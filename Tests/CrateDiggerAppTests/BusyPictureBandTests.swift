#if canImport(XCTest)
import AppKit
import CrateDiggerCore
import SwiftUI
import XCTest
@testable import CrateDiggerApp

/// How a job pane makes room for its Busy Signals picture (spec §5), rendered
/// offscreen with `ImageRenderer` so the layout is checked without a view
/// model or a running app.
///
/// The fixture paints each slot a solid colour, so a pixel scan shows exactly
/// where each slot stopped: headline blue, readout green, ticker yellow,
/// picture red, cell rail cyan, a ticker's meta magenta.
@MainActor
final class BusyPictureBandTests: XCTestCase {
    typealias Band = BusyPictureBand<EmptyView, EmptyView, EmptyView, EmptyView, EmptyView>

    /// The band at the default 170 pt header: the glass minus its rail, the
    /// pane's top inset and the 48 pt cell rail (spec §5, "≈ 85 pt").
    static let defaultBand = CGSize(width: 838, height: 85)
    /// A 120 pt header leaves about 35 pt: too short for a picture.
    static let shortBand = CGSize(width: 838, height: 35)
    /// Room enough for a picture, not for the default text stack (40 + 8 + 14).
    static let tightBand = CGSize(width: 838, height: 60)
    /// The narrow end: a window dragged below its 1200 pt minimum, where the
    /// picture is still kept but the text column is only ≈ 270 pt.
    static let narrowBand = CGSize(width: 700, height: 85)

    /// The pane that leaves `band` above its cell rail.
    static func pane(_ band: CGSize) -> CGSize {
        CGSize(width: band.width, height: band.height + 6 + 48)
    }

    override func setUp() {
        super.setUp()
        FontRegistrar.registerBundledFonts()
    }

    func testThePaneMeasuresItsBandAboveTheTopInsetAndTheCellRail() {
        XCTAssertEqual(Band.bandSize(inPane: Self.pane(Self.defaultBand)), Self.defaultBand)
        XCTAssertEqual(Band.bandSize(inPane: CGSize(width: 838, height: 30)).height, 0)
    }

    func testDefaultBandPlacesThePictureOnTheThirdCellsTextEdge() throws {
        let frame = try XCTUnwrap(Band.pictureFrame(in: Self.defaultBand))
        // 838 pt over five cells and four 1 pt dividers: 166.8 pt a cell, so
        // the third cell's text starts at 2 × 167.8 + 10.
        XCTAssertEqual(frame.minX, 345.6, accuracy: 0.01)
        XCTAssertEqual(frame.width, 220)
        XCTAssertGreaterThanOrEqual(frame.height, 40)
        XCTAssertEqual(frame.maxY, Self.defaultBand.height, accuracy: 0.01,
                       "it stands down to the cell rail and no further")
    }

    func testAShortHeaderDropsThePicture() {
        XCTAssertNil(Band.pictureFrame(in: Self.shortBand))
    }

    func testTextStopsAtTheGutterBeforeThePictureAndTheReadoutKeepsItsPlace() throws {
        let band = Self.defaultBand
        let frame = try XCTUnwrap(Band.pictureFrame(in: band))
        let textWidth = Band.textWidth(beside: frame)
        XCTAssertEqual(textWidth, frame.minX - 20, accuracy: 0.01)

        let image = try render(fixturePane(), size: Self.pane(band))
        let top: CGFloat = 6

        // The picture is drawn where the layout put it.
        XCTAssertEqual(image.color(x: frame.midX, y: top + frame.midY), .red)
        // Headline row: blue up to the gutter, then nothing until the readout.
        XCTAssertEqual(image.color(x: textWidth - 2, y: top + 10), .blue)
        XCTAssertEqual(image.color(x: textWidth + 2, y: top + 2), .clear, "the gutter before the picture")
        XCTAssertNil(image.firstX(of: .blue, inRow: top + 10, from: textWidth + 1),
                     "the headline never runs under the picture")
        XCTAssertEqual(image.color(x: band.width - 2, y: top + 10), .green, "the readout keeps the right edge")
        XCTAssertEqual(image.color(x: band.width - 148, y: top + 10), .green, "and its full 150 pt")
        // Ticker: yellow at the bottom of the band, stopping at the same gutter.
        let tickerY = top + band.height - 4
        XCTAssertEqual(image.color(x: textWidth - 2, y: tickerY), .yellow)
        XCTAssertNil(image.firstX(of: .yellow, inRow: tickerY, from: textWidth + 1),
                     "the ticker never runs under the picture")
        // The rail sits right under the band, below its own 6 pt gap.
        XCTAssertEqual(image.color(x: 2, y: top + band.height + 6 + 2), .cyan)
        image.assertRailNeverOverprinted()
        XCTAssertNil(image.firstRow(of: .magenta), "the meta steps aside beside a picture")
    }

