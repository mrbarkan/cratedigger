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
    static let marketing = "0.9.0"
    /// Mirror of `CFBundleVersion`.
    static let build = "1"
    /// Release-channel label shown in About ("BETA", "RC", …). Empty for a
    /// final release — at which point the pill reverts to "VERSION x (build)".
    static let channel = "BETA"

    /// Formats the About version pill, e.g. "VERSION 0.9.0 · BETA 1" or, once
    /// `channel` is empty, "VERSION 1.0.0 (1)". Defaults to the compiled-in
    /// values but accepts the live bundle values when packaged.
    static func displayString(version: String = marketing, build: String = AppVersion.build) -> String {
        channel.isEmpty
            ? "VERSION \(version) (\(build))"
            : "VERSION \(version) · \(channel) \(build)"
    }
}
