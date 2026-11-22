#if canImport(XCTest)
import AppKit
import CrateDiggerCore
import SwiftUI
import XCTest
@testable import CrateDiggerApp

/// Writes a contact sheet of generated Simple themes, so palette to theme
/// generation can be judged by eye. Skipped unless `CRATEDIGGER_SIMPLE_SHEETS`
/// is set to the output folder:
///
/// ```
/// CRATEDIGGER_SIMPLE_SHEETS=/some/dir scripts/test.sh --filter SimpleThemeContactSheetTests
/// ```
///
/// Every picture is built the way the editor builds one: NEW from Carbon
/// (`ThemeRegistry.newSimpleSeed`), `SimpleThemeBuilder.build`, drawn by
/// `ThemeRegistry.previewTheme`. Files are
/// `<n>-<palette>-<both|light|dark>-on-<dark|light>[-shuffle<k>].png` at 1x: BOTH on
/// each screen, then LIGHT shown while the screen is dark and DARK while it is light
/// (a single-appearance theme must draw itself whatever the screen). Plus one
/// `<n>-<palette>-sheet.png` per palette with every picture in a grid.
@MainActor
final class SimpleThemeContactSheetTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FontRegistrar.registerBundledFonts()
        BusySignalSnapshotTests.registerSourceFonts()
        ThemePreviewSnapshotTests.registerThemeFonts()
        ThemePreviewCoverStore.sampleCoverOverride = BusySignalSnapshotTests.repoRoot
            .appendingPathComponent("Sources/CrateDiggerApp/Resources/StarterCrate/cover.png")
    }

    private struct Palette {
        let slug: String
        let colors: [String]
        var assignment: [ThemeJob: Int?] = [:]
        var shuffles = 0
    }

    private static let palettes: [Palette] = [
        Palette(slug: "nord", colors: ["#2E3440", "#3B4252", "#ECEFF4", "#88C0D0", "#BF616A"], shuffles: 3),
        Palette(slug: "two-colours", colors: ["#1B1D22", "#FF6A13"]),
        Palette(slug: "pastel-light", colors: ["#FBF7F0", "#E8D8C4", "#6B5B4E", "#F2A7A0"]),
        Palette(slug: "neon", colors: ["#0A0A12", "#FF00AA", "#00FFD1", "#FAFF00"]),
        Palette(slug: "mono-greys", colors: ["#222222", "#2A2A2A", "#DDDDDD"]),
        Palette(slug: "forest", colors: ["#1F2D24", "#3E5641", "#A3B18A", "#DAD7CD", "#E9C46A", "#BC4749"],
                shuffles: 3),
        // A pale LCD with a deep accent (Pocket's light layer), then Shuffles that move
        // the pale swatches onto and off the glass.
        Palette(slug: "pale-glass", colors: ["#C9C6BE", "#E4E1DA", "#1B1B22", "#A12A5E", "#B7BBB0", "#1F2326"],
                assignment: [.frame: 0, .panels: 1, .text: 2, .accent: 3, .glass: 4, .screenText: 5],
                shuffles: 3),
    ]

    func testWriteSimpleContactSheets() throws {
        let setting = ProcessInfo.processInfo.environment["CRATEDIGGER_SIMPLE_SHEETS"]
        try XCTSkipUnless(setting?.isEmpty == false, "set CRATEDIGGER_SIMPLE_SHEETS to an output folder")
        let out = URL(fileURLWithPath: try XCTUnwrap(setting), isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        // Read-only: nothing here applies a theme, so the source folder is safe to load from.
        let themesDirectory = BusySignalSnapshotTests.repoRoot
            .appendingPathComponent("Sources/CrateDiggerApp/Resources/Themes", isDirectory: true)
        let registry = ThemeRegistry(loader: ThemeLoaderService(bundles: [], userThemesDirectoryOverride: themesDirectory))
        let carbon = try XCTUnwrap(registry.manifest(for: "carbon"), "carbon did not load")
        let seed = registry.newSimpleSeed(from: carbon)
        XCTAssertNil(seed.inherits)

        let fonts = ["display": try XCTUnwrap(SimpleFontPresets.screenTitles.first).font,
                     "mono": try XCTUnwrap(SimpleFontPresets.labels.first).font,
                     "sans": try XCTUnwrap(SimpleFontPresets.interface.first).font]
        func choices(_ mode: SimpleAppearanceMode) -> SimpleThemeChoices {
            SimpleThemeChoices(appearance: mode, material: .plastic, coverLook: .pixel, fonts: fonts)
        }

        for (offset, entry) in Self.palettes.enumerated() {
            let number = offset + 1
            // An empty assignment is incomplete, so the state starts from `SimplePaletteAssigner.initial`.
            var state = SimpleThemeState(recipe: SimpleThemeRecipe(palette: entry.colors, assignment: entry.assignment))
            var pictures: [CGImage] = []
            func write(_ mode: SimpleAppearanceMode, on screen: ThemeDefinition.BaseAppearance,
                       suffix: String = "") throws {
                let built = SimpleThemeBuilder.build(state: state, choices: choices(mode), onto: seed)
                XCTAssertNil(built.inherits)
                let picture = try image(for: built, on: screen, registry: registry)
                let name = "\(number)-\(entry.slug)-\(mode.rawValue)-on-\(screen == .dark ? "dark" : "light")\(suffix).png"
                try BusySignalSnapshotTests.writePNG(picture, to: out.appendingPathComponent(name))
                pictures.append(picture)
            }
            try write(.both, on: .dark)
            try write(.both, on: .light)
            try write(.light, on: .dark)
            try write(.dark, on: .light)
            for k in stride(from: 1, through: entry.shuffles, by: 1) {
                state.shuffle()
                try write(.both, on: .dark, suffix: "-shuffle\(k)")
                try write(.both, on: .light, suffix: "-shuffle\(k)")
            }
            try BusySignalSnapshotTests.writePNG(try Self.combined(pictures),
                                                 to: out.appendingPathComponent("\(number)-\(entry.slug)-sheet.png"))
        }
        print("Simple theme contact sheets: \(out.path)")
    }

    // MARK: - Helpers

    private func image(for definition: ThemeDefinition, on screen: ThemeDefinition.BaseAppearance,
                       registry: ThemeRegistry) throws -> CGImage {
        let theme = registry.previewTheme(for: definition, appearance: screen).theme
        ThemePreviewIllustration.prepareCovers(for: theme, scale: 1)
        let view = ThemePreviewIllustration(theme: theme, fonts: definition.fonts ?? [:], highlighted: [])
            .padding(16)
            .background(Color(white: 0.5))
            .environment(\.displayScale, 1)
        return try BusySignalSnapshotTests.image(view, scale: 1)
    }

    /// The pictures in a grid of two columns, in order.
    private static func combined(_ pictures: [CGImage]) throws -> CGImage {
        let columns = 2
        let cellW = pictures.map(\.width).max() ?? 1
        let cellH = pictures.map(\.height).max() ?? 1
        let rows = (pictures.count + columns - 1) / columns
        let context = try XCTUnwrap(CGContext(
            data: nil, width: cellW * columns, height: cellH * rows, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: cellW * columns, height: cellH * rows))
        for (i, picture) in pictures.enumerated() {
            let x = (i % columns) * cellW
            let y = (rows - 1 - i / columns) * cellH
            context.draw(picture, in: CGRect(x: x, y: y, width: picture.width, height: picture.height))
        }
        return try XCTUnwrap(context.makeImage())
    }
}
#endif
