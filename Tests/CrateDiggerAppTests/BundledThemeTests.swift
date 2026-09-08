#if canImport(XCTest)
import CoreText
import CrateDiggerCore
import SwiftUI
import XCTest
@testable import CrateDiggerApp

/// The four themes that ship with the app, read from the source folder they're
/// edited in.
///
/// A theme is data, so nothing in the compiler notices when a key is misspelt,
/// a hex is malformed, or a layer stops overriding what it used to — the app
/// just quietly renders the built-in default instead. These pin the parts that
/// would otherwise only be caught by looking at the window.
final class BundledThemeTests: XCTestCase {

    private var themes: [String: ThemeDefinition] = [:]
    private var manifests: [String: ThemeManifest] = [:]

    override func setUpWithError() throws {
        try super.setUpWithError()
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CrateDiggerAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/CrateDiggerApp/Resources/Themes", isDirectory: true)

        let result = ThemeLoaderService(bundles: [], userThemesDirectoryOverride: directory)
            .discoverThemes()

        XCTAssertEqual(result.warnings.map(\.message), [], "a bundled theme failed to parse")
        themes = Dictionary(uniqueKeysWithValues: result.themes.map { ($0.id, $0.definition) })
        manifests = Dictionary(uniqueKeysWithValues: result.themes.map { ($0.id, $0) })
    }

    /// Every shipped theme follows the app's Light/Dark setting — Linen was
    /// folded into Carbon as its light layer precisely so none of them force an
    /// appearance on the user any more.
    func testEveryBundledThemeCarriesBothAppearances() {
        XCTAssertFalse(themes.isEmpty)
        for (id, definition) in themes {
            XCTAssertTrue(definition.isAdaptive, "\(id) is missing a light or dark layer")
        }
    }

    /// Every shipped theme has a mark for each look, drawn by
    /// `scripts/render-theme-logos.swift`, and each file is a real image the
    /// header can draw at the slot's proportion.
    func testEveryBundledThemeShipsALogoPerLayer() throws {
        for (id, manifest) in manifests {
            for appearance in [ThemeDefinition.BaseAppearance.light, .dark] {
                let url = try XCTUnwrap(manifest.logoURL(for: appearance), "\(id) has no \(appearance) logo")
                let image = try XCTUnwrap(NSImage(contentsOf: url), "\(url.lastPathComponent) did not load")
                XCTAssertEqual(image.size.width / image.size.height, 5.5, accuracy: 0.01, "\(id): not the slot's shape")
            }
        }
    }

    func testLinenIsGoneAndCarbonRendersBothLooks() throws {
        XCTAssertNil(themes["linen"], "Linen is Carbon's light layer now, not a theme of its own")

        let carbon = try XCTUnwrap(themes["carbon"])
        XCTAssertLessThan(render(carbon, .dark).chassis.themeLuminance, 0.2)
        XCTAssertGreaterThan(render(carbon, .light).chassis.themeLuminance, 0.8)
    }

    /// The screen is the skin's signature: black glass running phosphor green,
    /// and the *same* green in both looks — the console being tributed has one
    /// readout, not a different one per appearance. The light layer used to
    /// switch it to white type; it doesn't any more, and the two layers now
    /// differ in their chrome (slate at night, silver by day) rather than in
    /// what the screen says. The glass is a shared token, so a layer that
    /// started overriding it would light it in exactly one appearance and
    /// nobody would notice until they switched.
    func testLlamaScreenIsGreenOnBlackInBothAppearances() throws {
        let llama = try XCTUnwrap(themes["llama-97"])
        for appearance in [ThemeDefinition.BaseAppearance.light, .dark] {
            let rendered = render(llama, appearance)
            XCTAssertEqual(rendered.oledSurface.themeHexString, "#000000", "\(appearance)")
            XCTAssertEqual(rendered.oledForeground.themeHexString, "#00FF00", "\(appearance)")
        }
    }