    func testAShortBandFallsBackToThePlainPane() throws {
        let size = Self.pane(Self.shortBand)
        let image = try render(fixturePane(headlineHeight: 20, readoutHeight: 20, tickerHeight: 6), size: size)
        XCTAssertNil(image.firstRow(of: .red), "no picture")
        // The plain pane: headline to the 24 pt gap before the readout.
        XCTAssertEqual(image.color(x: size.width - 150 - 24 - 2, y: 16), .blue)
        XCTAssertEqual(image.color(x: size.width - 150 - 12, y: 16), .clear)
        XCTAssertEqual(image.color(x: size.width - 2, y: 16), .green)
        // Full-width ticker just above the rail, its meta back at the end now
        // the picture is gone.
        XCTAssertEqual(image.color(x: size.width - 40 - 2, y: size.height - 48 - 2), .yellow)
        XCTAssertEqual(image.color(x: size.width - 2, y: size.height - 48 - 2), .magenta)
        image.assertRailNeverOverprinted()
    }

    /// The text taller than the band: the fallback overflows like the plain
    /// pane, rail pushed down and clipped at the glass, never overprinted.
    func testAnOverflowingFallbackPushesTheRailDownRatherThanPrintingOverIt() throws {
        let size = Self.pane(Self.shortBand)
        let image = try render(fixturePane(), size: size)
        XCTAssertNil(image.firstRow(of: .red), "no picture")
        image.assertRailNeverOverprinted()
        let lastTicker = try XCTUnwrap(image.lastRow(of: .yellow))
        let firstRail = try XCTUnwrap(image.firstRow(of: .cyan), "the rail's top still shows")
        XCTAssertLessThan(lastTicker, firstRail)
    }

    /// Room for the picture, not for the text beside it: the text column
    /// overflows the same way, and the picture rides with it.
    func testATightBandKeepsThePictureAndTheRailClear() throws {
        let band = Self.tightBand
        let frame = try XCTUnwrap(Band.pictureFrame(in: band), "a 60 pt band keeps the picture")
        let image = try render(fixturePane(), size: Self.pane(band))
        XCTAssertEqual(image.color(x: frame.midX, y: 6 + frame.midY), .red)
        image.assertRailNeverOverprinted()
        let lastTicker = try XCTUnwrap(image.lastRow(of: .yellow))
        let lastPicture = try XCTUnwrap(image.lastRow(of: .red))
        let firstRail = try XCTUnwrap(image.firstRow(of: .cyan))
        XCTAssertLessThan(lastTicker, firstRail)
        XCTAssertLessThan(lastPicture, firstRail)
    }

    /// Below the window minimum a fixed-size ticker prefix can be wider than
    /// the text column; it is cut at the gutter, not drawn under the picture.
    func testANarrowBandCutsAFixedSizeTickerAtTheGutter() throws {
        let band = Self.narrowBand
        let frame = try XCTUnwrap(Band.pictureFrame(in: band), "700 pt still keeps the picture")
        let textWidth = Band.textWidth(beside: frame)
        XCTAssertLessThan(textWidth, 300)
        let image = try render(fixturePane(tickerPrefixWidth: 320, headlinePrefixWidth: 320),
                               size: Self.pane(band))
        let tickerY = 6 + band.height - 4
        XCTAssertEqual(image.color(x: textWidth - 2, y: tickerY), .yellow)
        XCTAssertNil(image.firstX(of: .yellow, inRow: tickerY, from: textWidth + 1),
                     "the prefix stops at the gutter")
        XCTAssertNil(image.firstX(of: .blue, inRow: 6 + 10, from: textWidth + 1),
                     "so does a headline that cannot shrink")
        XCTAssertEqual(image.color(x: frame.midX, y: 6 + frame.midY), .red)
        image.assertRailNeverOverprinted()
    }

