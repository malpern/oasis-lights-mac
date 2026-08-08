import AppKit
import Darwin
import Foundation
import Observation
import Sparkle
import SwiftUI

private enum LightAddress {
    static let first: UInt16 = 0x0002
    static let second: UInt16 = 0x0003
    static let group: UInt16 = 0xC000
}

private enum LightAppearancePreset: String, CaseIterable, Identifiable {
    case bright
    case neutral
    case soft
    case glow
    case amber
    case candle
    case coral
    case sky
    case violet

    enum Command {
        case temperature(Int)
        case color(red: UInt8, green: UInt8, blue: UInt8)
    }

    var id: String { rawValue }

    /// Warmth is the choice people make most often, so it is offered directly
    /// in the main window; saturated colours stay behind the picker.
    static var warmths: [LightAppearancePreset] {
        allCases.filter { preset in
            if case .temperature = preset.command { return true }
            return false
        }
    }

    var description: LocalizedStringResource {
        switch command {
        case let .temperature(kelvin): "\(kelvin)K white"
        case let .color(red, green, blue): "Colour \(red), \(green), \(blue)"
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .bright: "Bright"
        case .neutral: "Neutral"
        case .soft: "Soft"
        case .glow: "Glow"
        case .amber: "Amber"
        case .candle: "Candle"
        case .coral: "Coral"
        case .sky: "Sky"
        case .violet: "Violet"
        }
    }

    var swatch: Color {
        switch self {
        case .bright: Color(red: 1.00, green: 0.98, blue: 0.92)
        case .neutral: Color(red: 1.00, green: 0.90, blue: 0.72)
        case .soft: Color(red: 1.00, green: 0.82, blue: 0.53)
        case .glow: Color(red: 1.00, green: 0.68, blue: 0.31)
        case .amber: Color(red: 1.00, green: 0.51, blue: 0.13)
        case .candle: Color(red: 1.00, green: 0.34, blue: 0.06)
        case .coral: Color(red: 1.00, green: 0.22, blue: 0.28)
        case .sky: Color(red: 0.10, green: 0.56, blue: 1.00)
        case .violet: Color(red: 0.58, green: 0.25, blue: 1.00)
        }
    }

    var command: Command {
        switch self {
        case .bright: .temperature(4000)
        case .neutral: .temperature(3500)
        case .soft: .temperature(3000)
        case .glow: .temperature(2800)
        case .amber: .temperature(2400)
        case .candle: .temperature(2000)
        case .coral: .color(red: 255, green: 56, blue: 71)
        case .sky: .color(red: 26, green: 143, blue: 255)
        case .violet: .color(red: 148, green: 64, blue: 255)
        }
    }
}

/// Custom colours the user has mixed, newest first, persisted as hex strings.
private enum CustomSwatches {
    static let limit = 5

    static func decode(_ raw: String) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(raw.utf8))) ?? []
    }

    static func encode(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// Newest first, no duplicates, oldest dropped past the limit.
    static func adding(_ hex: String, to raw: String) -> String {
        var values = decode(raw).filter { $0.caseInsensitiveCompare(hex) != .orderedSame }
        values.insert(hex, at: 0)
        return encode(Array(values.prefix(limit)))
    }

    static func removing(_ hex: String, from raw: String) -> String {
        encode(decode(raw).filter { $0.caseInsensitiveCompare(hex) != .orderedSame })
    }

    static func rgb(for hex: String) -> (red: UInt8, green: UInt8, blue: UInt8)? {
        var value = hex
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        return (
            UInt8((number >> 16) & 0xFF),
            UInt8((number >> 8) & 0xFF),
            UInt8(number & 0xFF)
        )
    }

    static func color(for hex: String) -> Color {
        guard let rgb = rgb(for: hex) else { return .gray }
        return Color(
            red: Double(rgb.red) / 255,
            green: Double(rgb.green) / 255,
            blue: Double(rgb.blue) / 255
        )
    }
}

private extension NSColor {
    var oasisHex: String? {
        guard let rgb = oasisRGB else { return nil }
        return String(format: "#%02X%02X%02X", rgb.red, rgb.green, rgb.blue)
    }

