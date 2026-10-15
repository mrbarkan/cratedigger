#if canImport(XCTest)
import AppKit
import CoreText
import CrateDiggerCore
import SwiftUI
import XCTest
@testable import CrateDiggerApp

/// The annunciator rail's Busy Signals cluster (spec §4), rendered offscreen
/// with `ImageRenderer` from fixture ledgers, so the rail is checked without
/// a view model or a running app. What still needs the running app (the
/// click, the titlebar drag band, compact) is listed in the Task 18 report.
@MainActor
final class BusyRailMinisTests: XCTestCase {
    private let now = Date()

    override func setUp() {
        super.setUp()
        FontRegistrar.registerBundledFonts()
    }

    // MARK: Width budget

    func testAvailableIsTheRailLessTheAnnunciatorsAndRailLivesFloor() {
        XCTAssertEqual(BusyRailSlot.available(railWidth: 900, annunciatorWidth: 400, onNowPlaying: true), 414)
        XCTAssertEqual(BusyRailSlot.available(railWidth: 900, annunciatorWidth: 400, onNowPlaying: false), 322)
        XCTAssertEqual(BusyRailSlot.available(railWidth: 300, annunciatorWidth: 400, onNowPlaying: false), 0,
                       "never negative, so a rail not yet measured shows nothing")
    }

    /// The cluster draws with its own copies of `BusyRail`'s internal sizes;
    /// the layout's width must be exactly what the cluster occupies.
    func testClusterSizesMatchCoresLayout() {
        let ledger = ledger(kinds: [.rip, .scan, .download])
        let entries = BusyRail.entries(ledger)
        let mini = BusyRailCluster.miniSize.width, gap = BusyRailCluster.spacing, tail = BusyRailCluster.trailing
        XCTAssertEqual(BusyRailCluster.miniSize, CGSize(width: 96, height: 12))
        XCTAssertEqual(BusyRail.layout(Array(entries.prefix(1)), available: 1_000,
                                       overflowLabelWidth: BusyRailSlot.overflowLabelWidth).width,
                       mini + tail)
        XCTAssertEqual(BusyRail.layout(Array(entries.prefix(2)), available: 1_000,
                                       overflowLabelWidth: BusyRailSlot.overflowLabelWidth).width,
                       2 * mini + gap + tail)
        XCTAssertEqual(BusyRail.layout(entries, available: 1_000,
                                       overflowLabelWidth: BusyRailSlot.overflowLabelWidth).width,
                       2 * mini + 2 * gap + BusyRailSlot.overflowLabelWidth + tail)
    }

    /// "+N" fits its budget in the bundled mono, up to two digits.
    func testOverflowLabelFitsItsBudget() throws {
        for label in ["+1", "+9", "+12"] {
            let image = try render(Text(label).font(CarbonFont.mono(8, weight: .bold)).fixedSize(), scale: 1)
            XCTAssertLessThanOrEqual(CGFloat(image.width), BusyRailSlot.overflowLabelWidth, label)
        }
    }

    // MARK: Accessibility

    func testAccessibilityNamesTheJobItsProgressAndItsScreen() throws {
        var ledger = BusyLedger(screen: .other, at: now)
        let rip = ledger.begin(.rip, on: .dub, labels: .init(),
                               progress: BusyProgress(completed: 2, total: 5), at: now)
        let scan = ledger.begin(.scan, on: .scan, labels: .init(), progress: BusyProgress(), at: now)
        let convert = ledger.begin(.convert, on: .conversion, labels: .init(),
                                   progress: BusyProgress(completed: 1, total: 3), at: now)
        ledger.finish(convert, .completed, at: now)

        let ripRecord = try XCTUnwrap(ledger.record(rip))
        XCTAssertEqual(BusyRailSlot.accessibilityLabel(for: ripRecord), "CD-RIP, 40 percent")
        XCTAssertEqual(BusyRailSlot.accessibilityHint(for: ripRecord), "Shows the DUB screen")
        XCTAssertEqual(BusyRailSlot.accessibilityLabel(for: try XCTUnwrap(ledger.record(scan))), "SCAN",
                       "an unknown total says no number rather than 0 percent")
        let convertRecord = try XCTUnwrap(ledger.record(convert))
        XCTAssertEqual(BusyRailSlot.accessibilityLabel(for: convertRecord), "CONVERT, finished")
        XCTAssertEqual(BusyRailSlot.accessibilityHint(for: convertRecord), "Shows the CNVRT screen")
    }

