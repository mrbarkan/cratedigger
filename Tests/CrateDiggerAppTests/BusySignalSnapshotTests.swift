#if canImport(XCTest)
import AppKit
import CoreText
import CrateDiggerCore
import SwiftUI
import XCTest
@testable import CrateDiggerApp

/// Renders every Busy Signals picture and mini through the real renderer
/// (`BusyCanvas` in an `ImageRenderer`), so the port can be compared with the
/// approved sketch (`CrateDigger_DESIGN/busy-signals/busy-signals.html`)
/// without launching the app.
///
/// - Always on: `testEveryPictureAndMiniRendersInk` (each kind draws
///   something) and `testMonochromeLlamaGlassDrawsNoRed` (the R1 regression,
///   checked on pixels rather than on palette values).
/// - Gated: `testWriteContactSheets` writes `.build/busy-signals/` and is
///   skipped unless `CRATEDIGGER_BUSY_SNAPSHOTS` is set (spec §11.3):
///
///   ```
///   CRATEDIGGER_BUSY_SNAPSHOTS=1 scripts/test.sh --filter BusySignalSnapshotTests/testWriteContactSheets
///   open .build/busy-signals/index.html
///   ```
@MainActor
final class BusySignalSnapshotTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FontRegistrar.registerBundledFonts()
        Self.registerSourceFonts()
    }

    /// The test bundle does not always find the app's resource bundle, and
    /// without it the scenes' `CarbonFont.mono(…, .semibold)` text falls back
    /// to the system font, which is not what ships. Register the faces from
    /// the source tree directly (synchronously; "already registered" is fine).
    static func registerSourceFonts() {
        let fonts = repoRoot.appendingPathComponent("Sources/CrateDiggerApp/Resources/Fonts", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: fonts, includingPropertiesForKeys: nil)) ?? []
        for url in files where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    // MARK: - Always on

    /// Each picture and each mini, on Carbon, leaves at least 1 % of its
    /// pixels more than 10/255 away from the glass.
    func testEveryPictureAndMiniRendersInk() throws {
        let theme = CarbonTheme.carbon
        for kind in BusyJobKind.allCases {
            let input = Fixture.running(kind, p: 0.5)
            let picture = try Self.image(Self.cell(BusyScenes.picture(kind, input), lineWidth: Self.pictureLine,
                                                   size: Self.pictureSize, theme: theme, glass: .flat))
            XCTAssertGreaterThanOrEqual(Self.inkCoverage(picture, over: theme.oledSurface), 0.01, "\(kind) picture")

            let mini = try Self.image(Self.cell(BusyScenes.mini(kind, input), lineWidth: Self.miniLine,
                                                size: BusyDrawing.miniSize, theme: theme, glass: .flat))
            XCTAssertGreaterThanOrEqual(Self.inkCoverage(mini, over: theme.oledSurface), 0.01, "\(kind) mini")
        }
    }

    /// Llama '97 pins Meter High to #FF0000 and turns monochrome on. Through
    /// its glass theme no picture or mini may put a red pixel on the screen,
    /// running or finished with the hot mark lit. The same frames on the
    /// un-glassed theme *do* draw red, which proves the probe can see it.
    func testMonochromeLlamaGlassDrawsNoRed() throws {
        let llama = try Self.llamaTheme()
        let glass = llama.monochromeGlass
        var redOffGlass = 0
        for kind in BusyJobKind.allCases {
            for input in [Fixture.running(kind, p: 0.5), Fixture.finished(kind, lit: true)] {
                for (drawing, line, size) in [
                    (BusyScenes.picture(kind, input), Self.pictureLine, Self.pictureSize),
                    (BusyScenes.mini(kind, input), Self.miniLine, BusyDrawing.miniSize),
                ] {
                    let onGlass = try Self.image(Self.cell(drawing, lineWidth: line, size: size, theme: glass, glass: .flat))
                    XCTAssertEqual(Self.redPixels(onGlass), 0, "\(kind) draws red on Llama's monochrome glass")
                    let offGlass = try Self.image(Self.cell(drawing, lineWidth: line, size: size, theme: llama, glass: .flat))
                    redOffGlass += Self.redPixels(offGlass)
                }
            }
        }
        XCTAssertGreaterThan(redOffGlass, 0, "the probe never saw the pinned red; the check above proves nothing")
    }

    // MARK: - Contact sheets (gated)

    func testWriteContactSheets() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CRATEDIGGER_BUSY_SNAPSHOTS"] != nil,
                          "set CRATEDIGGER_BUSY_SNAPSHOTS=1 to write .build/busy-signals/")
        XCTAssertNotNil(NSFont(name: CarbonFont.monoSemibold, size: 6),
                        "the scenes' text face is not registered; the sheets would show a fallback font")
        let out = Self.repoRoot.appendingPathComponent(".build/busy-signals", isDirectory: true)
        let cells = out.appendingPathComponent("cells", isDirectory: true)
        try FileManager.default.createDirectory(at: cells, withIntermediateDirectories: true)

        let rows = try Self.rows()
        for kind in BusyJobKind.allCases {
            let columns = Fixture.columns(kind)
            var sheetRows: [SheetRow] = []
            for row in rows {
                var sheetCells: [SheetCell] = []
                for column in columns {
                    let input = row.still ? Fixture.still(kind, column.input) : column.input
                    let drawing = BusyScenes.picture(kind, input)
                    let view = Self.cell(drawing, lineWidth: Self.pictureLine, size: Self.pictureSize,
                                         theme: row.theme, glass: .real)
                    sheetCells.append(SheetCell(caption: column.caption, view: AnyView(view)))
                    try Self.writePNG(Self.image(view),
                                      to: cells.appendingPathComponent("\(kind.rawValue)-\(row.id)-\(column.id).png"))
                }
                sheetRows.append(SheetRow(label: row.label, cells: sheetCells))
            }
            let sheet = Sheet(title: "\(kind.label) · \(Fixture.sketchSection(kind))", rows: sheetRows)
            try Self.writePNG(Self.image(sheet), to: out.appendingPathComponent("\(kind.rawValue).png"))
        }

        // Minis: every kind, 1× and 4×, running at 0.5, finished lit and unlit.
        var miniRows: [SheetRow] = []
        let states: [(id: String, caption: String, input: (BusyJobKind) -> BusySceneInput)] = [
            ("p50", "p 0.5", { Fixture.running($0, p: 0.5) }),
            ("lit", "done lit", { Fixture.finished($0, lit: true) }),
            ("unlit", "done unlit", { Fixture.finished($0, lit: false) }),
        ]
        for row in rows where !row.still {
            for kind in BusyJobKind.allCases {
                var sheetCells: [SheetCell] = []
                for zoom in [1, 4] as [CGFloat] {
                    for state in states {
                        let drawing = BusyScenes.mini(kind, state.input(kind))
                        let size = CGSize(width: BusyDrawing.miniSize.width * zoom, height: BusyDrawing.miniSize.height * zoom)
                        // The sketch strokes a mini 0.95 *mini units* wide,
                        // so its enlarged gallery copy scales the line too.
                        let view = Self.cell(drawing, lineWidth: Self.miniLine * zoom, size: size,
                                             theme: row.theme, glass: .real)
                        sheetCells.append(SheetCell(caption: "\(Int(zoom))× \(state.caption)", view: AnyView(view)))
                        try Self.writePNG(Self.image(view),
                                          to: cells.appendingPathComponent("mini-\(kind.rawValue)-\(row.id)-\(state.id)-\(Int(zoom))x.png"))
                    }
                }
                miniRows.append(SheetRow(label: "\(row.label)\n\(kind.label)", cells: sheetCells))
            }
        }
        try Self.writePNG(Self.image(Sheet(title: "MINIS · busy-signals.html § top line", rows: miniRows)),
                          to: out.appendingPathComponent("minis.png"))

        try Self.indexHTML.write(to: out.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    }

    // MARK: - Fixtures

    /// Inputs built the way the sketch builds its state (html:229-233 and
    /// each scene's `state(t)`), so a cell at p matches the sketch's frame at
    /// `local = p × run`. Times go through the 8 fps grid like the ledger's.
    enum Fixture {
        /// The sketch's run lengths (html:337, :393, :451, :530, :659, :729).
        static func run(_ kind: BusyJobKind) -> TimeInterval {
            switch kind {
            case .rip: return 18
            case .secureRead: return 20
            case .convert: return 22
            case .scan: return 20
            case .download: return 16
            case .transfer: return 18
            }
        }

        static func sketchSection(_ kind: BusyJobKind) -> String {
            switch kind {
            case .rip: return "busy-signals.html § cd-rip"
            case .secureRead: return "busy-signals.html § secure read"
            case .convert: return "busy-signals.html § convert"
            case .scan: return "busy-signals.html § scan"
            case .download: return "busy-signals.html § download"
            case .transfer: return "busy-signals.html § transfer"
            }
        }

        struct Column {
            var id: String
            var caption: String
            var input: BusySceneInput
        }

        /// p 0.1 / 0.5 / 0.9, finished lit and unlit, the still key frame,
        /// then any per-scene extra that a sketch-equivalent p never lands on.
        static func columns(_ kind: BusyJobKind) -> [Column] {
            var columns = [
                Column(id: "p10", caption: "p 0.1", input: running(kind, p: 0.1)),
                Column(id: "p50", caption: "p 0.5", input: running(kind, p: 0.5)),
                Column(id: "p90", caption: "p 0.9", input: running(kind, p: 0.9)),
                Column(id: "lit", caption: "done · lit", input: finished(kind, lit: true)),
                Column(id: "unlit", caption: "done · unlit", input: finished(kind, lit: false)),
                Column(id: "still", caption: "still (key \(BusyScenes.keyTime(kind)) s)", input: still(kind, running(kind, p: 0.5))),
            ]
            switch kind {
            case .rip:
                // local 7.45: track 3 has just started, so track 2's slab is falling.
                columns.append(Column(id: "falling", caption: "slab falling", input: rip(local: 7.45)))
            case .secureRead:
                columns.append(Column(id: "retry", caption: "retry · 2 re-reads",
                                      input: secure(track: 3, of: 8, phase: .retry, fraction: 0.5, rereads: 2, time: 9)))
            case .convert:
                columns.append(Column(id: "lossless", caption: "lossless · key",
                                      input: convert(time: BusyScenes.keyTime(.convert), lossless: true)))
            case .scan:
                // local 4.75: halfway through the first crate swap.
                columns.append(Column(id: "swap", caption: "crate swap", input: scan(time: 4.75, p: 0.24)))
            case .download, .transfer:
                break
            }
            return columns
        }

        static func running(_ kind: BusyJobKind, p: Double) -> BusySceneInput {
            let local = p * run(kind)
            switch kind {
            case .rip:
                return rip(local: local)
            case .secureRead:
                // html:399-402: eight tracks, each half pass 1, half pass 2.
                let f = min(p * 8, 8 - 1e-6)
                let k = Int(f.rounded(.down))
                let tp = f - Double(k)
                let phase: SecureRipEngine.Phase = tp < 0.5 ? .pass1 : .pass2
                let pp = tp.truncatingRemainder(dividingBy: 0.5) / 0.5
                return secure(track: k + 1, of: 8, phase: phase, fraction: pp, rereads: 0, time: local)
            case .convert:
                var input = convert(time: local, lossless: false)
                input.progress = input.progress.with(completed: Int(p * 24), total: 24)
                return input
            case .scan:
                return scan(time: local, p: p)
            case .download:
                return BusySceneInput(progress: .init(completed: Int(p * 100), total: 100),
                                      labels: .init(source: "KEXP"), time: q(local))
            case .transfer:
                return BusySceneInput(progress: .init(completed: Int(p * 380), total: 380), time: q(local))
            }
        }

        /// Finished a beat ago: at 1/8 s the 2 Hz blink is lit, at 5/8 s off.
        /// The scan finishes at 19 s, inside its fourth crate (T–Z), which is
        /// the crate the sketch's finished frame holds.
        static func finished(_ kind: BusyJobKind, lit: Bool) -> BusySceneInput {
            var input = running(kind, p: 1)
            input.time = kind == .scan ? 19 : run(kind)
            input.unitTime = 0
            input.unitFraction = 1
            input.finished = lit ? 0.125 : 0.625
            input.markLit = lit
            switch kind {
            case .rip: input.progress = .init(completed: 5, total: 5)
            case .secureRead:
                input = secure(track: 8, of: 8, phase: .pass2, fraction: 1, rereads: 0, time: run(kind))
                input.unitFraction = 1
                input.finished = lit ? 0.125 : 0.625
                input.markLit = lit
            default: break
            }
            return input
        }

        /// What the ledger hands a Reduce Motion view (BusyLedger.sceneInput):
        /// half a unit and a steady mark; the scene's key time while running,
        /// the time frozen at the finish once finished.
        static func still(_ kind: BusyJobKind, _ input: BusySceneInput) -> BusySceneInput {
            var input = input
            input.still = true
            input.markLit = true
            input.unitTime = 0.5
            if input.finished == nil {
                input.time = BusyScenes.keyTime(kind)
                input.unitFraction = 0.5
            }
            return input
        }

        // MARK: Per-scene builders

        private static func q(_ t: TimeInterval) -> TimeInterval { BusySignalTiming.quantized(t) }

        /// html:343-346: five tracks over the run, `k` done, `tp` into the next.
        static func rip(local: TimeInterval) -> BusySceneInput {
            let f = local / run(.rip) * 5
            let k = min(Int(f.rounded(.down)), 5)
            let tp = f - f.rounded(.down)
            let since = local - run(.rip) * Double(k) / 5
            return BusySceneInput(progress: .init(completed: k, total: 5), time: q(local),
                                  unitTime: q(since), unitFraction: min(tp, 0.95))
        }

        static func secure(track: Int, of count: Int, phase: SecureRipEngine.Phase, fraction: Double,
                           rereads: Int, time: TimeInterval) -> BusySceneInput {
            let engine = SecureRipEngine.Progress(trackNumber: track, phase: phase, fraction: fraction, rereads: rereads)
            let disc = SecureDiscRip.Progress(trackOrdinal: track, trackCount: count, track: engine, discRereads: rereads)
            return BusySceneInput(progress: .init(completed: track - 1, total: count, secure: BusySecureRead(disc)),
                                  time: q(time))
        }

        static func convert(time: TimeInterval, lossless: Bool) -> BusySceneInput {
            BusySceneInput(progress: .init(completed: 0, total: 24, lossless: lossless),
                           labels: .init(source: "FLAC", target: lossless ? "ALAC" : "MP3"),
                           time: q(time))
        }

        static func scan(time: TimeInterval, p: Double) -> BusySceneInput {
            BusySceneInput(progress: .init(completed: Int(p * 14820), total: 14820), time: q(time))
        }
    }

    // MARK: - Themes

    struct ThemeRow {
        var id: String
        var label: String
        /// Already the glass theme: `monochromeGlass` applied when the theme
        /// asks for it, as `OLEDDisplay` does and nothing else would here.
        var theme: CarbonTheme
        var still = false
    }

    static func rows() throws -> [ThemeRow] {
        let llama = try llamaTheme()
        return [
            ThemeRow(id: "carbon", label: "CARBON", theme: glass(.carbon)),
            ThemeRow(id: "llama", label: "LLAMA '97\nmono glass", theme: glass(llama)),
            ThemeRow(id: "backlit", label: "BACKLIT\npale LCD", theme: glass(try backlitTheme())),
            ThemeRow(id: "reduce", label: "CARBON\nreduce motion", theme: glass(.carbon), still: true),
        ]
    }

    static func glass(_ theme: CarbonTheme) -> CarbonTheme {
        theme.oledMonochrome ? theme.monochromeGlass : theme
    }

    /// The bundled Llama '97, flattened for Dark the way `BundledThemeTests`
    /// renders it: its Meter High pin and monochrome switch live only inside
    /// the appearance layers, so the unflattened definition would test
    /// nothing.
    static func llamaTheme() throws -> CarbonTheme {
        let directory = repoRoot.appendingPathComponent("Sources/CrateDiggerApp/Resources/Themes", isDirectory: true)
        let themes = ThemeLoaderService(bundles: [], userThemesDirectoryOverride: directory).discoverThemes().themes
        let definition = try XCTUnwrap(themes.first { $0.id == "llama-97" }?.definition, "Llama 97.cdtheme did not load")
        let theme = CarbonTheme(definition: definition.resolved(for: .dark), resolvedBase: .carbon)
        XCTAssertNotNil(theme.meterHotOverride, "precondition: Llama '97 pins Meter High")
        XCTAssertTrue(theme.oledMonochrome, "precondition: Llama '97 is monochrome")
        return theme
    }

    /// No bundled theme has a pale glass, so the pale row is the theme
    /// editor's BACKLIT screen preset (a lit blue-green LCD with dark type)
    /// on Carbon, applied the way the preset writes it.
    static func backlitTheme() throws -> CarbonTheme {
        let preset = try XCTUnwrap(ThemeTokenCatalog.screenPresets.first { $0.name == "BACKLIT" })
        let definition = ThemeDefinition(
            id: "snapshot-backlit", name: "Backlit", baseAppearance: .dark,
            colors: preset.colors,
            effects: ["oledMonochrome": preset.monochrome ? 1 : 0]
        )
        return CarbonTheme(definition: definition, resolvedBase: .carbon)
    }

    // MARK: - Views

    static let pictureSize = CGSize(width: 220, height: 84)
    static let pictureLine: CGFloat = 1.15
    static let miniLine: CGFloat = 0.95

    enum GlassKind { case flat, real }

    /// One drawing on the glass. `.real` is the OLED's own background
    /// (OLEDDisplay.swift `background`): `oledSurface` with the diagonal
    /// white → clear → `oledSurfaceShade` rake, laid over a 720 × 150 glass
    /// (the sketch's strip) of which the cell is the centre window, roughly
    /// where a pane hosts its picture. `.flat` is the bare surface, for the
    /// pixel probes.
    static func cell(_ drawing: BusyDrawing, lineWidth: CGFloat, size: CGSize,
                     theme: CarbonTheme, glass: GlassKind) -> some View {
        // The glass is a background, so its 720 × 150 frame never sizes the
        // cell: only the canvas's frame does.
        BusyCanvas(drawing: drawing, lineWidth: lineWidth)
            .frame(width: size.width, height: size.height)
            .background {
                switch glass {
                case .flat: theme.oledSurface
                case .real: GlassWell(theme: theme)
                }
            }
            .clipped()
            .environment(\.carbon, theme)
    }

    struct GlassWell: View {
        let theme: CarbonTheme
        var body: some View {
            ZStack {
                theme.oledSurface
                LinearGradient(colors: [Color.white.opacity(theme.isDark ? 0.04 : 0.08), .clear, theme.oledSurfaceShade],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .frame(width: 720, height: 150)
        }
    }

    struct SheetCell {
        var caption: String
        var view: AnyView
    }

    struct SheetRow {
        var label: String
        var cells: [SheetCell]
    }

    struct Sheet: View {
        var title: String
        var rows: [SheetRow]
        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(CarbonFont.mono(11, weight: .semibold)).foregroundColor(Color(white: 0.85))
                ForEach(rows.indices, id: \.self) { r in
                    HStack(alignment: .top, spacing: 10) {
                        Text(rows[r].label)
                            .font(CarbonFont.mono(9))
                            .foregroundColor(Color(white: 0.6))
                            .frame(width: 96, alignment: .leading)
                        ForEach(rows[r].cells.indices, id: \.self) { c in
                            VStack(alignment: .leading, spacing: 4) {
                                rows[r].cells[c].view
                                    .overlay(Rectangle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                                Text(rows[r].cells[c].caption)
                                    .font(CarbonFont.mono(9))
                                    .foregroundColor(Color(white: 0.6))
                            }
                        }
                    }
                }
            }
            .padding(16)
            .background(Color(red: 0x15 / 255, green: 0x18 / 255, blue: 0x1A / 255))
        }
    }

    // MARK: - Pixels and files

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CrateDiggerAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    static func image<V: View>(_ view: V, scale: CGFloat = 3) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return try XCTUnwrap(renderer.cgImage, "ImageRenderer produced no image")
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    /// The image as sRGB RGBA8, row-major.
    static func pixels(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                    bytesPerRow: w * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return bytes
    }

    /// The share of pixels more than 10/255 from `surface` in any channel.
    static func inkCoverage(_ image: CGImage, over surface: Color) -> Double {
        let s = rgba(surface)
        let ref = [s.r, s.g, s.b].map { $0 * 255 }
        let bytes = pixels(image)
        var inked = 0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            if (0..<3).contains(where: { abs(Double(bytes[i + $0]) - ref[$0]) > 10 }) { inked += 1 }
        }
        return Double(inked) / Double(max(1, bytes.count / 4))
    }

    /// Pixels that read as red: a strong red channel over weak green and blue.
    static func redPixels(_ image: CGImage) -> Int {
        let bytes = pixels(image)
        var red = 0
        for i in stride(from: 0, to: bytes.count, by: 4) where bytes[i] > 120 && bytes[i + 1] < 60 && bytes[i + 2] < 60 {
            red += 1
        }
        return red
    }

    static let indexHTML = """
    <!doctype html>
    <meta charset="utf-8">
    <title>Busy Signals contact sheets</title>
    <style>
    body { background: #15181A; color: #E9E6DF; font: 13px/1.5 -apple-system, sans-serif; margin: 24px; }
    h2 { font: 600 14px ui-monospace, monospace; margin: 28px 0 4px; }
    p { color: #8E989D; margin: 0 0 8px; }
    img { max-width: 100%; border: 1px solid #2C3337; }
    </style>
    <h1>Busy Signals</h1>
    <p>Rendered by BusySignalSnapshotTests through BusyCanvas. Open CrateDigger_DESIGN/busy-signals/busy-signals.html alongside.</p>
    <h2>rip.png</h2><p>compare with CrateDigger_DESIGN/busy-signals/busy-signals.html § cd-rip</p><img src="rip.png">
    <h2>secureRead.png</h2><p>compare with CrateDigger_DESIGN/busy-signals/busy-signals.html § secure read</p><img src="secureRead.png">
    <h2>convert.png</h2><p>compare with CrateDigger_DESIGN/busy-signals/busy-signals.html § convert</p><img src="convert.png">
    <h2>scan.png</h2><p>compare with CrateDigger_DESIGN/busy-signals/busy-signals.html § scan</p><img src="scan.png">
    <h2>download.png</h2><p>compare with CrateDigger_DESIGN/busy-signals/busy-signals.html § download</p><img src="download.png">
    <h2>transfer.png</h2><p>compare with CrateDigger_DESIGN/busy-signals/busy-signals.html § transfer</p><img src="transfer.png">
    <h2>minis.png</h2><p>compare with CrateDigger_DESIGN/busy-signals/busy-signals.html § top line (the mini gallery)</p><img src="minis.png">
    """
}
#endif
