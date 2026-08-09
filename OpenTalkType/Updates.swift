import AppKit
import Foundation
import Observation
import Sparkle

// Automatic updates.
//
// Sparkle is the one third-party dependency in this app, and it earns the exception. The part
// that matters is not "download a zip" -- it is verifying an EdDSA signature against a key baked
// into the bundle before anything is installed, and swapping the bundle safely on quit. This app
// holds Accessibility permission, which is permission to observe every keystroke on the machine.
// A homemade updater with a subtle verification bug on top of that is not a bug, it is a backdoor.
//
// The signing key lives in the author's Keychain and in this repository's Actions secrets, and
// nowhere else. An update cannot be substituted even by someone who controls the download server.
// The FIRST install is a different question and is not solved here: it is unnotarised, and the
// README says so plainly.

extension Prefs {
    /// Mirrors Sparkle's own setting so the SwiftUI toggle has something to bind to. Sparkle owns
    /// the truth; this is the key it stores it under.
    static let automaticUpdates = "SUEnableAutomaticChecks"
}

@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController?

    /// False in a development build, where the whole Updates section is hidden rather than shown
    /// doing nothing. See `isInstalledCopy`.
    private(set) var isActive = false
    /// Drives the Check button's enabled state; Sparkle refuses overlapping checks.
    private(set) var canCheck = false

    private init() {
        guard Self.isInstalledCopy else {
            controller = nil
            return
        }
        // startingUpdater: true means Sparkle schedules its own checks according to the Info.plist
        // interval, but only once the user has turned them on -- SUEnableAutomaticChecks ships
        // false, so a fresh install phones nowhere until somebody asks it to.
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        isActive = true
        canCheck = controller?.updater.canCheckForUpdates ?? false
    }

    /// Only a copy running from a real Applications folder updates itself.
    ///
    /// A build in DerivedData has no business replacing itself: the feed would offer the released
    /// version as an "update" over a local build that is usually newer, and Sparkle would try to
    /// overwrite a bundle Xcode is about to rewrite anyway. Checking where we are running from is
    /// cruder than openusage's approach of baking the feed into release builds only, but it needs
    /// no second Info.plist and it cannot be got wrong by building the wrong configuration.
    private static var isInstalledCopy: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications")
            || Bundle.main.bundleURL.path.contains("/Applications/")
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// The version Sparkle last saw, for the About pane. Nil until a check has run.
    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }

    /// User-initiated. Sparkle brings its own window forward for this path, which is why the menu
    /// item and the settings button both route here rather than poking the scheduler.
    func checkForUpdates() {
        guard let controller else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
        canCheck = controller.updater.canCheckForUpdates
    }
}
