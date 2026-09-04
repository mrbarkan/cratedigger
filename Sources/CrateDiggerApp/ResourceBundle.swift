import Foundation

extension Bundle {
    /// This target's SwiftPM resource bundle (fonts, themes, starter album),
    /// or `nil` when it isn't there.
    ///
    /// Deliberately **not** `Bundle.module`. For an *executable* target SwiftPM
    /// generates an accessor that looks in exactly two places — next to the
    /// binary (`Bundle.main.bundleURL`) and the absolute `.build` path of the
    /// machine that compiled it — then `fatalError`s. A packaged `.app` keeps
    /// the bundle in `Contents/Resources`, which is neither, so `.module`
    /// trapped on every launch of the shipped app (the 1.5.5 crash-on-launch).
    ///
    /// Scanning for `*.bundle` instead of naming it also survives a package
    /// rename, and returning `nil` degrades to system fonts / no built-in
    /// themes rather than killing the app.
    static let crateDiggerResources: Bundle? = crateDiggerResourceBundles.first

    /// **Every** resource bundle beside the binary, in a stable order.
    ///
    /// A `swift build` tree can hold several: the app's own, plus one per test
    /// target the moment anyone runs the suite. `contentsOfDirectory` returns
    /// them in filesystem order, so picking the first match handed callers
    /// `CrateDigger_CrateDiggerCoreTests.bundle` — which carries no Fonts —
    /// and every custom face silently fell back to the system font for the
    /// rest of the session. Search them all instead of guessing which one.
    static let crateDiggerResourceBundles: [Bundle] = resourceBundles(
        searching: [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap { $0 }
    )

    /// The app bundle plus the resource bundle, for the callers that have to
    /// look in both because which one holds a resource depends on how the app
    /// was launched (`swift run` vs. a packaged `.app`).
    static var crateDiggerSearchBundles: [Bundle] {
        [Bundle.main] + crateDiggerResourceBundles
    }

    static func resourceBundle(searching bases: [URL]) -> Bundle? {
        resourceBundles(searching: bases).first
    }

    /// Every `*.bundle` under `bases`, deduplicated, with test bundles last.
    ///
    /// Ordering is by name so a given tree always resolves the same way, and
    /// anything ending in `Tests.bundle` sorts to the back: it is a real
    /// resource bundle, but never the one a caller asking for the app's fonts
    /// or themes means.
    static func resourceBundles(searching bases: [URL]) -> [Bundle] {
        let fileManager = FileManager.default
        var seen: Set<String> = []
        var found: [URL] = []
        for base in bases {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: base,
                includingPropertiesForKeys: nil
            ) else { continue }
            for entry in entries where entry.pathExtension == "bundle" {
                if seen.insert(entry.standardizedFileURL.path).inserted { found.append(entry) }
            }
        }
        return found
            .sorted { left, right in
                let leftIsTests = left.lastPathComponent.hasSuffix("Tests.bundle")
                let rightIsTests = right.lastPathComponent.hasSuffix("Tests.bundle")
                if leftIsTests != rightIsTests { return rightIsTests }
                return left.lastPathComponent < right.lastPathComponent
            }
            .compactMap { Bundle(url: $0) }
    }
}
