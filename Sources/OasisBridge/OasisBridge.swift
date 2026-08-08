import AppKit
import CommonCrypto
import CoreBluetooth
import Foundation
import Network

private enum BridgeError: LocalizedError {
    case invalidConfiguration(String)
    case invalidCommand
    case bluetoothNotReady
    case sequenceExhausted
    case cryptoFailure(CCCryptorStatus)

    var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message): message
        case .invalidCommand: "malformed command"
        case .bluetoothNotReady: "Bluetooth Mesh proxy is not ready"
        case .sequenceExhausted: "Bluetooth Mesh sequence space is exhausted"
        case let .cryptoFailure(status): "AES operation failed with status \(status)"
        }
    }
}

private enum LightMode: UInt8 {
    case color = 0x01
    case temperature = 0x02
}

private struct TopologyEnvelope: Decodable {
    let meshNetwork: MeshNetwork
}

private struct MeshNetwork: Decodable {
    let netKeys: [MeshKey]
    let appKeys: [MeshKey]
}

private struct MeshKey: Decodable {
    let key: String
}

private struct SequenceEnvelope: Codable {
    let nextSequence: Int

    enum CodingKeys: String, CodingKey {
        case nextSequence = "next_sequence"
    }
}

private struct BridgeDetails: Encodable {
    let ready: Bool
    let bluetoothState: Int
    let proxy: String?
    let port: UInt16
    let nextSequence: Int
    let lastCommands: [String: Bool]
    let lastError: String?
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var result = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        self = result
    }

    static func +(left: Data, right: Data) -> Data {
        var result = left
        result.append(right)
        return result
    }

    func xor(_ other: Data) -> Data {
        Data(zip(self, other).map(^))
    }
}

private enum MeshCrypto {
    static func buildVendorNetworkPDU(
        networkKey: Data,
        applicationKey: Data,
        source: UInt16,
        destination: UInt16,
        sequence: Int,
        ivIndex: UInt32,
        opcode: UInt8,
        parameters: Data,
        ttl: UInt8 = 5
    ) throws -> Data {
        let accessPayload = Data([opcode, 0xE5, 0x02]) + parameters
        let aid = try k4(applicationKey)
        let applicationNonce = Data([0x01, 0x00])
            + uint24(sequence)
            + bigEndian(source)
            + bigEndian(destination)
            + bigEndian(ivIndex)
        let upperTransport = try ccmEncrypt(
            key: applicationKey,
            nonce: applicationNonce,
            plaintext: accessPayload,
            tagLength: 4
        )
        let lowerTransport = Data([0x40 | aid]) + upperTransport
        let (nid, encryptionKey, privacyKey) = try k2(networkKey)
        let ctlTTL = ttl & 0x7F
        let networkNonce = Data([0x00, ctlTTL])
            + uint24(sequence)
            + bigEndian(source)
            + Data([0x00, 0x00])
            + bigEndian(ivIndex)
        let encoded = try ccmEncrypt(
            key: encryptionKey,
            nonce: networkNonce,
            plaintext: bigEndian(destination) + lowerTransport,
            tagLength: 4
        )
        let header = Data([ctlTTL]) + uint24(sequence) + bigEndian(source)
        let privacyRandom = Data(repeating: 0, count: 5) + bigEndian(ivIndex) + encoded.prefix(7)
        let pecb = try aesECB(key: privacyKey, block: privacyRandom).prefix(6)
        let obfuscated = header.xor(Data(pecb))
        return Data([UInt8((ivIndex & 1) << 7) | nid]) + obfuscated + encoded
    }

    static func buildPowerNetworkPDU(
        networkKey: Data,
        applicationKey: Data,
        source: UInt16,
        destination: UInt16,
        sequence: Int,
        ivIndex: UInt32,
        isOn: Bool,
        ttl: UInt8 = 5
    ) throws -> Data {
        try buildVendorNetworkPDU(
            networkKey: networkKey,
            applicationKey: applicationKey,
            source: source,
            destination: destination,
            sequence: sequence,
            ivIndex: ivIndex,
            opcode: 0xC3,
            parameters: Data([isOn ? 1 : 0]),
            ttl: ttl
        )
    }