    /// Writes realistic panes (text, a cell rail, the real glass and the real
    /// picture timeline from a fixture ledger) to `.build/busy-signals/` for
    /// a visual check. Gated, like the contact sheets:
    /// `CRATEDIGGER_BUSY_SNAPSHOTS=1 scripts/test.sh --filter BusyPictureBandTests`.
    func testWritePaneSnapshots() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CRATEDIGGER_BUSY_SNAPSHOTS"] != nil)
        let out = Self.repoRoot.appendingPathComponent(".build/busy-signals", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let now = Date()
        let cases: [(name: String, kind: BusyJobKind, title: String, sub: String, ticker: String,
                     header: CGFloat, finished: Bool, theme: CarbonTheme)] = [
            ("pane-rip", .rip, "CD-RIP", "Kind of Blue · Miles Davis · 5 tracks", "RIPPING · 03 / 05", 170, false, .carbon),
            ("pane-secure", .secureRead, "SECURE READ", "Kind of Blue · Miles Davis", "SECURE READ · TRACK 3/8 · PASS 2 · 40%", 170, false, .carbon),
            ("pane-convert", .convert, "CONVERT", "Converting · MP3 · Lossy", "WRITING · 07 / 12", 170, false, .carbon),
            ("pane-convert-done", .convert, "FLAC ► MP3", "Album folders · Template", "PREVIEW · 01 / 12", 170, true, .carbon),
            ("pane-scan", .scan, "DIGGING", "Scanning 1,204 files", "SCAN · /Volumes/Music/Jazz", 170, false, .carbon),
            ("pane-download", .download, "DOWNLOAD", "KEXP · Live on KEXP", "DOWNLOADING · 42%", 170, false, .carbon),
            ("pane-transfer", .transfer, "SYNC → IPOD", "Copying 4 of 20", "SYNC", 170, false, .carbon),
            ("pane-rip-llama", .rip, "CD-RIP", "Kind of Blue · Miles Davis · 5 tracks", "RIPPING · 03 / 05", 170, false,
             MonochromeGlassTests.llamaLikeTheme().monochromeGlass),
            ("pane-rip-header120", .rip, "CD-RIP", "Kind of Blue · Miles Davis · 5 tracks", "RIPPING · 03 / 05", 120, false, .carbon),
            ("pane-rip-header145", .rip, "CD-RIP", "Kind of Blue · Miles Davis · 5 tracks", "RIPPING · 03 / 05", 145, false, .carbon)
        ]
        for c in cases {
            var ledger = BusyLedger(screen: c.kind.defaultScreen, at: now.addingTimeInterval(-60))
            var progress = BusyProgress(completed: 2, total: 5, lossless: false)
            if c.kind == .secureRead {
                progress = BusyProgress(completed: 0, total: nil, lossless: true)
            }
            let id = ledger.begin(c.kind, on: c.kind.defaultScreen,
                                  labels: c.kind == .convert ? BusyLabels(source: "FLAC", target: "MP3")
                                      : (c.kind == .download ? BusyLabels(source: "KEXP") : BusyLabels()),
                                  progress: progress, at: now.addingTimeInterval(-9))
            if c.finished { ledger.finish(id, .completed, at: now.addingTimeInterval(-0.1)) }

            let glass = FixtureGlass(header: c.header, title: c.title, sub: c.sub, ticker: c.ticker) {
                BusySceneTimeline(ledger: ledger, recordID: id, style: .picture)
            }
            .environment(\.carbon, c.theme)
            let size = CGSize(width: fixtureGlassWidth, height: c.header)
            let renderer = ImageRenderer(content: glass.frame(width: size.width, height: size.height))
            renderer.scale = 2
            let cg: CGImage = try XCTUnwrap(renderer.cgImage, c.name)
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
            try png.write(to: out.appendingPathComponent("\(c.name).png"))
        }
    }

