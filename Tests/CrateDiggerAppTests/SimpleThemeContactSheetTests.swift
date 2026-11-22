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
/// Files are `<n>-<palette>-<dark|light>[-shuffle<k>].png` at 1x, plus one
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

    private static let palettes: [(slug: String, colors: [String])] = [
        ("nord", ["#2E3440", "#3B4252", "#ECEFF4", "#88C0D0", "#BF616A"]),
        ("two-colours", ["#1B1D22", "#FF6A13"]),
        ("pastel-light", ["#FBF7F0", "#E8D8C4", "#6B5B4E", "#F2A7A0"]),
        ("neon", ["#0A0A12", "#FF00AA", "#00FFD1", "#FAFF00"]),
        ("mono-greys", ["#222222", "#2A2A2A", "#DDDDDD"]),
        ("forest", ["#1F2D24", "#3E5641", "#A3B18A", "#DAD7CD", "#E9C46A", "#BC4749"]),
    ]

    func testWriteSimpleContactSheets() throws {
        let setting = ProcessInfo.processInfo.environment["CRATEDIGGER_SIMPLE_SHEETS"]
        try XCTSkipUnless(setting?.isEmpty == false, "set CRATEDIGGER_SIMPLE_SHEETS to an output folder")
        let out = URL(fileURLWithPath: try XCTUnwrap(setting), isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let themesDirectory = BusySignalSnapshotTests.repoRoot
            .appendingPathComponent("Sources/CrateDiggerApp/Resources/Themes", isDirectory: true)
        let themes = ThemeLoaderService(bundles: [], userThemesDirectoryOverride: themesDirectory).discoverThemes().themes
        let carbon = try XCTUnwrap(themes.first { $0.id == "carbon" }, "carbon did not load").definition

        let choices = SimpleThemeChoices(
            appearance: .both, material: .plastic, coverLook: .pixel,
            fonts: ["display": try XCTUnwrap(SimpleFontPresets.screenTitles.first).font,
                    "mono": try XCTUnwrap(SimpleFontPresets.labels.first).font,
                    "sans": try XCTUnwrap(SimpleFontPresets.interface.first).font])

        for (offset, entry) in Self.palettes.enumerated() {
            let number = offset + 1
            // An empty assignment is incomplete, so the state starts from `SimplePaletteAssigner.initial`.
            var state = SimpleThemeState(recipe: SimpleThemeRecipe(palette: entry.colors))
            var pictures: [CGImage] = []
            func write(_ appearance: ThemeDefinition.BaseAppearance, suffix: String) throws {
                let built = SimpleThemeBuilder.build(state: state, choices: choices, onto: carbon)
                let picture = try image(for: built, appearance: appearance)
                let name = "\(number)-\(entry.slug)-\(appearance == .dark ? "dark" : "light")\(suffix).png"
                try BusySignalSnapshotTests.writePNG(picture, to: out.appendingPathComponent(name))
                pictures.append(picture)
            }
            try write(.dark, suffix: "")
            try write(.light, suffix: "")
            if number == 1 || number == 6 {
                for k in 1...3 {
                    state.shuffle()
                    try write(.dark, suffix: "-shuffle\(k)")
                }
            }
            try BusySignalSnapshotTests.writePNG(try Self.combined(pictures),
                                                 to: out.appendingPathComponent("\(number)-\(entry.slug)-sheet.png"))
        }
        print("Simple theme contact sheets: \(out.path)")
    }

    // MARK: - Helpers

    private func image(for definition: ThemeDefinition, appearance: ThemeDefinition.BaseAppearance) throws -> CGImage {
        let flat = definition.resolved(for: definition.isAdaptive ? appearance : definition.baseAppearance)
        var theme = CarbonTheme(definition: flat, resolvedBase: flat.baseAppearance == .dark ? .carbon : .linen)
        theme.name = flat.name
        theme.id = flat.id
        ThemePreviewIllustration.prepareCovers(for: theme, scale: 1)
        let view = ThemePreviewIllustration(theme: theme, fonts: flat.fonts ?? [:], highlighted: [])
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