    private static func s1(_ message: Data) throws -> Data {
        try cmac(key: Data(repeating: 0, count: 16), message: message)
    }

    private static func k2(_ networkKey: Data) throws -> (UInt8, Data, Data) {
        let salt = try s1(Data("smk2".utf8))
        let t = try cmac(key: salt, message: networkKey)
        let t1 = try cmac(key: t, message: Data([0x00, 0x01]))
        let t2 = try cmac(key: t, message: t1 + Data([0x00, 0x02]))
        let t3 = try cmac(key: t, message: t2 + Data([0x00, 0x03]))
        let result = (t1 + t2 + t3).suffix(33)
        return (result[result.startIndex] & 0x7F,
                Data(result.dropFirst().prefix(16)),
                Data(result.dropFirst(17).prefix(16)))
    }

    private static func k4(_ applicationKey: Data) throws -> UInt8 {
        let salt = try s1(Data("smk4".utf8))
        let t = try cmac(key: salt, message: applicationKey)
        let result = try cmac(key: t, message: Data("id6".utf8) + Data([0x01]))
        return result.last! & 0x3F
    }

    private static func cmac(key: Data, message: Data) throws -> Data {
        let zero = Data(repeating: 0, count: 16)
        let l = try aesECB(key: key, block: zero)
        let k1 = cmacSubkey(l)
        let k2 = cmacSubkey(k1)
        let isComplete = !message.isEmpty && message.count.isMultiple(of: 16)
        let blockCount = max(1, (message.count + 15) / 16)
        var x = zero
        if blockCount > 1 {
            for blockIndex in 0..<(blockCount - 1) {
                let start = blockIndex * 16
                let block = Data(message[start..<(start + 16)])
                x = try aesECB(key: key, block: x.xor(block))
            }
        }
        let finalStart = (blockCount - 1) * 16
        let finalBlock: Data
        if isComplete {
            finalBlock = Data(message[finalStart..<(finalStart + 16)]).xor(k1)
        } else {
            var padded = finalStart < message.count ? Data(message[finalStart..<message.count]) : Data()
            padded.append(0x80)
            padded.append(Data(repeating: 0, count: 16 - padded.count))
            finalBlock = padded.xor(k2)
        }
        return try aesECB(key: key, block: x.xor(finalBlock))
    }

    private static func cmacSubkey(_ input: Data) -> Data {
        var output = [UInt8](repeating: 0, count: 16)
        let bytes = [UInt8](input)
        for index in 0..<16 {
            let nextCarry: UInt8 = index + 1 < 16 ? (bytes[index + 1] >> 7) : 0
            output[index] = (bytes[index] << 1) | nextCarry
        }
        if bytes[0] & 0x80 != 0 {
            output[15] ^= 0x87
        }
        return Data(output)
    }

    private static func ccmEncrypt(
        key: Data,
        nonce: Data,
        plaintext: Data,
        tagLength: Int
    ) throws -> Data {
        let lengthFieldSize = 15 - nonce.count
        guard key.count == 16,
              (7...13).contains(nonce.count),
              [4, 6, 8, 10, 12, 14, 16].contains(tagLength),
              lengthFieldSize == 2,
              plaintext.count <= 0xFFFF
        else {
            throw BridgeError.invalidConfiguration("Unsupported AES-CCM parameters")
        }
        let flags = UInt8(((tagLength - 2) / 2) << 3) | UInt8(lengthFieldSize - 1)
        let b0 = Data([flags]) + nonce + bigEndian(UInt16(plaintext.count))
        var mac = Data(repeating: 0, count: 16)
        mac = try aesECB(key: key, block: mac.xor(b0))
        if !plaintext.isEmpty {
            var offset = 0
            while offset < plaintext.count {
                let end = min(offset + 16, plaintext.count)
                var block = Data(plaintext[offset..<end])
                block.append(Data(repeating: 0, count: 16 - block.count))
                mac = try aesECB(key: key, block: mac.xor(block))
                offset = end
            }
        }
        func counterBlock(_ counter: UInt16) -> Data {
            Data([UInt8(lengthFieldSize - 1)]) + nonce + bigEndian(counter)
        }
        let s0 = try aesECB(key: key, block: counterBlock(0))
        let tag = Data(mac.prefix(tagLength)).xor(Data(s0.prefix(tagLength)))
        var ciphertext = Data(capacity: plaintext.count + tagLength)
        var offset = 0
        var counter: UInt16 = 1
        while offset < plaintext.count {
            let stream = try aesECB(key: key, block: counterBlock(counter))
            let end = min(offset + 16, plaintext.count)
            ciphertext.append(Data(plaintext[offset..<end]).xor(Data(stream.prefix(end - offset))))
            offset = end
            counter += 1
        }
        ciphertext.append(tag)
        return ciphertext
    }

