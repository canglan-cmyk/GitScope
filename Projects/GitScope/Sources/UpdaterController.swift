import AppKit
import Sparkle

/// Thin wrapper around Sparkle's standard updater. Owns the updater for the
/// app's lifetime and exposes a menu-friendly check action.
@MainActor
final class UpdaterController {

    static let shared = UpdaterController()

    private let controller: SPUStandardUpdaterController

    private init() {
        // Standard controller: automatic background checks per Info.plist
        // (SUEnableAutomaticChecks), standard Sparkle UI for prompts.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Starts Sparkle. Call once at launch; the shared instance keeps the
    /// updater alive.
    func start() {
        // Initialization happens in init; this exists to make the launch
        // call site explicit.
    }

    @objc func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }

    /// Menu item validation comes for free when the menu action targets the
    /// updater itself.
    var menuTarget: SPUStandardUpdaterController { controller }
}
