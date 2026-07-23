import Foundation

/// Single compiled-in source of truth for the app version, used by the About
/// screen so a debug / `swift build` run — which has no embedded Info.plist —
/// still shows the real number instead of the bundle-key fallback ("0.1.0").
///
/// The packaged `.app` carries these same values in
/// `Packaging/CrateDiggerApp/Info.plist`, which stays canonical for Finder,
/// notarization, and the DMG name. Keep the two in sync; the constants below
/// are only the fallback the About pill uses when no bundle plist is present.
enum AppVersion {
    /// Mirror of `CFBundleShortVersionString`.
    static let marketing = "1.1.0"
    /// Mirror of `CFBundleVersion`.
    static let build = "44"
    /// Release-channel label shown in About ("BETA", "RC", …). Empty for a
    /// final release — at which point the pill reverts to "VERSION x (build)".
    static let channel = ""
    /// Human ordinal within the channel ("RC 3"), hand-bumped per release
    /// alongside `build` — the build number is monotonic across the whole
    /// beta/RC run, so it can't double as the ordinal (RC 3 = build 33).
    /// Unused once `channel` is empty (the final release).
    static let channelOrdinal = "1"

    /// Hard expiry for beta builds — on/after this date the app shows a notice
    /// and quits at launch. `nil` disables it: a shipping final release must
    /// never brick itself, so 1.0.0 carries no expiry.
    static let betaExpiry: Date? = nil

    /// True once the current date has passed `betaExpiry`.
    static var isBetaExpired: Bool {
        guard let betaExpiry else { return false }
        return Date() > betaExpiry
    }

    /// Formats the About version pill, e.g. "VERSION 1.0.0 · RC 3 (33)" or,
    /// once `channel` is empty, "VERSION 1.0.0 (33)". Callers pass the live
    /// bundle values (falling back to the compiled-in constants above).
    static func displayString(version: String, build: String) -> String {
        channel.isEmpty
            ? "VERSION \(version) (\(build))"
            : "VERSION \(version) · \(channel) \(channelOrdinal) (\(build))"
    }

    /// The version pill for the current process: live bundle values when an
    /// Info.plist is present (packaged app), else the compiled-in constants
    /// (a bare `swift build` run). Single source for About and the splash.
    static var currentDisplayString: String {
        let bundle = Bundle.main
        let liveVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? marketing
        let liveBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? build
        return displayString(version: liveVersion, build: liveBuild)
    }

    /// The running app as a semver string the update checker can compare
    /// against GitHub release tags. Convention: prerelease tags carry the
    /// BUILD number as the prerelease number (v1.0.0-rc.33 = build 33), so
    /// channel + build reconstructs the tag exactly. Keep release tags on
    /// that convention or update checks will misorder.
    static var currentSemverString: String {
        let bundle = Bundle.main
        let liveVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? marketing
        let liveBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? build
        return channel.isEmpty ? liveVersion : "\(liveVersion)-\(channel.lowercased()).\(liveBuild)"
    }
}