    private static func aesECB(key: Data, block: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128, block.count == kCCBlockSizeAES128 else {
            throw BridgeError.invalidConfiguration("AES-128 requires 16-byte keys and blocks")
        }
        var output = Data(repeating: 0, count: kCCBlockSizeAES128)
        let outputCapacity = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            key.withUnsafeBytes { keyBytes in
                block.withUnsafeBytes { blockBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress,
                        key.count,
                        nil,
                        blockBytes.baseAddress,
                        block.count,
                        outputBytes.baseAddress,
                        outputCapacity,
                        &moved
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw BridgeError.cryptoFailure(status) }
        return output
    }

    private static func uint24(_ value: Int) -> Data {
        Data([
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ])
    }

    private static func bigEndian(_ value: UInt16) -> Data {
        Data([UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    private static func bigEndian(_ value: UInt32) -> Data {
        Data([
            UInt8(value >> 24), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
        ])
    }
}

final class OasisBridge: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let port: NWEndpoint.Port = 18765
    private let topologyPath: URL
    private let sequencePath: URL
    private let networkKey: Data
    private let applicationKey: Data
    private var nextSequence: Int
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var dataIn: CBCharacteristic?
    private var dataOut: CBCharacteristic?
    private var listener: NWListener?
    private var isReady = false
    private var bluetoothState = CBManagerState.unknown
    private var connectedProxy: String?
    private var lastCommands: [UInt16: Bool] = [:]
    private var lastError: String?
    private var handshakeWatchdog: DispatchWorkItem?
    private var retryDelay = OasisBridge.minimumRetryDelay

    // A proxy that answers the advertisement but never completes the GATT
    // handshake used to wedge the bridge forever. Every path that leaves the
    // ready state now re-arms a watchdog and retries with backoff.
    private static let handshakeTimeout: TimeInterval = 15
    private static let minimumRetryDelay: TimeInterval = 1
    private static let maximumRetryDelay: TimeInterval = 30
    private static let scanSupervisorInterval: TimeInterval = 30

    override init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        topologyPath = home.appending(path: ".homeassistant/oasis-mesh-network.json")
        sequencePath = home.appending(path: ".homeassistant/oasis-mesh-sequence.json")
        do {
            let envelope = try JSONDecoder().decode(
                TopologyEnvelope.self,
                from: Data(contentsOf: topologyPath)
            )
            guard let netHex = envelope.meshNetwork.netKeys.first?.key,
                  let appHex = envelope.meshNetwork.appKeys.first?.key,
                  let netKey = Data(hex: netHex), netKey.count == 16,
                  let appKey = Data(hex: appHex), appKey.count == 16
            else {
                throw BridgeError.invalidConfiguration("Mesh topology does not contain 16-byte keys")
            }
            networkKey = netKey
            applicationKey = appKey
            if let saved = try? JSONDecoder().decode(
                SequenceEnvelope.self,
                from: Data(contentsOf: sequencePath)
            ) {
                nextSequence = saved.nextSequence
            } else {
                nextSequence = 10
            }
        } catch {
            fputs("configuration_failed \(error.localizedDescription)\n", stderr)
            exit(2)
        }
        super.init()
        startListener()
    }

    private func log(_ message: String) {
        print("\(Self.timestampFormatter.string(from: Date())) \(message)")
        fflush(stdout)
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter
    }()

    private func startListener() {
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    // Bluetooth only starts once this instance owns the port, so a
                    // duplicate bridge can never take the radio away from the one
                    // that is actually serving clients.
                    self?.startBluetooth()
                case let .failed(error):
                    fputs("listener_failed \(error)\n", stderr)
                    exit(2)
                case let .waiting(error):
                    // Loopback listeners only wait on address-in-use, which never
                    // clears on its own; let launchd retry instead of idling here.
                    fputs("listener_unavailable \(error)\n", stderr)
                    exit(2)
                default:
                    break
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            fputs("listener_setup_failed \(error)\n", stderr)
            exit(2)
        }
    }

    private func startBluetooth() {
        guard central == nil else { return }
        log("listener_ready port=\(port.rawValue)")
        central = CBCentralManager(delegate: self, queue: .main)
        startScanSupervisor()
    }

    /// Recovers from a scan that stops delivering discoveries without any
    /// delegate callback — restarting it is cheap and idempotent.
    private func startScanSupervisor() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scanSupervisorInterval) { [weak self] in
            guard let self else { return }
            if !isReady, peripheral == nil, central?.state == .poweredOn {
                log("scan_restart reason=no_proxy_seen")
                central.stopScan()
                scan()
            }
            startScanSupervisor()
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveLine(connection, buffer: Data())
    }

