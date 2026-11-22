#if canImport(XCTest)
@testable import CrateDiggerCore
import SwiftUI
import XCTest
@testable import CrateDiggerApp

/// A Simple theme is self-contained: whatever theme it was started from, what the
/// editor previews and what the app draws once it is applied are the builder's own
/// colours, in LIGHT, DARK and BOTH, on either screen appearance. All four built-ins
/// are adaptive and set their own optional overrides (Llama '97 sets every one), so
/// they are the parents that would leak through.
///
/// The built-ins are copied into a temp Themes folder so APPLY has somewhere to write;
/// `selectedThemeID` is put back afterwards.
@MainActor
final class SimpleThemeSelfContainedTests: XCTestCase {
    private var themesDirectory: URL!
    private var registry: ThemeRegistry!
    private var savedSelection: String?

    private static let builtIns = ["carbon", "cobalt", "llama-97", "pocket"]
    private static let anchors = ["chassis", "paper", "ink", "orange", "oledSurface", "oledForeground"]
    private static let nord = ["#2E3440", "#3B4252", "#ECEFF4", "#88C0D0", "#BF616A"]

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedSelection = PreferencesStore.shared.selectedThemeID
        themesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleThemeSelfContainedTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: themesDirectory, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CrateDiggerApp/Resources/Themes", isDirectory: true)
        for name in try FileManager.default.contentsOfDirectory(atPath: source.path) where name.hasSuffix(".cdtheme") {
            try FileManager.default.copyItem(at: source.appendingPathComponent(name),
                                             to: themesDirectory.appendingPathComponent(name))
        }
        registry = ThemeRegistry(loader: ThemeLoaderService(bundles: [], userThemesDirectoryOverride: themesDirectory))
        XCTAssertEqual(Set(registry.manifests.map(\.id)).intersection(Self.builtIns).count, 4)
    }

    override func tearDownWithError() throws {
        PreferencesStore.shared.selectedThemeID = savedSelection
        if let themesDirectory { try? FileManager.default.removeItem(at: themesDirectory) }
        try super.tearDownWithError()
    }

    private func built(from parentID: String, _ mode: SimpleAppearanceMode,
                       palette: [String] = nord) throws -> ThemeDefinition {
        let parent = try XCTUnwrap(registry.manifest(for: parentID), parentID)
        let seed = registry.newSimpleSeed(from: parent)
        let state = SimpleThemeState(recipe: SimpleThemeRecipe(palette: palette))
        let choices = SimpleThemeChoices(appearance: mode, material: nil, coverLook: nil, fonts: [:])
        return SimpleThemeBuilder.build(state: state, choices: choices, onto: seed)
    }

    /// The builder's own colour for `key` as the app would draw it on `screen`.
    private func expected(_ key: String, in theme: ThemeDefinition,
                          on screen: ThemeDefinition.BaseAppearance) -> String? {
        let layer = theme.isAdaptive ? screen : theme.baseAppearance
        return theme.resolved(for: layer).colors?[key]
    }

    private func assertAnchors(_ drawn: CarbonTheme, match theme: ThemeDefinition,
                               on screen: ThemeDefinition.BaseAppearance, _ label: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        for key in Self.anchors {
            let token = ThemeTokenCatalog.allColorTokens.first { $0.key == key }!
            let got = drawn[keyPath: token.read].themeHexString
            guard let want = expected(key, in: theme, on: screen) else {
                XCTFail("builder wrote no \(key) — \(label)", file: file, line: line)
                continue
            }
            XCTAssertTrue(ThemeAuthoringService.colorsMatch(got, want),
                          "\(key): drawn \(got), built \(want) — \(label)", file: file, line: line)
        }
    }

    func testPreviewAndAppliedThemeDrawTheBuildersColoursOverEveryBuiltIn() throws {
        for parentID in Self.builtIns {
            for mode in [SimpleAppearanceMode.light, .dark, .both] {
                let theme = try built(from: parentID, mode)
                XCTAssertNil(theme.inherits, "\(parentID) \(mode): a Simple theme has no parent")
                XCTAssertEqual(theme.isAdaptive, mode == .both, "\(parentID) \(mode)")

                for screen in [ThemeDefinition.BaseAppearance.dark, .light] {
                    let preview = registry.previewTheme(for: theme, appearance: screen).theme
                    assertAnchors(preview, match: theme, on: screen, "preview \(parentID) \(mode) on \(screen)")
                }

                let id = try XCTUnwrap(try registry.applySimple(theme))
                let saved = try XCTUnwrap(registry.manifest(for: id))
                XCTAssertNil(saved.definition.inherits, "\(parentID) \(mode): saved file names a parent")
                XCTAssertEqual(saved.definition.isAdaptive, mode == .both, "\(parentID) \(mode) saved")
                for screen in [ThemeDefinition.BaseAppearance.dark, .light] {
                    let drawn = try XCTUnwrap(registry.resolvedTheme(for: id, appearance: screen)).theme
                    assertAnchors(drawn, match: theme, on: screen, "applied \(parentID) \(mode) on \(screen)")
                }
                XCTAssertTrue(registry.deleteTheme(saved))
            }
        }
    }

    /// Every token the app draws, read back from the rendered theme, so an override the
    /// parent sets (and Simple never writes) is measured exactly as it shows.
    private func drawnTokens(_ theme: CarbonTheme) -> [String: String] {
        var tokens: [String: String] = [:]
        for token in ThemeTokenCatalog.allColorTokens {
            tokens[token.key] = theme[keyPath: token.read].themeHexString
        }
        return tokens
    }

    func testFloorsHoldOnTheDrawnPreviewOverLlama97() throws {
        let parent = try XCTUnwrap(registry.manifest(for: "llama-97"))
        for palette in [Self.nord, ["#1B1D22", "#FF6A13"], ["#FBF7F0", "#E8D8C4", "#6B5B4E", "#F2A7A0"]] {
            for contrast in SimpleContrast.allCases {
                var state = SimpleThemeState(recipe: SimpleThemeRecipe(palette: palette))
                state.contrast = contrast
                for mode in [SimpleAppearanceMode.light, .dark, .both] {
                    let choices = SimpleThemeChoices(appearance: mode, material: nil, coverLook: nil, fonts: [:])
                    let theme = SimpleThemeBuilder.build(state: state, choices: choices,
                                                         onto: registry.newSimpleSeed(from: parent))
                    for screen in [ThemeDefinition.BaseAppearance.dark, .light] {
                        let tokens = drawnTokens(registry.previewTheme(for: theme, appearance: screen).theme)
                        for pair in ContrastFloors.pairs(contrast: contrast) {
                            let label = "\(palette.count) colours \(contrast) \(mode) on \(screen): "
                                + "\(pair.foreground) on \(pair.background)"
                            let ratio = try XCTUnwrap(ContrastFloors.ratio(of: pair, in: tokens), label)
                            XCTAssertGreaterThanOrEqual(ratio, pair.minimum, label)
                        }
                    }
                }
            }
        }
    }

    /// Simple writes no optional override, so the parent's (Llama's red key LEDs, its
    /// green column headers) never reach a Simple theme: they follow the new accent and inks.
    func testNoOverrideOfTheParentSurvives() throws {
        let theme = try built(from: "llama-97", .both)
        for screen in [ThemeDefinition.BaseAppearance.dark, .light] {
            let drawn = registry.previewTheme(for: theme, appearance: screen).theme
            XCTAssertEqual(drawn.keyLamp.themeHexString, drawn.orange.themeHexString, "keyLamp \(screen)")
            XCTAssertEqual(drawn.transportLamp.themeHexString, drawn.orange.themeHexString, "transportLamp \(screen)")
            XCTAssertEqual(drawn.meterHot.themeHexString, drawn.orange.themeHexString, "meterHot \(screen)")
            XCTAssertEqual(drawn.columnHeaderInk.themeHexString, drawn.ink3.themeHexString, "columnHeaderInk \(screen)")
            XCTAssertEqual(drawn.chassisInk.themeHexString, drawn.ink2.themeHexString, "chassisInk \(screen)")
        }
    }
}
#endif
