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

        let urls = ttfURLs + otfURLs
        guard !urls.isEmpty else { return }

        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true) { _, _ in true }
    }
}