    private func receiveLine(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            guard error == nil, let data else {
                self?.reply(connection, "ERR malformed\n")
                return
            }
            var accumulated = buffer
            accumulated.append(data)
            guard accumulated.count <= 4096 else {
                self?.reply(connection, "ERR malformed\n")
                return
            }
            guard let newline = accumulated.firstIndex(of: 0x0A) else {
                self?.receiveLine(connection, buffer: accumulated)
                return
            }
            guard let line = String(data: accumulated[..<newline], encoding: .utf8) else {
                self?.reply(connection, "ERR malformed\n")
                return
            }
            self?.handle(line: line, connection: connection)
        }
    }

    private func handle(line: String, connection: NWConnection) {
        if line == "STATUS" {
            reply(connection, isReady ? "READY\n" : "NOT_READY state=\(bluetoothState.rawValue)\n")
            return
        }
        if line == "DETAILS" {
            let details = BridgeDetails(
                ready: isReady,
                bluetoothState: bluetoothState.rawValue,
                proxy: connectedProxy,
                port: port.rawValue,
                nextSequence: nextSequence,
                lastCommands: Dictionary(uniqueKeysWithValues: lastCommands.map { (String($0.key), $0.value) }),
                lastError: lastError
            )
            guard let data = try? JSONEncoder().encode(details),
                  let json = String(data: data, encoding: .utf8)
            else {
                reply(connection, "ERR encoding\n")
                return
            }
            reply(connection, json + "\n")
            return
        }
        if line == "RECONNECT" {
            resetAndScan(cancelCurrent: true)
            reply(connection, "OK\n")
            return
        }
        let fields = line.split(separator: " ")
        if fields.count == 3, fields[0] == "POWER",
           let destination = parseAddress(String(fields[1])),
           let onValue = Int(fields[2]), onValue == 0 || onValue == 1 {
            do {
                try sendPower(destination: destination, isOn: onValue == 1)
                reply(connection, "OK\n")
            } catch {
                lastError = error.localizedDescription
                if case BridgeError.bluetoothNotReady = error {
                    reply(connection, "ERR bluetooth_not_ready\n")
                } else {
                    reply(connection, "ERR command_failed\n")
                }
            }
            return
        }
        if fields.count == 3, fields[0] == "BRIGHTNESS",
           let destination = parseAddress(String(fields[1])),
           let brightness = UInt8(fields[2]), brightness <= 100 {
            do {
                try sendBrightness(destination: destination, brightness: brightness)
                reply(connection, "OK\n")
            } catch {
                lastError = error.localizedDescription
                if case BridgeError.bluetoothNotReady = error {
                    reply(connection, "ERR bluetooth_not_ready\n")
                } else {
                    reply(connection, "ERR command_failed\n")
                }
            }
            return
        }
        if fields.count == 4, fields[0] == "CCTB",
           let destination = parseAddress(String(fields[1])),
           let temperature = UInt16(fields[2]), (2000...6500).contains(temperature),
           let brightness = UInt8(fields[3]), brightness <= 100 {
            do {
                try sendColorTemperature(
                    destination: destination,
                    temperature: temperature,
                    brightness: brightness
                )
                reply(connection, "OK\n")
            } catch {
                lastError = error.localizedDescription
                if case BridgeError.bluetoothNotReady = error {
                    reply(connection, "ERR bluetooth_not_ready\n")
                } else {
                    reply(connection, "ERR command_failed\n")
                }
            }
            return
        }
        if fields.count == 5, fields[0] == "COLOR",
           let destination = parseAddress(String(fields[1])),
           let red = UInt8(fields[2]),
           let green = UInt8(fields[3]),
           let blue = UInt8(fields[4]) {
            do {
                try sendColor(
                    destination: destination,
                    red: red,
                    green: green,
                    blue: blue
                )
                reply(connection, "OK\n")
            } catch {
                lastError = error.localizedDescription
                if case BridgeError.bluetoothNotReady = error {
                    reply(connection, "ERR bluetooth_not_ready\n")
                } else {
                    reply(connection, "ERR command_failed\n")
                }
            }
            return
        }
        // Legacy encrypted-PDU transport retained for diagnostic compatibility.
        if fields.count == 2, fields[0] == "SEND",
           let pdu = Data(base64Encoded: String(fields[1])), (14...29).contains(pdu.count) {
            do {
                try writeProxyNetworkPDU(pdu)
                reply(connection, "OK\n")
            } catch {
                reply(connection, "ERR bluetooth_not_ready\n")
            }
            return
        }
        reply(connection, "ERR malformed\n")
    }

    private func parseAddress(_ value: String) -> UInt16? {
        if value.hasPrefix("0x") || value.hasPrefix("0X") {
            return UInt16(value.dropFirst(2), radix: 16)
        }
        return UInt16(value)
    }

    private func sendPower(destination: UInt16, isOn: Bool) throws {
        try sendVendor(destination: destination, opcode: 0xC3, parameters: Data([isOn ? 1 : 0]))
        lastCommands[destination] = isOn
        if destination == 0xC000 {
            lastCommands[0x0002] = isOn
            lastCommands[0x0003] = isOn
        }
    }

    private func sendBrightness(destination: UInt16, brightness: UInt8) throws {
        let parameters = Data([brightness]) + commandTimestamp()
        try sendVendor(destination: destination, opcode: 0xC4, parameters: parameters)
    }

    private func sendColorTemperature(
        destination: UInt16,
        temperature: UInt16,
        brightness: UInt8
    ) throws {
        try sendLightMode(destination: destination, mode: .temperature)
        let parameters = Data([
            UInt8(temperature & 0xFF),
            UInt8(temperature >> 8),
            brightness,
        ]) + commandTimestamp()
        try sendVendor(destination: destination, opcode: 0xD2, parameters: parameters)
    }

    private func sendColor(
        destination: UInt16,
        red: UInt8,
        green: UInt8,
        blue: UInt8
    ) throws {
        try sendLightMode(destination: destination, mode: .color)
        try sendVendor(
            destination: destination,
            opcode: 0xC6,
            parameters: Data([red, green, blue])
        )
    }

    private func sendLightMode(destination: UInt16, mode: LightMode) throws {
        try sendVendor(
            destination: destination,
            opcode: 0xCC,
            parameters: Data([mode.rawValue])
        )
    }

    private func commandTimestamp() -> Data {
        let timestamp = UInt32(Date().timeIntervalSince1970)
        return Data([
            UInt8(timestamp & 0xFF),
            UInt8((timestamp >> 8) & 0xFF),
            UInt8((timestamp >> 16) & 0xFF),
            UInt8(timestamp >> 24),
        ])
    }

    private func sendVendor(destination: UInt16, opcode: UInt8, parameters: Data) throws {
        guard isReady else { throw BridgeError.bluetoothNotReady }
        guard nextSequence <= 0xFFFFFF else { throw BridgeError.sequenceExhausted }
        let sequence = nextSequence
        nextSequence += 1
        try persistSequence()
        let pdu = try MeshCrypto.buildVendorNetworkPDU(
            networkKey: networkKey,
            applicationKey: applicationKey,
            source: 0x0100,
            destination: destination,
            sequence: sequence,
            ivIndex: 0,
            opcode: opcode,
            parameters: parameters
        )
        try writeProxyNetworkPDU(pdu)
        lastError = nil
    }

    private func persistSequence() throws {
        let data = try JSONEncoder().encode(SequenceEnvelope(nextSequence: nextSequence))
        try data.write(to: sequencePath, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sequencePath.path)
    }

    private func reply(_ connection: NWConnection, _ response: String) {
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
        isReady = false
        log("bluetooth_state \(Self.describe(central.state))")
        guard central.state == .poweredOn else {
            // Radio went away (powered off, reset, or access revoked); drop the
            // stale peripheral so recovery starts from a clean scan.
            cancelHandshakeWatchdog()
            dataIn = nil
            dataOut = nil
            peripheral = nil
            connectedProxy = nil
            lastError = "Bluetooth is \(Self.describe(central.state))"
            return
        }
        scan()
    }

    private static func describe(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn: "powered on"
        case .poweredOff: "powered off"
        case .unauthorized: "not authorized"
        case .unsupported: "unsupported"
        case .resetting: "resetting"
        default: "unknown"
        }
    }

    private func scan() {
        guard central.state == .poweredOn, peripheral == nil else { return }
        central.scanForPeripherals(withServices: [CBUUID(string: "1828")])
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        // Oasis Mesh proxies use the OASIS_ prefix. Avoid baking one home's
        // private proxy identifiers into the bridge or its distributable app.
        guard name.hasPrefix("OASIS_"), self.peripheral == nil else { return }
        self.peripheral = peripheral
        connectedProxy = name
        peripheral.delegate = self
        central.stopScan()
        log("proxy_discovered name=\(name) rssi=\(RSSI)")
        // connect(_:) has no timeout of its own, so the watchdog covers both a
        // connection that never lands and a handshake that never finishes.
        armHandshakeWatchdog()
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("proxy_connected name=\(connectedProxy ?? "unknown")")
        peripheral.discoverServices([CBUUID(string: "1828")])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        lastError = error?.localizedDescription
        log("proxy_connect_failed error=\(error?.localizedDescription ?? "none")")
        resetAndScan()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        lastError = error?.localizedDescription
        log("proxy_disconnected error=\(error?.localizedDescription ?? "none")")
        resetAndScan()
    }

    private func armHandshakeWatchdog() {
        cancelHandshakeWatchdog()
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, !isReady else { return }
            lastError = "Proxy handshake timed out after \(Int(Self.handshakeTimeout))s"
            log("handshake_timeout name=\(connectedProxy ?? "unknown")")
            resetAndScan(cancelCurrent: true)
        }
        handshakeWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.handshakeTimeout, execute: watchdog)
    }

    private func cancelHandshakeWatchdog() {
        handshakeWatchdog?.cancel()
        handshakeWatchdog = nil
    }

    private func resetAndScan(cancelCurrent: Bool = false) {
        cancelHandshakeWatchdog()
        isReady = false
        dataIn = nil
        dataOut = nil
        connectedProxy = nil
        if cancelCurrent, let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        let delay = retryDelay
        retryDelay = min(Self.maximumRetryDelay, retryDelay * 2)
        log("rescan_scheduled delay=\(Int(delay))s")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.scan() }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            lastError = error?.localizedDescription
            log("service_discovery_failed error=\(error?.localizedDescription ?? "none")")
            return resetAndScan(cancelCurrent: true)
        }
        let services = peripheral.services ?? []
        guard !services.isEmpty else {
            lastError = "Proxy advertised the mesh service but exposed none"
            log("service_discovery_empty name=\(connectedProxy ?? "unknown")")
            return resetAndScan(cancelCurrent: true)
        }
        for service in services {
            peripheral.discoverCharacteristics([CBUUID(string: "2ADD"), CBUUID(string: "2ADE")], for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil else {
            lastError = error?.localizedDescription
            log("characteristic_discovery_failed error=\(error?.localizedDescription ?? "none")")
            return resetAndScan(cancelCurrent: true)
        }
        // This fires once per service. Only record a hit, never overwrite a
        // characteristic already found on an earlier service with nil.
        if let found = service.characteristics?.first(where: { $0.uuid == CBUUID(string: "2ADD") }) {
            dataIn = found
        }
        if let found = service.characteristics?.first(where: { $0.uuid == CBUUID(string: "2ADE") }) {
            dataOut = found
            peripheral.setNotifyValue(true, for: found)
        }
        // Another service may still carry the write characteristic; if none
        // does, the handshake watchdog tears the connection down and rescans.
        guard dataIn != nil else { return }
        cancelHandshakeWatchdog()
        isReady = true
        lastError = nil
        retryDelay = Self.minimumRetryDelay
        print("bridge_ready proxy=\(connectedProxy ?? "OASIS") port=\(port.rawValue)")
        fflush(stdout)
    }

    private func writeProxyNetworkPDU(_ pdu: Data) throws {
        guard isReady, let peripheral, let dataIn else { throw BridgeError.bluetoothNotReady }
        let maximum = peripheral.maximumWriteValueLength(for: .withoutResponse)
        let payloadMaximum = max(1, maximum - 1)
        if pdu.count <= payloadMaximum {
            peripheral.writeValue(Data([0x00]) + pdu, for: dataIn, type: .withoutResponse)
            return
        }
        var offset = 0
        var isFirst = true
        while offset < pdu.count {
            let end = min(pdu.count, offset + payloadMaximum)
            let isLast = end == pdu.count
            let header: UInt8 = isFirst ? 0x40 : (isLast ? 0xC0 : 0x80)
            peripheral.writeValue(Data([header]) + pdu[offset..<end], for: dataIn, type: .withoutResponse)
            isFirst = false
            offset = end
        }
    }
}

