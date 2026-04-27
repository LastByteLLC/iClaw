#if !MAS_BUILD
import Foundation
import Observation
import Sparkle

/// Manages Sparkle auto-updates for DMG builds.
///
/// MAS builds don't include the Sparkle dependency, so this file
/// compiles to nothing via `#if canImport(Sparkle)`.
/// The updater checks `https://geticlaw.com/appcast.xml` for new versions.
@MainActor
@Observable
final class UpdaterManager {
    static let shared = UpdaterManager()

    let updaterController: SPUStandardUpdaterController

    /// Whether the updater can check for updates right now.
    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }

    private init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Manually trigger an update check (from Settings → About).
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
#endif