    var oasisRGB: (red: UInt8, green: UInt8, blue: UInt8)? {
        guard let color = usingColorSpace(.sRGB) else { return nil }
        return (
            UInt8((color.redComponent * 255).rounded()),
            UInt8((color.greenComponent * 255).rounded()),
            UInt8((color.blueComponent * 255).rounded())
        )
    }
}

private struct BridgeDetails: Decodable, Equatable {
    let ready: Bool
    let bluetoothState: Int
    let proxy: String?
    let port: UInt16
    let nextSequence: Int
    let lastCommands: [String: Bool]
    let lastError: String?

    func lastCommand(for destination: UInt16) -> Bool? {
        lastCommands[String(destination)]
    }
}

private enum ControllerError: LocalizedError {
    case connectionFailed
    case invalidResponse
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed: "Could not connect to Oasis Bridge."
        case .invalidResponse: "Oasis Bridge returned an invalid response."
        case let .rejected(response): "Oasis Bridge rejected the command: \(response)"
        }
    }
}

private enum BridgeClient {
    static func request(_ command: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw ControllerError.connectionFailed }
            defer { close(descriptor) }

            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(18765).bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else { throw ControllerError.connectionFailed }

            let payload = Data((command + "\n").utf8)
            let sent = payload.withUnsafeBytes { bytes in
                Darwin.send(descriptor, bytes.baseAddress, payload.count, 0)
            }
            guard sent == payload.count else { throw ControllerError.connectionFailed }

            var response = Data()
            var byte: UInt8 = 0
            while response.count < 4096 {
                let received = Darwin.recv(descriptor, &byte, 1, 0)
                guard received > 0 else { break }
                if byte == 0x0A { break }
                response.append(byte)
            }
            guard let value = String(data: response, encoding: .utf8), !value.isEmpty else {
                throw ControllerError.invalidResponse
            }
            return value
        }.value
    }
}

@MainActor
@Observable
private final class ControllerModel {
    static let shared = ControllerModel()

    private(set) var details: BridgeDetails?
    private(set) var isRefreshing = false
    private(set) var commandInFlight = false
    var presentedError: String?
    private var pollingTask: Task<Void, Never>?

    var isReady: Bool { details?.ready == true }

    /// "Waiting for Bluetooth" used to cover every not-ready condition, which
    /// made an unreachable light look like a Bluetooth permission problem.
    /// Each cause now reports itself.
    enum BridgeStatus: Equatable {
        case bridgeUnavailable
        case bluetoothUnavailable(Int)
        case searching
        case connecting
        case connected
    }

    var status: BridgeStatus {
        guard let details else { return .bridgeUnavailable }
        // CBManagerState.poweredOn
        guard details.bluetoothState == 5 else {
            return .bluetoothUnavailable(details.bluetoothState)
        }
        if details.ready { return .connected }
        return details.proxy == nil ? .searching : .connecting
    }

    var statusTitle: LocalizedStringResource {
        switch status {
        case .bridgeUnavailable: "Bridge unavailable"
        case let .bluetoothUnavailable(state): Self.bluetoothTitle(for: state)
        case .searching: "No lights found"
        case .connecting: "Connecting"
        case .connected: "Connected"
        }
    }

    private static func bluetoothTitle(for state: Int) -> LocalizedStringResource {
        switch state {
        // CBManagerState raw values
        case 2: "Bluetooth unsupported"
        case 3: "Bluetooth not authorized"
        case 4: "Bluetooth turned off"
        default: "Waiting for Bluetooth"
        }
    }

    /// The proxy when there is one, otherwise why the bridge cannot reach it.
    var statusDetail: String? {
        switch status {
        case .connected, .connecting: details?.proxy
        // Deliberately not lastError: while searching, the absence of any proxy
        // is the reason, and a stale error would read as the current cause.
        case .searching: "No light is advertising in range"
        case .bluetoothUnavailable: "Bridge cannot use the Bluetooth radio"
        case .bridgeUnavailable: "Oasis Bridge is not running"
        }
    }

    var statusSystemImage: String {
        switch status {
        case .bridgeUnavailable: "exclamationmark.triangle.fill"
        case .bluetoothUnavailable: "antenna.radiowaves.left.and.right.slash"
        case .searching: "magnifyingglass"
        case .connecting: "antenna.radiowaves.left.and.right"
        case .connected: "checkmark.circle.fill"
        }
    }

