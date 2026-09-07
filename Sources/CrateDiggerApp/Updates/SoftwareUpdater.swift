import AppKit
import CrateDiggerCore
import Sparkle

/// In-app updates, start to finish: Sparkle reads the appcast, verifies the
/// EdDSA signature on the download, swaps the app in place and relaunches it.
///
/// It's the app's only third-party dependency, and it's here rather than
/// hand-rolled because every step of a self-update is a security decision —
/// who signed this download, is it really newer, can it be written where the
/// app lives — and the home-made version of any of them is the kind of code
/// you find out is wrong after it has already replaced someone's app.
///
/// **Only the packaged app updates itself.** `SUFeedURL` and `SUPublicEDKey`
/// live in `Packaging/CrateDiggerApp/Info.plist`, so a bare `swift build` run
/// has no feed and no key: the updater is never created and "Check for
/// Updates…" greys out instead of failing in a way nobody can read.
@MainActor
final class SoftwareUpdater {
    static let shared = SoftwareUpdater()

    private let controller: SPUStandardUpdaterController?
    private let channels: ChannelDelegate

    private init() {
        let channels = ChannelDelegate()
        self.channels = channels
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String else {
            controller = nil
            return
        }
        // `startingUpdater: true` also starts the scheduled background check
        // (SUEnableAutomaticChecks / SUScheduledCheckInterval in Info.plist),
        // which is why nothing else has to poll at launch.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: channels,
            userDriverDelegate: nil
        )
    }

    /// False in development builds, and while a check is already running —
    /// `validateMenuItem` uses it to grey the menu item out.
    var canCheckForUpdates: Bool {
        controller?.updater.canCheckForUpdates ?? false
    }

    /// The user asked. Sparkle takes it from here, including the "you're up to
    /// date" answer.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

/// Which appcast a given build reads.
///
/// Split out from the delegate and kept pure so it can be tested: this one
/// branch decides who is offered a prerelease, and getting it backwards would
/// hand an untested build to people who never asked for one.
enum UpdateFeed {
    /// Mirrors `SUFeedURL` in `Packaging/CrateDiggerApp/Info.plist`, which is
    /// what a build falls back to when nothing here overrides it.
    static let stable = "https://cratedigger.mrbarkan.com/appcast.xml"

    /// The 2.0 beta line. Published from the `v2` branch and deliberately a
    /// separate file, so a beta release never rewrites the feed stable copies
    /// read.
    static let beta = "https://cratedigger.mrbarkan.com/appcast-beta.xml"

    /// The feed to hand Sparkle, or `nil` to leave it on the Info.plist one.
    ///
    /// Beta applies in exactly two cases: the build is itself a prerelease
    /// (`AppVersion.channel` is set, so it must keep following the line it came
    /// from), or somebody deliberately turned the setting on. A stable build
    /// that has been left alone always returns `nil`.
    static func override(channel: String, betaOptIn: Bool) -> String? {
        (!channel.isEmpty || betaOptIn) ? beta : nil
    }
}

/// Points the updater at the right feed, and keeps prerelease builds on
/// prerelease updates.
///
/// Isolation is at the **feed**, not at a channel tag inside a shared one. A
/// beta is published into `appcast-beta.xml`, which a stable build never reads
/// unless its owner ticked Advanced ▸ Receive beta updates, so a mistake in a
/// beta release has no route to somebody who left that alone.
///
/// `allowedChannels` stays for the older `rc` convention, where prerelease
/// items were tagged inside the stable feed.
private final class ChannelDelegate: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        UpdateFeed.override(
            channel: AppVersion.channel,
            betaOptIn: PreferencesStore.shared.betaUpdatesEnabled
        )
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        AppVersion.channel.isEmpty ? [] : [AppVersion.channel.lowercased()]
    }
}