    /// The light layer is the skin as it shipped: silver bevels that are
    /// actually bevelled, and the navy bar under a selected row straight out of
    /// `pledit.txt`. Both were inverted or purple while the layer was being
    /// rebuilt, and a highlight darker than the face it sits on is the kind of
    /// thing you only see by looking at the window.
    func testLlamaLightIsSilverWithARaisedBevel() throws {
        let light = render(try XCTUnwrap(themes["llama-97"]), .light)
        XCTAssertGreaterThan(light.chassisHi.themeLuminance, light.chassis.themeLuminance,
                             "the bevel highlight has to be lighter than the face")
        XCTAssertLessThan(light.chassisLo.themeLuminance, light.chassis.themeLuminance,
                          "and its shadow darker")
        XCTAssertLessThan(light.wellDeep.themeLuminance, light.well.themeLuminance,
                          "a recess gets darker toward the bottom")
        XCTAssertEqual(light.selectionSpread.themeHexString, "#0000C6", "pledit.txt SelectedBG")
    }

    /// A shipped theme may only name type the app is responsible for: a face
    /// inside its own `Fonts/` folder, one of the faces `CarbonFont` itself
    /// defaults to, or one macOS installs everywhere. Llama '97 used to name
    /// `Ndot57CapsRegular`, a font that existed on the author's machine and
    /// nowhere else, so every other copy of the app drew its screen in the
    /// system font and nobody could tell from the code.
    ///
    /// The `CarbonFont` defaults are allowed by name, not by presence: Inter and
    /// JetBrains Mono are the app's own vocabulary, and whether the app actually
    /// ships them is a question about `Resources/Fonts`, not about a theme.
    func testEveryFaceABundledThemeNamesIsOneItShips() throws {
        let appDefaults: Set<String> = [
            CarbonFont.sansFamily, CarbonFont.sansMedium, CarbonFont.sansSemibold,
            CarbonFont.sansBold, CarbonFont.sansExtraBold,
            CarbonFont.monoFamily, CarbonFont.monoMedium, CarbonFont.monoSemibold, CarbonFont.monoBold,
            CarbonFont.displayFamily,
        ]
        for (id, manifest) in manifests {
            guard let fonts = manifest.definition.fonts, !fonts.isEmpty else { continue }
            guard case .userInstalled(let manifestURL) = manifest.origin else { continue }
            let bundled = Set(
                FontRegistrar.bundledThemeFontURLs(under: manifestURL.deletingLastPathComponent().deletingLastPathComponent())
                    .filter { $0.path.hasPrefix(manifestURL.deletingLastPathComponent().path) }
                    .flatMap(postScriptNames)
            )
            for (role, font) in fonts {
                let faces = [font.regular, font.light, font.medium, font.semibold, font.bold].compactMap { $0 }
                for face in faces {
                    let shipped = bundled.contains(face) || appDefaults.contains(face)
                    // CoreText never fails to make a font — it substitutes. The
                    // name coming back unchanged is what says the face exists.
                    let installed = CTFontCopyPostScriptName(CTFontCreateWithName(face as CFString, 12, nil)) as String == face
                    XCTAssertTrue(shipped || installed,
                                  "\(id) · \(role) names \(face), which is neither in its Fonts/ folder nor installed by macOS")
                }
            }
        }
    }

    /// Llama ships four faces, and the launch registrar has to be able to find
    /// them — it is the only path that registers a *bundled* theme's fonts.
    func testLlamaShipsItsPixelFaces() throws {
        let llama = try XCTUnwrap(manifests["llama-97"])
        guard case .userInstalled(let manifestURL) = llama.origin else { return XCTFail("loaded from disk") }
        let themes = manifestURL.deletingLastPathComponent().deletingLastPathComponent()
        let names = Set(FontRegistrar.bundledThemeFontURLs(under: themes).flatMap(postScriptNames))
        for face in ["Silkscreen-Regular", "Silkscreen-Bold", "PixelOperatorMono8", "PixelOperatorMono8-Bold"] {
            XCTAssertTrue(names.contains(face), "\(face) is not in Llama 97.cdtheme/Fonts")
        }
    }

    private func postScriptNames(_ url: URL) -> [String] {
        ((CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]) ?? [])
            .compactMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }
    }

    private func render(
        _ definition: ThemeDefinition,
        _ appearance: ThemeDefinition.BaseAppearance
    ) -> CarbonTheme {
        let resolved = definition.resolved(for: appearance)
        return CarbonTheme(definition: resolved, resolvedBase: appearance == .dark ? .carbon : .linen)
    }
}
#endif