    var statusColor: Color {
        switch status {
        case .bridgeUnavailable, .bluetoothUnavailable: .orange
        case .searching: .secondary
        case .connecting: .yellow
        case .connected: .green
        }
    }

    func beginPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let response = try await BridgeClient.request("DETAILS")
            details = try JSONDecoder().decode(BridgeDetails.self, from: Data(response.utf8))
        } catch {
            details = nil
        }
    }

    func sendPower(to destination: UInt16, isOn: Bool) {
        guard !commandInFlight else { return }
        commandInFlight = true
        Task {
            defer { commandInFlight = false }
            do {
                let response = try await BridgeClient.request("POWER \(destination) \(isOn ? 1 : 0)")
                guard response == "OK" else { throw ControllerError.rejected(response) }
                await refresh()
            } catch {
                presentedError = error.localizedDescription
            }
        }
    }

    func sendBrightness(to destination: UInt16, percent: Int) {
        send("BRIGHTNESS \(destination) \(min(100, max(1, percent)))")
    }

    func sendColorTemperature(to destination: UInt16, kelvin: Int, brightness: Int) {
        let temperature = min(4000, max(2000, kelvin))
        let percent = min(100, max(1, brightness))
        send("CCTB \(destination) \(temperature) \(percent)")
    }

    func sendColor(to destination: UInt16, red: UInt8, green: UInt8, blue: UInt8) {
        send("COLOR \(destination) \(red) \(green) \(blue)")
    }

    private func send(_ command: String) {
        guard !commandInFlight else { return }
        commandInFlight = true
        Task {
            defer { commandInFlight = false }
            do {
                let response = try await BridgeClient.request(command)
                guard response == "OK" else { throw ControllerError.rejected(response) }
                await refresh()
            } catch {
                presentedError = error.localizedDescription
            }
        }
    }

    enum PairState {
        case allOn
        case allOff
        case mixed
        case unknown

        var summary: LocalizedStringResource {
            switch self {
            case .allOn: "Both on"
            case .allOff: "Both off"
            case .mixed: "One on, one off"
            case .unknown: "State unknown"
            }
        }
    }

    /// A group command is recorded against the group address, so fall back to
    /// it when an individual light has not been addressed directly.
    var pairState: PairState {
        guard let details else { return .unknown }
        let group = details.lastCommand(for: LightAddress.group)
        let first = details.lastCommand(for: LightAddress.first) ?? group
        let second = details.lastCommand(for: LightAddress.second) ?? group
        switch (first, second) {
        case (true, true): return .allOn
        case (false, false): return .allOff
        case (nil, nil): return .unknown
        default: return .mixed
        }
    }

    func toggle(_ destination: UInt16) {
        let current: Bool?
        if destination == LightAddress.group {
            let first = details?.lastCommand(for: LightAddress.first)
            let second = details?.lastCommand(for: LightAddress.second)
            current = first == second ? first : nil
        } else {
            current = details?.lastCommand(for: destination)
        }
        sendPower(to: destination, isOn: !(current ?? false))
    }

    func reconnect() {
        Task {
            do {
                let response = try await BridgeClient.request("RECONNECT")
                guard response == "OK" else { throw ControllerError.rejected(response) }
                try? await Task.sleep(for: .seconds(1))
                await refresh()
            } catch {
                presentedError = error.localizedDescription
            }
        }
    }

    func revealLog() {
        // The bridge may run in another account, whose home this process cannot
        // read; the shared location is canonical. Fall back to our own home for
        // installs that predate it.
        let shared = URL(filePath: "/Users/Shared/OasisBridge/OasisBridge.log")
        let log = FileManager.default.fileExists(atPath: shared.path)
            ? shared
            : FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Logs/OasisBridge.log")
        NSWorkspace.shared.activateFileViewerSelecting([log])
    }

}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
private struct OasisControllerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = ControllerModel.shared
    @State private var updates = UpdateService.shared

    var body: some Scene {
        WindowGroup("Oasis Lights") {
            MainControlView(model: model)
                .frame(width: 620)
        }
        // Let the window follow the disclosure instead of leaving dead space
        // below the footer when the individual controls are collapsed.
        .windowResizability(.contentSize)
        .commands {
            LightCommands(model: model)
            UpdateCommands(updates: updates)
            AboutCommands()
        }

        Window("About Oasis Lights", id: "about") {
            OasisLightsAboutView()
        }
        .defaultSize(width: 760, height: 560)
        .windowResizability(.contentSize)

        Settings {
            BridgeSettingsView(model: model, updates: updates)
                .frame(minWidth: 520, minHeight: 680)
        }
    }
}

