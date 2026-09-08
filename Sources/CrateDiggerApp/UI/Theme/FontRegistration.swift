import CoreText
import Foundation

public enum FontRegistrar {
    /// Register every TTF/OTF found under Fonts/ in the app bundle AND the SPM
    /// resource bundle (where `.copy("Resources/Fonts")` lands for both
    /// `swift run` and the packaged .app — see `Bundle.crateDiggerResources`).
    /// Safe to call when no fonts are found — `Font.custom` in
    /// CarbonTypography silently falls back to the system equivalents.
    public static func registerBundledFonts() {
        var urls: [URL] = []
        for bundle in Bundle.crateDiggerSearchBundles {
            urls += bundle.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
            urls += bundle.urls(forResourcesWithExtension: "otf", subdirectory: "Fonts") ?? []
            // A bundled theme carries its type in its own `Fonts/`, exactly as
            // a third-party `.cdtheme` does. The loader registers that folder
            // for *installed* themes only (it needs the manifest's source URL,
            // which a built-in origin doesn't carry), so the shipped ones are
            // picked up here, at launch, alongside the app's own faces.
            if let themes = bundle.resourceURL?.appendingPathComponent("Themes", isDirectory: true) {
                urls += bundledThemeFontURLs(under: themes)
            }
        }
        registerFonts(at: urls)
    }

    /// Every `*.cdtheme/Fonts/*.ttf|otf` under `themes`.
    static func bundledThemeFontURLs(under themes: URL) -> [URL] {
        let fm = FileManager.default
        guard let bundles = try? fm.contentsOfDirectory(at: themes, includingPropertiesForKeys: nil) else { return [] }
        return bundles
            .filter { $0.pathExtension.lowercased() == "cdtheme" }
            .flatMap { bundle -> [URL] in
                let fonts = bundle.appendingPathComponent("Fonts", isDirectory: true)
                let files = (try? fm.contentsOfDirectory(at: fonts, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles])) ?? []
                return files.filter { ["ttf", "otf"].contains($0.pathExtension.lowercased()) }
            }
    }

    /// Registers font files shipped inside an installed `.cdtheme`'s `Fonts/`
    /// subfolder (see `ThemeLoaderService.fontURLs(for:)`). Safe to call with
    /// an empty array; a name that fails to register just means `Font.custom`
    /// falls back to the system font, same as any other missing PostScript name.
    public static func registerFonts(at urls: [URL]) {
        guard !urls.isEmpty else { return }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true) { _, _ in true }
    }
}
