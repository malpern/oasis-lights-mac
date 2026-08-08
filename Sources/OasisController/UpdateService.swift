import Foundation
import Observation
import Sparkle

@MainActor
@Observable
final class UpdateService {
    static let shared = UpdateService()

    @ObservationIgnored private let updaterController: SPUStandardUpdaterController

    private(set) var canCheckForUpdates: Bool
    private(set) var lastUpdateCheckDate: Date?

    var automaticallyChecksForUpdates: Bool {
        didSet {
            guard updaterController.updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates else {
                return
            }
            updaterController.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
            synchronize()
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        didSet {
            guard updaterController.updater.automaticallyDownloadsUpdates != automaticallyDownloadsUpdates else {
                return
            }
            updaterController.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
            synchronize()
        }
    }

    private init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        let updater = updaterController.updater
        canCheckForUpdates = updater.canCheckForUpdates
        lastUpdateCheckDate = updater.lastUpdateCheckDate
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
        synchronize()
    }

    func synchronize() {
        let updater = updaterController.updater
        canCheckForUpdates = updater.canCheckForUpdates
        lastUpdateCheckDate = updater.lastUpdateCheckDate
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
    }
}

extension Bundle {
    /// Read from the bundle so the About panel cannot drift from Info.plist.
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}