private struct MainControlView: View {
    let model: ControllerModel
    @AppStorage("firstLightName") private var firstLightName = "Oasis Light 1"
    @AppStorage("secondLightName") private var secondLightName = "Oasis Light 2"
    @AppStorage("firstLightBrightness") private var firstLightBrightness = 100.0
    @AppStorage("secondLightBrightness") private var secondLightBrightness = 100.0
    @AppStorage("showIndividualLights") private var showIndividualLights = false

    private var isEnabled: Bool { model.isReady && !model.commandInFlight }

    /// Derived rather than stored: a third copy of "how bright" would sit at
    /// its default while the per-light sliders held real values, and the card
    /// would contradict the rows below it.
    private var pairBrightness: Binding<Double> {
        Binding(
            get: { (firstLightBrightness + secondLightBrightness) / 2 },
            set: { value in
                firstLightBrightness = value
                secondLightBrightness = value
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ControlHeader(
                statusTitle: model.statusTitle,
                statusSystemImage: model.statusSystemImage,
                statusColor: model.statusColor,
                detail: model.statusDetail
            )
            PairControlCard(
                state: model.pairState,
                brightness: pairBrightness,
                isEnabled: isEnabled,
                setPower: { model.sendPower(to: LightAddress.group, isOn: $0) },
                setBrightness: { model.sendBrightness(to: LightAddress.group, percent: $0) },
                setTemperature: { kelvin in
                    model.sendColorTemperature(
                        to: LightAddress.group,
                        kelvin: kelvin,
                        brightness: Int(pairBrightness.wrappedValue.rounded())
                    )
                },
                setColor: { model.sendColor(to: LightAddress.group, red: $0, green: $1, blue: $2) }
            )
            IndividualLightsDisclosure(
                isExpanded: $showIndividualLights,
                firstName: firstLightName,
                firstState: model.details?.lastCommand(for: LightAddress.first),
                secondName: secondLightName,
                secondState: model.details?.lastCommand(for: LightAddress.second),
                firstBrightness: $firstLightBrightness,
                secondBrightness: $secondLightBrightness,
                isEnabled: isEnabled,
                sendPower: model.sendPower,
                sendBrightness: model.sendBrightness,
                sendColorTemperature: model.sendColorTemperature,
                sendColor: model.sendColor
            )
            Spacer(minLength: 0)
            ControlFooter()
        }
        .padding(28)
        .animation(.snappy(duration: 0.22), value: showIndividualLights)
        .task { model.beginPolling() }
        .alert("Oasis command failed", isPresented: Binding(
            get: { model.presentedError != nil },
            set: { if !$0 { model.presentedError = nil } }
        )) {
            Button("OK") { model.presentedError = nil }
        } message: {
            Text(model.presentedError ?? "Unknown error")
        }
    }

}

private struct ControlHeader: View {
    let statusTitle: LocalizedStringResource
    let statusSystemImage: String
    let statusColor: Color
    let detail: String?

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Oasis Lights")
                    .font(.largeTitle.bold())
                Text("Local Bluetooth Mesh control")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Label(statusTitle, systemImage: statusSystemImage)
                    .foregroundStyle(statusColor)
                    .font(.headline)
                if let detail {
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                        .frame(maxWidth: 280, alignment: .trailing)
                }
            }
        }
    }
}

