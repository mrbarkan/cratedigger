import AppKit
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

/// Keeps prerelease builds on prerelease updates and everyone else on stable.
///
/// A prerelease build declares a channel (`AppVersion.channel = "RC"`), which
/// matches the `<sparkle:channel>rc</sparkle:channel>` the release script
/// writes onto prerelease appcast items. A final release allows no channel at
/// all, so it is only ever offered stable releases — the same rule the GitHub
/// feed check used before Sparkle replaced it.
///
/// **The v2 beta line does not rely on this.** It is isolated one level up, at
/// the feed: this branch's `SUFeedURL` points at `appcast-beta.xml`, which no
/// shipped 1.5.x app has ever heard of, so a beta release cannot reach a
/// stable user even if its channel tag were wrong. The declared BETA channel
/// is what labels the About pill and builds the `v2.0.0-beta.<build>` tag.
private final class ChannelDelegate: NSObject, SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        AppVersion.channel.isEmpty ? [] : [AppVersion.channel.lowercased()]
    }
}
