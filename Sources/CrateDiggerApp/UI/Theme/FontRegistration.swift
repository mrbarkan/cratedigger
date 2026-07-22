import CoreText
import Foundation

public enum FontRegistrar {
    /// Register every TTF/OTF found under Fonts/ in the app bundle AND the SPM
    /// resource bundle (`Bundle.module` — where `.copy("Resources/Fonts")`
    /// lands for both `swift run` and the packaged .app). Safe to call when no
    /// fonts are found — `Font.custom` in CarbonTypography silently falls back
    /// to the system equivalents.
    public static func registerBundledFonts() {
        var urls: [URL] = []
        for bundle in [Bundle.main, Bundle.module] {
            urls += bundle.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
            urls += bundle.urls(forResourcesWithExtension: "otf", subdirectory: "Fonts") ?? []
        }
        registerFonts(at: urls)
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
