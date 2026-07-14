import CoreText
import Foundation

public enum FontRegistrar {
    /// Register every TTF/OTF found under Resources/Fonts/ in the app bundle.
    /// Safe to call when no fonts are bundled — it becomes a no-op and `Font.custom`
    /// in CarbonTypography silently falls back to the system equivalents.
    public static func registerBundledFonts() {
        let bundle = Bundle.main

        let ttfURLs = bundle.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
        let otfURLs = bundle.urls(forResourcesWithExtension: "otf", subdirectory: "Fonts") ?? []

        registerFonts(at: ttfURLs + otfURLs)
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
