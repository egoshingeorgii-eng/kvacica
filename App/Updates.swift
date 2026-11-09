import AppKit
import Sparkle

/// Updates for the Mac app people download from GitHub: Sparkle checks the release feed once a
/// day and on "Check for Updates…", downloads the new DMG, checks its EdDSA signature
/// (SUPublicEDKey in project.yml) and installs it. Only a build that names a feed
/// (`SUFeedURL`, added by make-dmg.sh --no-icloud and the public repo's project.yml) updates
/// itself: the iCloud build from run.sh must never be replaced by one without iCloud.
@MainActor
enum Updates {
    static let isOn = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil

    /// A scheduled check found a version the learner hasn't been shown yet: the menu bar menu says so.
    static var available = false

    private static let delegate = Delegate()
    private static var controller: SPUStandardUpdaterController?

    /// At launch: starts the daily checks.
    static func start() {
        guard isOn, controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: delegate)
    }

    static func check() {
        available = false
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    /// A menu-bar app has no Dock icon to bounce: a scheduled check doesn't pop a window over
    /// whatever the learner is doing, it marks the menu instead ("gentle reminders").
    private final class Delegate: NSObject, SPUStandardUserDriverDelegate {
        var supportsGentleScheduledUpdateReminders: Bool { true }

        func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
            immediateFocus
        }

        func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
            if !handleShowingUpdate { MainActor.assumeIsolated { Updates.available = true } }
        }

        func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
            MainActor.assumeIsolated { Updates.available = false }
        }
    }
}