    // MARK: Rendering

    /// The rail is one text line tall, and a mini (12 pt) is taller than
    /// that line on Llama '97 (≈ 9.8 pt): the slot must add no height, in
    /// either font.
    func testMinisNeverChangeTheRailsHeight() throws {
        let llama = try llamaMono()
        for font in [CarbonFont.mono(9, weight: .bold), llama] {
            let idle = try render(FixtureRail(ledger: BusyLedger(screen: .other, at: now), font: font))
            let busy = try render(FixtureRail(ledger: ledger(kinds: [.rip, .scan, .download]), font: font))
            XCTAssertEqual(idle.height, busy.height)
        }
        // And the Llama line really is shorter than a mini, or the check
        // above would prove nothing.
        let line = try render(Text("NOW").font(llama).fixedSize(), scale: 1)
        XCTAssertLessThan(CGFloat(line.height), BusyRailCluster.miniSize.height)
    }

    /// Drawn unclipped, centred on the line: two minis, then "+1", inside
    /// the slot's width, and no pixel more than 6 pt above or below centre.
    func testTheClusterDrawsTwoMinisAndAnOverflowCentredOnTheLine() throws {
        let ledger = ledger(kinds: [.rip, .scan, .download])
        let height: CGFloat = 40
        let slot = BusyRailSlot(ledger: ledger, available: 1_000, guardsWindowDrag: false, select: { _ in })
        let pixels = try Lit(render(slot.frame(width: 300, height: height).background(Color.black), scale: 1))
        // The slot (two minis, "+1" and the trailing gap: 246 pt) is centred
        // in 300, and the cluster is leading-aligned in it.
        let left: CGFloat = (300 - 246) / 2
        XCTAssertTrue(pixels.anyLit(x: left ..< left + 96), "first mini")
        XCTAssertTrue(pixels.anyLit(x: left + 108 ..< left + 204), "second mini")
        XCTAssertTrue(pixels.anyLit(x: left + 216 ..< left + 232), "+1")
        XCTAssertFalse(pixels.anyLit(x: left + 232 ..< 300), "the 14 pt gap before the annunciators")
        let rows = try XCTUnwrap(pixels.litRows())
        XCTAssertGreaterThanOrEqual(CGFloat(rows.lowerBound), height / 2 - 6)
        XCTAssertLessThanOrEqual(CGFloat(rows.upperBound), height / 2 + 6)
    }

    func testAJobOnTheGlasssOwnScreenGetsNoMini() throws {
        var ledger = BusyLedger(screen: .dub, at: now)
        ledger.begin(.rip, on: .dub, labels: .init(), progress: BusyProgress(), at: now)
        let slot = BusyRailSlot(ledger: ledger, available: 1_000, guardsWindowDrag: false, select: { _ in })
        let pixels = try Lit(render(slot.frame(width: 300, height: 40).background(Color.black), scale: 1))
        XCTAssertNil(pixels.litRows())
    }

    /// Writes rail renders to `.build/busy-signals/` for a visual check.
    /// Gated like the pane snapshots:
    /// `CRATEDIGGER_BUSY_SNAPSHOTS=1 scripts/test.sh --filter BusyRailMinisTests`.
    func testWriteRailSnapshots() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CRATEDIGGER_BUSY_SNAPSHOTS"] != nil)
        let out = BusyPictureBandTests.repoRoot.appendingPathComponent(".build/busy-signals", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        var finished = BusyLedger(screen: .other, at: now.addingTimeInterval(-60))
        let rip = finished.begin(.rip, on: .dub, labels: .init(),
                                 progress: BusyProgress(completed: 5, total: 5), at: now.addingTimeInterval(-30))
        finished.finish(rip, .completed, at: now.addingTimeInterval(-0.3))

        let llama = MonochromeGlassTests.llamaLikeTheme().monochromeGlass
        let cases: [(String, BusyLedger, CarbonTheme, Font, String?)] = [
            ("rail-now-3jobs", ledger(kinds: [.rip, .scan, .download]), .carbon, CarbonFont.mono(9, weight: .bold), nil),
            ("rail-now-1job", ledger(kinds: [.convert]), .carbon, CarbonFont.mono(9, weight: .bold), nil),
            ("rail-now-finished", finished, .carbon, CarbonFont.mono(9, weight: .bold), nil),
            ("rail-now-notice", ledger(kinds: [.rip, .scan]), .carbon, CarbonFont.mono(9, weight: .bold), "VOLUME −3 dB"),
            ("rail-llama-3jobs", ledger(kinds: [.rip, .transfer, .scan]), llama, try llamaMono(), nil)
        ]
        for (name, ledger, theme, font, notice) in cases {
            let rail = FixtureRail(ledger: ledger, font: font, notice: notice)
                .padding(.vertical, 8).padding(.horizontal, 18)
                .background(theme.oledSurface)
                .environment(\.carbon, theme)
            let renderer = ImageRenderer(content: rail.frame(width: 874))
            renderer.scale = 2
            let cg = try XCTUnwrap(renderer.cgImage, name)
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
            try png.write(to: out.appendingPathComponent("\(name).png"))
        }
    }