/// The pair is what people actually manage; both lights live in the same room
/// and are almost always set together.
private struct PairControlCard: View {
    let state: ControllerModel.PairState
    @Binding var brightness: Double
    let isEnabled: Bool
    let setPower: (Bool) -> Void
    let setBrightness: (Int) -> Void
    let setTemperature: (Int) -> Void
    let setColor: (UInt8, UInt8, UInt8) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                Image(systemName: state == .allOn ? "lightbulb.2.fill" : "lightbulb.2")
                    .font(.system(size: 28))
                    .foregroundStyle(state == .allOn ? .yellow : .secondary)
                    .frame(width: 38)
                    .help(state == .mixed ? "The two lights disagree" : "Both lights")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Both lights")
                        .font(.title2.weight(.semibold))
                    Text(state.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Both lights", isOn: Binding(
                    get: { state == .allOn },
                    set: setPower
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.large)
                .disabled(!isEnabled)
                .help("Turn both lights on or off with one command")
                .accessibilityIdentifier("bothLights.toggle")
            }
            HStack(spacing: 12) {
                Image(systemName: "sun.max.fill")
                    .foregroundStyle(.secondary)
                Slider(value: $brightness, in: 1 ... 100, step: 1) { editing in
                    if !editing { setBrightness(Int(brightness.rounded())) }
                }
                .accessibilityIdentifier("bothLights.brightness")
                .help("Brightness for both lights")
                Text("\(Int(brightness.rounded()))%")
                    .font(.body.monospacedDigit())
                    .frame(width: 44, alignment: .trailing)
            }
            .disabled(!isEnabled)
            WarmthRow(
                brightness: Int(brightness.rounded()),
                isEnabled: isEnabled,
                setTemperature: setTemperature,
                setColor: setColor
            )
        }
        .padding(20)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Warmth presets sit in the main window instead of behind the picker — they
/// are the second thing anyone changes after on/off.
private struct WarmthRow: View {
    let brightness: Int
    let isEnabled: Bool
    let setTemperature: (Int) -> Void
    let setColor: (UInt8, UInt8, UInt8) -> Void
    @AppStorage("customColorSwatches") private var storedSwatches = "[]"
    @State private var isPickingColor = false
    @State private var draftColor = Color(red: 0.20, green: 0.48, blue: 1.00)

    private var swatches: [String] { CustomSwatches.decode(storedSwatches) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Warmth & colour")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(LightAppearancePreset.warmths) { preset in
                    SwatchButton(
                        fill: preset.swatch,
                        title: preset.title,
                        tooltip: preset.description,
                        identifier: "bothLights.warmth.\(preset.rawValue)",
                        select: { selectPreset(preset) }
                    )
                }
                ForEach(swatches, id: \.self) { hex in
                    SwatchButton(
                        fill: CustomSwatches.color(for: hex),
                        title: "",
                        tooltip: "\(hex) — right-click to remove",
                        identifier: "bothLights.custom.\(hex)",
                        select: { apply(hex: hex) }
                    )
                    .contextMenu {
                        Button("Remove Colour", role: .destructive) {
                            storedSwatches = CustomSwatches.removing(hex, from: storedSwatches)
                        }
                    }
                }
                AddSwatchButton(isPresented: $isPickingColor)
                    .popover(isPresented: $isPickingColor, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Custom colour")
                                .font(.headline)
                            ColorPicker("Pick a colour", selection: $draftColor, supportsOpacity: false)
                                .accessibilityIdentifier("bothLights.customColor")
                            Button("Use & Remember") { rememberDraft() }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("bothLights.rememberColor")
                        }
                        .padding(18)
                        .frame(width: 260)
                    }
                Spacer()
            }
        }
        .disabled(!isEnabled)
    }

    private func selectPreset(_ preset: LightAppearancePreset) {
        switch preset.command {
        case let .temperature(kelvin): setTemperature(kelvin)
        case let .color(red, green, blue): setColor(red, green, blue)
        }
    }

    private func apply(hex: String) {
        guard let rgb = CustomSwatches.rgb(for: hex) else { return }
        setColor(rgb.red, rgb.green, rgb.blue)
    }

    private func rememberDraft() {
        guard let hex = NSColor(draftColor).oasisHex else { return }
        storedSwatches = CustomSwatches.adding(hex, to: storedSwatches)
        apply(hex: hex)
        isPickingColor = false
    }
}

private struct AddSwatchButton: View {
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .strokeBorder(.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 30, height: 30)
                Text("Add")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Mix a colour and keep it as a swatch")
        .accessibilityIdentifier("bothLights.addColor")
    }
}

private struct SwatchButton: View {
    let fill: Color
    let title: LocalizedStringResource
    let tooltip: LocalizedStringResource
    let identifier: String
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 5) {
                Circle()
                    .fill(fill)
                    .frame(width: 30, height: 30)
                    .overlay { Circle().stroke(.white.opacity(0.38), lineWidth: 1) }
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityIdentifier(identifier)
    }
}

