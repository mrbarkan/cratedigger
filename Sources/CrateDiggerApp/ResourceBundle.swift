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
    static let crateDiggerResources: Bundle? = resourceBundle(
        searching: [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap { $0 }
    )

    /// The app bundle plus the resource bundle, for the callers that have to
    /// look in both because which one holds a resource depends on how the app
    /// was launched (`swift run` vs. a packaged `.app`).
    static var crateDiggerSearchBundles: [Bundle] {
        [Bundle.main, .crateDiggerResources].compactMap { $0 }
    }

    static func resourceBundle(searching bases: [URL]) -> Bundle? {
        let fileManager = FileManager.default
        for base in bases {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: base,
                includingPropertiesForKeys: nil
            ) else { continue }
            for entry in entries where entry.pathExtension == "bundle" {
                if let bundle = Bundle(url: entry) { return bundle }
            }
        }
        return nil
    }
}
