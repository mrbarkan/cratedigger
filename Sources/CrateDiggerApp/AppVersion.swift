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
    static let marketing = "1.0.0"
    /// Mirror of `CFBundleVersion`.
    static let build = "32"
    /// Release-channel label shown in About ("BETA", "RC", …). Empty for a
    /// final release — at which point the pill reverts to "VERSION x (build)".
    static let channel = "RC"

    /// Hard expiry for beta builds — on/after this date the app shows a notice
    /// and quits at launch. Bump per release; set to `nil` to disable.
    static let betaExpiry: Date? = {
        var components = DateComponents()
        components.year = 2026
        components.month = 12
        components.day = 31
        components.hour = 23
        components.minute = 59
        components.second = 59
        return Calendar(identifier: .gregorian).date(from: components)
    }()

    /// True once the current date has passed `betaExpiry`.
    static var isBetaExpired: Bool {
        guard let betaExpiry else { return false }
        return Date() > betaExpiry
    }

    /// Formats the About version pill, e.g. "VERSION 0.9.0 · BETA 1" or, once
    /// `channel` is empty, "VERSION 1.0.0 (1)". Callers pass the live bundle
    /// values (falling back to the compiled-in constants above).
    static func displayString(version: String, build: String) -> String {
        channel.isEmpty
            ? "VERSION \(version) (\(build))"
            : "VERSION \(version) · \(channel) \(build)"
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
}