    // MARK: Fixtures

    /// A pane's worth of fixture slots. The ticker has a fixed-size prefix
    /// (`tickerPrefixWidth`, 0 = none) in front of a greedy path, like
    /// `DSPTicker`, and a magenta meta that, like `DSPTicker`'s, steps aside
    /// while a picture is shown; the headline can likewise lead with a part
    /// that refuses to shrink.
    private func fixturePane(headlineHeight: CGFloat = 40, readoutHeight: CGFloat = 40,
                             tickerHeight: CGFloat = 14, tickerPrefixWidth: CGFloat = 0,
                             headlinePrefixWidth: CGFloat = 0) -> some View {
        // Pure sRGB primaries: the system `.blue` and `.green` are tints that
        // the swatch reader would not recognise.
        BusyPictureBand {
            HStack(spacing: 0) {
                Color(red: 0, green: 0, blue: 1).frame(width: headlinePrefixWidth)
                Color(red: 0, green: 0, blue: 1).frame(maxWidth: .infinity)
            }
            .frame(height: headlineHeight)
        } readout: {
            Color(red: 0, green: 1, blue: 0).frame(width: 150, height: readoutHeight)
        } ticker: {
            FixtureTicker(prefixWidth: tickerPrefixWidth, height: tickerHeight)
        } cells: {
            Color(red: 0, green: 1, blue: 1).frame(height: 42).padding(.top, 6)
        } picture: {
            Color(red: 1, green: 0, blue: 0)
        }
    }

    private func render(_ view: some View, size: CGSize) throws -> Pixels {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 1
        return Pixels(try XCTUnwrap(renderer.cgImage))
    }

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}

/// A rough stand-in for the real glass around a job pane: the OLED's
/// background and gradient, a rail line, the band with pane-like type, and a
/// five-cell rail. Only the band is the real code; the rest is there so the
/// picture can be judged in context.
/// The glass around an 838 pt pane: 18 pt of padding each side.
private let fixtureGlassWidth: CGFloat = 874

private struct FixtureGlass<Picture: View>: View {
    let header: CGFloat
    let title: String
    let sub: String
    let ticker: String
    @ViewBuilder var picture: () -> Picture
    @Environment(\.carbon) private var theme

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(theme.oledSurface)
                .overlay(LinearGradient(colors: [Color.white.opacity(0.04), .clear, theme.oledSurfaceShade],
                                        startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("02:41 / 07:22   SO WHAT").foregroundStyle(theme.oledForeground)
                    Spacer()
                    Text("NOW  CNVRT  SCAN  SYNC  DUB  DEV  SRCH  STAT  ON AIR")
                        .foregroundStyle(theme.oledForeground.opacity(0.3))
                }
                .font(CarbonFont.mono(9, weight: .bold))
                .padding(.bottom, 7)
                VStack(alignment: .leading, spacing: 0) {
                    BusyPictureBand {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title).font(CarbonFont.display(44, weight: .thin))
                                .foregroundStyle(theme.oledForeground).lineLimit(1).minimumScaleFactor(0.55)
                            Text(sub).font(CarbonFont.mono(9.5, weight: .semibold)).tracking(1.9)
                                .foregroundStyle(theme.oledForeground.opacity(0.55)).lineLimit(1)
                        }
                    } readout: {
                        VStack(alignment: .trailing, spacing: 6) {
                            Text("03 / 05").font(CarbonFont.display(34, weight: .thin))
                                .foregroundStyle(theme.oledForeground)
                            Capsule().fill(theme.orange).frame(width: 150, height: 5)
                        }
                        .fixedSize()
                    } ticker: {
                        HStack(spacing: 12) {
                            Text(ticker).font(CarbonFont.mono(8.5, weight: .bold)).tracking(1.9).fixedSize()
                                .foregroundStyle(theme.oledForeground.opacity(0.5))
                            Text("~/Music/Miles Davis/Kind of Blue/03 Blue in Green.flac")
                                .font(CarbonFont.mono(10)).lineLimit(1).truncationMode(.head)
                                .foregroundStyle(theme.oledForeground)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.bottom, 4)
                    } cells: {
                        HStack(spacing: 0) {
                            ForEach(["Disc", "Output", "Speed", "Elapsed", "Remain"], id: \.self) { key in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(key.uppercased()).font(CarbonFont.mono(8, weight: .bold))
                                        .foregroundStyle(theme.oledForeground.opacity(0.5))
                                    Text("CDDA").font(CarbonFont.display(18, weight: .light))
                                        .foregroundStyle(theme.oledForeground)
                                }
                                .padding(.horizontal, 10)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                                .overlay(alignment: .trailing) {
                                    Rectangle().fill(theme.oledForeground.opacity(0.12)).frame(width: 1)
                                }
                            }
                        }
                        .frame(height: 48)
                    } picture: {
                        picture()
                    }
                }
            }
            .padding(.top, 8)
            .padding(.horizontal, 18)
            .padding(.bottom, 4)
        }
    }
}