private struct IndividualLightsDisclosure: View {
    @Binding var isExpanded: Bool
    let firstName: String
    let firstState: Bool?
    let secondName: String
    let secondState: Bool?
    @Binding var firstBrightness: Double
    @Binding var secondBrightness: Double
    let isEnabled: Bool
    let sendPower: (UInt16, Bool) -> Void
    let sendBrightness: (UInt16, Int) -> Void
    let sendColorTemperature: (UInt16, Int, Int) -> Void
    let sendColor: (UInt16, UInt8, UInt8, UInt8) -> Void

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            lightRows.padding(.top, 12)
        } label: {
            Label("Adjust each light", systemImage: "slider.horizontal.3")
                .font(.headline)
                .help("Control the two lights separately")
                .accessibilityIdentifier("individualLights.disclosure")
        }
    }

    private var lightRows: some View {
        VStack(spacing: 12) {
            LightControlRow(
                name: firstName,
                identifier: "AM2GLS619104885",
                lastCommand: firstState,
                brightness: $firstBrightness,
                isEnabled: isEnabled,
                turnOn: { sendPower(LightAddress.first, true) },
                turnOff: { sendPower(LightAddress.first, false) },
                setBrightness: { sendBrightness(LightAddress.first, $0) },
                setTemperature: {
                    sendColorTemperature(LightAddress.first, $0, Int(firstBrightness.rounded()))
                },
                setColor: { sendColor(LightAddress.first, $0, $1, $2) }
            )
            LightControlRow(
                name: secondName,
                identifier: "AM2GLS619204014",
                lastCommand: secondState,
                brightness: $secondBrightness,
                isEnabled: isEnabled,
                turnOn: { sendPower(LightAddress.second, true) },
                turnOff: { sendPower(LightAddress.second, false) },
                setBrightness: { sendBrightness(LightAddress.second, $0) },
                setTemperature: {
                    sendColorTemperature(LightAddress.second, $0, Int(secondBrightness.rounded()))
                },
                setColor: { sendColor(LightAddress.second, $0, $1, $2) }
            )
        }
    }
}

private struct LightControlRow: View {
    let name: String
    let identifier: String
    let lastCommand: Bool?
    @Binding var brightness: Double
    let isEnabled: Bool
    let turnOn: () -> Void
    let turnOff: () -> Void
    let setBrightness: (Int) -> Void
    let setTemperature: (Int) -> Void
    let setColor: (UInt8, UInt8, UInt8) -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                Image(systemName: lastCommand == true ? "lightbulb.fill" : "lightbulb")
                    .font(.title2)
                    .foregroundStyle(lastCommand == true ? .yellow : .secondary)
                    .frame(width: 32)
                // The device id is reference material, not something to read at
                // a glance; it stays available on hover.
                Text(name)
                    .font(.headline)
                    .help("\(name) · \(identifier)")
                Spacer()
                Toggle(name, isOn: Binding(
                    get: { lastCommand == true },
                    set: { $0 ? turnOn() : turnOff() }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!isEnabled)
                .help(lastCommand == nil ? "State unknown — no command sent yet" : "Turn \(name) on or off")
                .accessibilityIdentifier("\(identifier).toggle")
            }
            HStack(spacing: 12) {
                Image(systemName: "sun.max.fill")
                    .foregroundStyle(.secondary)
                Slider(value: $brightness, in: 1 ... 100, step: 1) { editing in
                    if !editing { setBrightness(Int(brightness.rounded())) }
                }
                .accessibilityIdentifier("\(identifier).brightness")
                .help("Brightness for \(name)")
                Text("\(Int(brightness.rounded()))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 40, alignment: .trailing)
                AppearancePickerButton(
                    title: name,
                    brightness: Int(brightness.rounded()),
                    isEnabled: isEnabled,
                    accessibilityPrefix: identifier,
                    setTemperature: setTemperature,
                    setColor: setColor
                )
            }
            .font(.caption)
            .disabled(!isEnabled)
        }
        .padding(16)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct AppearancePickerButton: View {
    let title: String
    let brightness: Int
    let isEnabled: Bool
    let accessibilityPrefix: String
    let setTemperature: (Int) -> Void
    let setColor: (UInt8, UInt8, UInt8) -> Void
    @State private var isPresented = false
    @State private var customColor = Color(red: 0.20, green: 0.48, blue: 1.00)

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label("Color", systemImage: "paintpalette.fill")
        }
        .buttonStyle(.bordered)
        .disabled(!isEnabled)
        .accessibilityIdentifier("\(accessibilityPrefix).appearance")
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            LightAppearancePopover(
                title: title,
                brightness: brightness,
                customColor: $customColor,
                accessibilityPrefix: accessibilityPrefix,
                close: { isPresented = false },
                selectPreset: selectPreset,
                applyCustomColor: applyCustomColor
            )
        }
    }

    private func selectPreset(_ preset: LightAppearancePreset) {
        switch preset.command {
        case let .temperature(kelvin):
            setTemperature(kelvin)
        case let .color(red, green, blue):
            setColor(red, green, blue)
        }
        isPresented = false
    }

    private func applyCustomColor() {
        guard let rgb = NSColor(customColor).oasisRGB else { return }
        setColor(rgb.red, rgb.green, rgb.blue)
        isPresented = false
    }
}