    // MARK: Fixtures

    /// A ledger on `.other` (NOW) with one running job per kind, each on its
    /// default screen and partway through.
    private func ledger(kinds: [BusyJobKind]) -> BusyLedger {
        var ledger = BusyLedger(screen: .other, at: now.addingTimeInterval(-60))
        for kind in kinds {
            ledger.begin(kind, on: kind.defaultScreen, labels: .init(),
                         progress: BusyProgress(completed: 2, total: 5), at: now.addingTimeInterval(-9))
        }
        return ledger
    }

    /// Llama '97's rail font, registered from the bundled theme.
    private func llamaMono() throws -> Font {
        let url = BusyPictureBandTests.repoRoot
            .appendingPathComponent("Sources/CrateDiggerApp/Resources/Themes/Llama 97.cdtheme/Fonts/PixelOperatorMono8-Bold.ttf")
        let descriptors = try XCTUnwrap(CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])
        let name = try XCTUnwrap(CTFontDescriptorCopyAttribute(try XCTUnwrap(descriptors.first),
                                                               kCTFontNameAttribute) as? String)
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        return Font.custom(name, size: 9)
    }

    private func render(_ view: some View, scale: CGFloat = 2) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return try XCTUnwrap(renderer.cgImage)
    }
}

/// The rail's shape around the real `BusyRailSlot`: a flexible live title,
/// the slot, a fixed annunciator block, and the notice with its plate.
private struct FixtureRail: View {
    let ledger: BusyLedger
    let font: Font
    var notice: String?
    @Environment(\.carbon) private var theme

    var body: some View {
        HStack(spacing: 0) {
            Text("02:41  NOW PLAYING: SO WHAT · MILES DAVIS · KIND OF BLUE")
                .font(font).foregroundStyle(theme.oledForeground).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 14)
            BusyRailSlot(ledger: ledger, available: 380, guardsWindowDrag: false, select: { _ in })
            Text("NOW  CNVRT  SCAN  SYNC  DUB  DEV  SRCH  STAT  ON AIR")
                .font(font).foregroundStyle(theme.oledForeground.opacity(0.3)).fixedSize()
        }
        .overlay(alignment: .center) {
            if let notice {
                Text(notice).font(CarbonFont.mono(9, weight: .bold)).tracking(1.8)
                    .foregroundStyle(theme.sun).lineLimit(1).fixedSize()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(theme.oledSurface)
            }
        }
    }
}

/// Which pixels of a render on black are lit.
private struct Lit {
    let rep: NSBitmapImageRep

    init(_ image: CGImage) { rep = NSBitmapImageRep(cgImage: image) }

    func lit(_ x: Int, _ y: Int) -> Bool {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
        return max(c.redComponent, c.greenComponent, c.blueComponent) > 0.15
    }

    func anyLit(x range: Range<CGFloat>) -> Bool {
        let xs = max(0, Int(range.lowerBound)) ..< min(rep.pixelsWide, Int(range.upperBound))
        return xs.contains { x in (0 ..< rep.pixelsHigh).contains { lit(x, $0) } }
    }

    func litRows() -> ClosedRange<Int>? {
        let rows = (0 ..< rep.pixelsHigh).filter { y in (0 ..< rep.pixelsWide).contains { lit($0, y) } }
        guard let first = rows.first, let last = rows.last else { return nil }
        return first ... last
    }
}
#endif
