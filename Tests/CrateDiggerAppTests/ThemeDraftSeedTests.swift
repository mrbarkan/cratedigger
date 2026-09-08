#if canImport(XCTest)
import CrateDiggerCore
import SwiftUI
import XCTest
@testable import CrateDiggerApp

/// Opening the editor must not change what is on screen.
///
/// The editor has no separate preview surface — the draft *is* the running
/// app's theme — so the seeded draft has to render identically to the theme it
/// was seeded from, in both looks. It didn't: an adaptive theme's shared token
/// set was filled from a single render of its declared appearance, so every
/// token the *other* layer left unset picked up the wrong stock defaults and
/// half the window repainted the moment you pressed EDIT.
final class ThemeDraftSeedTests: XCTestCase {

    private var manifests: [ThemeManifest] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CrateDiggerAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/CrateDiggerApp/Resources/Themes", isDirectory: true)
        manifests = ThemeLoaderService(bundles: [], userThemesDirectoryOverride: directory)
            .discoverThemes()
            .themes
        XCTAssertFalse(manifests.isEmpty)
    }

    func testSeedingAShippedThemeChangesNoColorInEitherLook() {
        for manifest in manifests {
            let seeded = ThemeRegistry.seeded(manifest.definition)
            for appearance in [ThemeDefinition.BaseAppearance.light, .dark] {
                let before = rendered(manifest.definition, for: appearance)
                let after = rendered(seeded, for: appearance)
                for token in ThemeTokenCatalog.allColorTokens {
                    XCTAssertEqual(
                        after[keyPath: token.read].themeHexString,
                        before[keyPath: token.read].themeHexString,
                        "\(manifest.id) · \(appearance.rawValue) · \(token.key) moved when the editor opened"
                    )
                }
            }
        }
    }

    /// The seed is also what "has the author touched this?" is measured
    /// against, so a freshly opened draft has to report no changes at all.
    func testAFreshDraftHasChangedNothing() {
        for manifest in manifests {
            let seeded = ThemeRegistry.seeded(manifest.definition)
            let rendered = manifest.definition.merging(seeded.tokensChanged(from: seeded))
            XCTAssertEqual(rendered.colors, manifest.definition.colors, "\(manifest.id)")
        }
    }

    private func rendered(_ definition: ThemeDefinition,
                          for appearance: ThemeDefinition.BaseAppearance) -> CarbonTheme {
        let flattened = definition.resolved(for: appearance)
        let base: CarbonTheme = flattened.baseAppearance == .dark ? .carbon : .linen
        return CarbonTheme(definition: flattened, resolvedBase: base)
    }
}
#endif
