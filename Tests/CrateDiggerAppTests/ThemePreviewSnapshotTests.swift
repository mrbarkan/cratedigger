#if canImport(XCTest)
import AppKit
import CoreText
import CrateDiggerCore
import SwiftUI
import XCTest
@testable import CrateDiggerApp

/// Renders the theme editor's illustrated preview (`ThemePreviewIllustration`)
/// for the built-in themes, so the drawing can be judged by eye without
/// launching the app.
///
/// - Always on: `testPreviewDrawsEveryScreen` (each theme renders something,
///   the sample cover is found, and highlighting a job changes the picture).
/// - Gated: `testWritePreviewSnapshots` writes PNGs, one plain and one per
///   highlighted job for each theme, and is skipped unless
///   `CRATEDIGGER_THEME_PREVIEW_SNAPSHOTS` is set; its value, when a path, is
///   the output folder (default `.build/theme-preview`):
///
///   ```
///   CRATEDIGGER_THEME_PREVIEW_SNAPSHOTS=1 scripts/test.sh --filter ThemePreviewSnapshotTests
///   ```
///
/// `ImageRenderer` flattens blend modes and runs no tasks, so the covers are
/// prepared first and the shell material is the preview's flat tint anyway.
@MainActor
final class ThemePreviewSnapshotTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FontRegistrar.registerBundledFonts()
        BusySignalSnapshotTests.registerSourceFonts()
        Self.registerThemeFonts()
        ThemePreviewCoverStore.sampleCoverOverride = BusySignalSnapshotTests.repoRoot
            .appendingPathComponent("Sources/CrateDiggerApp/Resources/StarterCrate/cover.png")
    }

    func testPreviewDrawsEveryScreen() throws {
        XCTAssertNotNil(ThemePreviewCoverStore.source(), "StarterCrate/cover.png was not found")
        for sample in try Self.samples() {
            let plain = try image(for: sample, highlighted: [])
            let lit = try image(for: sample, highlighted: [.accent])
            XCTAssertGreaterThan(plain.width, 800, sample.name)
            XCTAssertNotEqual(Self.checksum(plain), Self.checksum(lit),
                              "\(sample.name): highlighting the accent changed nothing")
        }
    }

    func testWritePreviewSnapshots() throws {
        let setting = ProcessInfo.processInfo.environment["CRATEDIGGER_THEME_PREVIEW_SNAPSHOTS"]
        try XCTSkipUnless(setting != nil, "set CRATEDIGGER_THEME_PREVIEW_SNAPSHOTS to write the snapshots")
        let out = setting.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
            ?? BusySignalSnapshotTests.repoRoot.appendingPathComponent(".build/theme-preview", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for sample in try Self.samples() {
            let slug = sample.name.lowercased().replacingOccurrences(of: " ", with: "-")
            try BusySignalSnapshotTests.writePNG(try image(for: sample, highlighted: []),
                                                 to: out.appendingPathComponent("\(slug).png"))
            for job in ThemeJob.allCases {
                try BusySignalSnapshotTests.writePNG(try image(for: sample, highlighted: [job]),
                                                     to: out.appendingPathComponent("\(slug)-\(job.rawValue).png"))
            }
        }
        print("Theme preview snapshots: \(out.path)")
    }

    // MARK: - Helpers

    struct Sample {
        let name: String
        let theme: CarbonTheme
        let fonts: [String: ThemeFont]
    }

    private static let scale: CGFloat = 2

    private func image(for sample: Sample, highlighted: Set<ThemeJob>) throws -> CGImage {
        ThemePreviewIllustration.prepareCovers(for: sample.theme, scale: Self.scale)
        let view = ThemePreviewIllustration(theme: sample.theme, fonts: sample.fonts, highlighted: highlighted)
            .padding(16)
            .background(Color(white: 0.5))
            .environment(\.displayScale, Self.scale)
        // Each view tags its opacity with an animation; none runs in a one-shot render.
        return try BusySignalSnapshotTests.image(view, scale: Self.scale)
    }

    static func samples() throws -> [Sample] {
        let directory = BusySignalSnapshotTests.repoRoot
            .appendingPathComponent("Sources/CrateDiggerApp/Resources/Themes", isDirectory: true)
        let themes = ThemeLoaderService(bundles: [], userThemesDirectoryOverride: directory).discoverThemes().themes
        func sample(_ name: String, id: String, appearance: ThemeDefinition.BaseAppearance) throws -> Sample {
            let manifest = try XCTUnwrap(themes.first { $0.id == id }, "\(id) did not load")
            let target = manifest.definition.isAdaptive ? appearance : manifest.definition.baseAppearance
            let definition = manifest.definition.resolved(for: target)
            var theme = CarbonTheme(definition: definition,
                                    resolvedBase: definition.baseAppearance == .dark ? .carbon : .linen)
            theme.name = definition.name
            theme.id = definition.id
            return Sample(name: name, theme: theme, fonts: definition.fonts ?? [:])
        }
        return [
            try sample("Carbon", id: "carbon", appearance: .dark),
            try sample("Carbon Light", id: "carbon", appearance: .light),
            try sample("Llama 97", id: "llama-97", appearance: .dark),
            try sample("Pocket", id: "pocket", appearance: .dark),
        ]
    }

    /// Theme bundles carry their own faces (Llama '97's pixel fonts); the
    /// registry registers them in the app, the test does it here.
    static func registerThemeFonts() {
        let themes = BusySignalSnapshotTests.repoRoot
            .appendingPathComponent("Sources/CrateDiggerApp/Resources/Themes", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: themes, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in enumerator where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    private static func checksum(_ image: CGImage) -> Int {
        guard let data = image.dataProvider?.data as Data? else { return 0 }
        var hasher = Hasher()
        hasher.combine(data)
        return hasher.finalize()
    }
}
#endif