if CommandLine.arguments.contains("--crypto-self-test") {
    let expected = Data(hex: "1cc8ea83a6760de41c10675036d1290e32997b7294de")!
    let actual = try MeshCrypto.buildPowerNetworkPDU(
        networkKey: Data(0..<16),
        applicationKey: Data(16..<32),
        source: 0x0100,
        destination: 0x0002,
        sequence: 0x1234,
        ivIndex: 0,
        isOn: true
    )
    guard actual == expected else {
        fputs("crypto_self_test_failed\n", stderr)
        exit(1)
    }
    print("crypto_self_test_ok")
} else if CommandLine.arguments.contains("--about") {
    print("Oasis Bridge 0.5.0 — headless service")
} else {
    let application = NSApplication.shared
    let isAuthorizing = CommandLine.arguments.contains("--authorize")
    application.setActivationPolicy(isAuthorizing ? .regular : .accessory)
    application.finishLaunching()
    if isAuthorizing {
        application.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Enable Oasis Bridge"
        alert.informativeText = "Continue to let macOS request Bluetooth access for the background bridge."
        alert.addButton(withTitle: "Continue")
        alert.runModal()
        application.setActivationPolicy(.accessory)
    }
    let bridge = OasisBridge()
    withExtendedLifetime(bridge) {
        application.run()
    }
}