private struct LightAppearancePopover: View {
    let title: String
    let brightness: Int
    @Binding var customColor: Color
    let accessibilityPrefix: String
    let close: () -> Void
    let selectPreset: (LightAppearancePreset) -> Void
    let applyCustomColor: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            AppearancePickerHeader(title: title, close: close)
            AppearancePresetGrid(
                accessibilityPrefix: accessibilityPrefix,
                selectPreset: selectPreset
            )
            Divider()
            CustomColorSection(
                customColor: $customColor,
                accessibilityPrefix: accessibilityPrefix,
                apply: applyCustomColor
            )
            Text("White presets retain the current brightness of \(brightness) percent.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 370)
    }
}

private struct AppearancePickerHeader: View {
    let title: String
    let close: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2.bold())
                Text("Choose a light color")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close")
            .accessibilityLabel("Close color picker")
        }
    }
}

private struct AppearancePresetGrid: View {
    private static let columns = Array(
        repeating: GridItem(.flexible(), spacing: 12),
        count: 3
    )

    let accessibilityPrefix: String
    let selectPreset: (LightAppearancePreset) -> Void

    var body: some View {
        LazyVGrid(columns: Self.columns, spacing: 16) {
            ForEach(LightAppearancePreset.allCases) { preset in
                AppearancePresetButton(
                    preset: preset,
                    accessibilityPrefix: accessibilityPrefix,
                    select: selectPreset
                )
            }
        }
    }
}

private struct AppearancePresetButton: View {
    let preset: LightAppearancePreset
    let accessibilityPrefix: String
    let select: (LightAppearancePreset) -> Void