/// The fixture's ticker: a fixed-size prefix, a path that takes what is left,
/// and a meta that steps aside while a picture is shown, as `DSPTicker` does.
private struct FixtureTicker: View {
    let prefixWidth: CGFloat
    let height: CGFloat
    @Environment(\.busyPictureShown) private var pictureShown

    var body: some View {
        HStack(spacing: 0) {
            Color(red: 1, green: 1, blue: 0).frame(width: prefixWidth)
            Color(red: 1, green: 1, blue: 0).frame(maxWidth: .infinity)
            if !pictureShown {
                Color(red: 1, green: 0, blue: 1).frame(width: 40)
            }
        }
        .frame(height: height)
    }
}

/// Reads a rendered image's pixels as the fixture colours.
private struct Pixels {
    enum Swatch: Equatable { case red, green, blue, yellow, cyan, magenta, clear, other }

    let rep: NSBitmapImageRep

    init(_ image: CGImage) { rep = NSBitmapImageRep(cgImage: image) }

    func color(x: CGFloat, y: CGFloat) -> Swatch {
        guard let c = rep.colorAt(x: Int(x), y: Int(y))?.usingColorSpace(.sRGB) else { return .other }
        func on(_ v: CGFloat) -> Bool { v > 0.5 }
        if c.alphaComponent < 0.1 { return .clear }
        switch (on(c.redComponent), on(c.greenComponent), on(c.blueComponent)) {
        case (true, false, false): return .red
        case (false, true, false): return .green
        case (false, false, true): return .blue
        case (true, true, false): return .yellow
        case (false, true, true): return .cyan
        case (true, false, true): return .magenta
        default: return .other
        }
    }

    /// The first x at or after `from` in row `y` that reads `swatch`.
    func firstX(of swatch: Swatch, inRow y: CGFloat, from: CGFloat) -> Int? {
        (Int(from)..<rep.pixelsWide).first { color(x: CGFloat($0), y: y) == swatch }
    }

    func row(_ y: Int, contains swatch: Swatch) -> Bool {
        firstX(of: swatch, inRow: CGFloat(y), from: 0) != nil
    }

    /// The first and last rows holding any pixel of `swatch`.
    func firstRow(of swatch: Swatch) -> Int? { (0..<rep.pixelsHigh).first { row($0, contains: swatch) } }
    func lastRow(of swatch: Swatch) -> Int? { (0..<rep.pixelsHigh).last { row($0, contains: swatch) } }

    /// No row that shows the cell rail shows headline, ticker or picture too:
    /// the solid fixtures would replace the cyan wherever they overlapped,
    /// so any rail row reading another slot's colour is an overprint.
    func assertRailNeverOverprinted(file: StaticString = #filePath, line: UInt = #line) {
        guard let first = firstRow(of: .cyan) else { return }
        for y in first..<rep.pixelsHigh {
            for intruder in [Swatch.blue, .yellow, .red] where row(y, contains: intruder) {
                XCTFail("row \(y) of the cell rail shows \(intruder)", file: file, line: line)
                return
            }
        }
    }
}
#endif