    var body: some View {
        Button {
            select(preset)
        } label: {
            VStack(spacing: 7) {
                Circle()
                    .fill(preset.swatch)
                    .frame(width: 54, height: 54)
                    .overlay {
                        Circle().stroke(.white.opacity(0.38), lineWidth: 1)
                    }
                    .shadow(color: preset.swatch.opacity(0.45), radius: 7)
                Text(preset.title)
                    .font(.callout.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("\(accessibilityPrefix).preset.\(preset.rawValue)")
    }
}

private struct CustomColorSection: View {
    @Binding var customColor: Color
    let accessibilityPrefix: String
    let apply: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ColorPicker("Custom color", selection: $customColor, supportsOpacity: false)
                .accessibilityIdentifier("\(accessibilityPrefix).customColor")
            Spacer()
            Button("Apply Custom Color", action: apply)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("\(accessibilityPrefix).applyCustomColor")
        }
    }
}

private struct ControlFooter: View {
    var body: some View {
        HStack {
            Label("Displayed state is the last command sent, not a verified device report.", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }
}

private struct BridgeSettingsView: View {
    let model: ControllerModel
    let updates: UpdateService
    @Environment(\.openWindow) private var openWindow
    @AppStorage("firstLightName") private var firstLightName = "Oasis Light 1"
    @AppStorage("secondLightName") private var secondLightName = "Oasis Light 2"

    var body: some View {
        Form {
            Section("Bridge") {
                LabeledContent("Status") {
                    Label(model.statusTitle, systemImage: model.statusSystemImage)
                        .foregroundStyle(model.statusColor)
                }
                LabeledContent("Connected proxy", value: model.details?.proxy ?? "None")
                LabeledContent("Last Bluetooth error", value: model.details?.lastError ?? "None")
                LabeledContent("Next Mesh sequence", value: model.details.map { String($0.nextSequence) } ?? "Unavailable")
                HStack {
                    Button("Reconnect Bluetooth", action: model.reconnect)
                        .accessibilityIdentifier("settings.reconnect")
                    Button("Reveal Bridge Log", action: model.revealLog)
                        .accessibilityIdentifier("settings.revealLog")
                }
            }
            Section("Light names") {
                TextField("First light", text: $firstLightName)
                    .accessibilityIdentifier("settings.firstLightName")
                TextField("Second light", text: $secondLightName)
                    .accessibilityIdentifier("settings.secondLightName")
            }
            Section("Keyboard shortcuts") {
                LabeledContent("Toggle first light", value: "⌘1")
                LabeledContent("Toggle second light", value: "⌘2")
                LabeledContent("Toggle both lights", value: "⇧⌘L")
                Text("These shortcuts work while Oasis Lights is the active application.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Startup") {
                Label("The bridge runs as a headless login service on the Mac mini and remains available when this controller is closed.", systemImage: "checkmark.circle")
                Text("It is managed separately so removing a controller from another Mac cannot accidentally disable Home Assistant.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            UpdateSettingsSection(updates: updates)
            Section("About") {
                Button("About Oasis Lights") { openWindow(id: "about") }
                    .accessibilityIdentifier("settings.aboutLights")
                LabeledContent("Bridge component", value: "Headless on Mac mini")
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { model.beginPolling() }
    }
}

private struct UpdateSettingsSection: View {
    let updates: UpdateService

    var body: some View {
        @Bindable var updates = updates

        Section("Updates") {
            Toggle("Automatically check for updates", isOn: $updates.automaticallyChecksForUpdates)
                .accessibilityIdentifier("settings.automaticUpdateChecks")
            Toggle("Automatically download and install updates", isOn: $updates.automaticallyDownloadsUpdates)
                .disabled(!updates.automaticallyChecksForUpdates)
                .accessibilityIdentifier("settings.automaticUpdateDownloads")
            HStack {
                Button("Check for Updates…", action: updates.checkForUpdates)
                    .disabled(!updates.canCheckForUpdates)
                    .accessibilityIdentifier("settings.checkForUpdates")
                Spacer()
                if let lastUpdateCheckDate = updates.lastUpdateCheckDate {
                    Text("Last checked \(lastUpdateCheckDate, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear(perform: updates.synchronize)
    }
}

private struct UpdateCommands: Commands {
    let updates: UpdateService

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…", action: updates.checkForUpdates)
                .disabled(!updates.canCheckForUpdates)
        }
    }
}

private struct AboutCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Oasis Lights") { openWindow(id: "about") }
        }
    }
}

private struct OasisLightsAboutView: View {
    private let artwork = Bundle.main.url(forResource: "OasisLightsAbout", withExtension: "png")
        .flatMap(NSImage.init(contentsOf:))

    var body: some View {
        VStack(spacing: 0) {
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 760, height: 380)
                    .clipped()
                    .accessibilityHidden(true)
            }
            HStack(alignment: .center, spacing: 18) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Oasis Lights")
                        .font(.title.bold())
                    Text("Local control for two Oasis lights")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Version \(Bundle.main.shortVersion) · Bluetooth Mesh stays on your network")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(24)
            .background(.regularMaterial)
        }
        .frame(width: 760, height: 522)
    }
}

private struct LightCommands: Commands {
    let model: ControllerModel

    var body: some Commands {
        CommandMenu("Lights") {
            Button("Toggle First Light") { model.toggle(LightAddress.first) }
                .keyboardShortcut("1", modifiers: .command)
            Button("Toggle Second Light") { model.toggle(LightAddress.second) }
                .keyboardShortcut("2", modifiers: .command)
            Divider()
            Button("Toggle Both Lights") { model.toggle(LightAddress.group) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }
}
