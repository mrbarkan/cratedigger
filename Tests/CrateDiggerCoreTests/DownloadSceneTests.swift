#if canImport(XCTest)
import CoreGraphics
import XCTest
@testable import CrateDiggerCore

/// The download scene's own invariants (spec §3.2, §11.1): the approved
/// cassette's proportions and stadium window, packs that follow the fraction,
/// and a finished picture that holds still while only its mini blinks.
final class DownloadSceneTests: XCTestCase {
    // MARK: - Inputs

    static func input(fraction: Double?, time: TimeInterval, finished: TimeInterval? = nil,
                      lit: Bool = true, source: String? = "KEXP") -> BusySceneInput {
        let q = BusySignalTiming.quantized
        return BusySceneInput(
            progress: BusyProgress(completed: fraction.map { Int(($0 * 100).rounded(.down)) } ?? 0,
                                   total: fraction == nil ? nil : 100),
            labels: BusyLabels(source: source),
            time: q(time), unitTime: q(time), unitFraction: 0,
            finished: finished.map(q), markLit: lit, still: false, blinking: finished != nil)
    }

    // MARK: - Cassette

    func testCassetteIsOnePointFiveSevenToOne() throws {
        let d = DownloadScene.picture(Self.input(fraction: 0.4, time: 1.3))
        let shell = try XCTUnwrap(Self.roundedRects(in: d).first { $0.stroke == .foreground && $0.fill == .background },
                                  "the cassette shell is a background-filled rounded rect")
        XCTAssertEqual(shell.rect.size, CGSize(width: 104, height: 66))
        XCTAssertEqual(shell.rect.width / shell.rect.height, 1.576, accuracy: 0.01,
                       "a compact cassette is 100.4 × 63.8 mm")
    }

    func testWindowIsAStadiumWithAHubInEachEnd() throws {
        let d = DownloadScene.picture(Self.input(fraction: 0.4, time: 1.3))
        let window = CGRect(x: 137, y: 36, width: 62, height: 18)

        let stroke = try XCTUnwrap(Self.roundedRects(in: d).first { $0.rect == window },
                                   "the window is outlined")
        XCTAssertEqual(stroke.radius, window.height / 2, "a stadium: its ends are half-circles")

        let clip = d.shapes.compactMap { shape -> (CGRect, CGFloat)? in
            if case let .clipBegin(rect, radius) = shape { return (rect, radius) }
            return nil
        }
        XCTAssertEqual(clip.count, 1)
        XCTAssertEqual(clip.first?.0, window, "the packs are clipped to the window")
        XCTAssertEqual(clip.first?.1, window.height / 2)

        // The hubs are the background-filled circles: each one masks the
        // pack behind it, so its spokes read on a clear face.
        let hubs = Self.circles(in: d).filter { $0.fill == .background }.map(\.center)
        XCTAssertEqual(hubs, [CGPoint(x: 146, y: 45), CGPoint(x: 190, y: 45)],
                       "one hub centred in each round end (wx + 9 and wx + ww - 9)")
    }

    func testPacksFollowFraction() {
        func packs(_ fraction: Double?) -> (supply: CGFloat?, takeUp: CGFloat?) {
            let d = DownloadScene.picture(Self.input(fraction: fraction, time: 1.3))
            let circles = Self.circles(in: d)
            return (circles.first { $0.center == CGPoint(x: 146, y: 45) && $0.stroke == .dim }?.radius,
                    circles.first { $0.center == CGPoint(x: 190, y: 45) && $0.stroke == .cool }?.radius)
        }
        let early = packs(0.1), late = packs(1)
        XCTAssertEqual(early.supply ?? 0, 6 + 9 * 0.9, accuracy: 1e-9)
        XCTAssertEqual(early.takeUp ?? 0, 6 + 9 * 0.1, accuracy: 1e-9)
        XCTAssertGreaterThan(late.takeUp ?? 0, early.takeUp ?? .infinity, "take-up grows with the fraction")
        XCTAssertLessThan(late.supply ?? .infinity, early.supply ?? 0, "supply shrinks with the fraction")

        let unknown = packs(nil)
        XCTAssertEqual(unknown.takeUp ?? 0, 6, accuracy: 1e-9, "an unknown total reads as an empty take-up")
    }

    func testPacksStayFullOnceFinished() {
        let d = DownloadScene.picture(Self.input(fraction: nil, time: 4, finished: 1))
        let takeUp = Self.circles(in: d).first { $0.center == CGPoint(x: 190, y: 45) && $0.stroke == .cool }
        XCTAssertEqual(takeUp?.radius ?? 0, 15, accuracy: 1e-9,
                       "a finished download is a full take-up, as the sketch's done state is p = 1")
    }

    // MARK: - Label

    func testLabelPrintsTheChannelOrStream() {
        XCTAssertEqual(Self.texts(in: DownloadScene.picture(Self.input(fraction: 0.4, time: 1.3))),
                       [Text(string: "KEXP", ink: .dim), Text(string: "A", ink: .foreground)])
        XCTAssertEqual(Self.texts(in: DownloadScene.picture(Self.input(fraction: 0.4, time: 1.3, source: nil))),
                       [Text(string: "STREAM", ink: .dim), Text(string: "A", ink: .foreground)])
    }

    // MARK: - Finished

    func testHubsStopAndLabelReadsDoneWhenFinished() {
        let lit = DownloadScene.picture(Self.input(fraction: 1, time: 3.3, finished: 2, lit: true))
        let unlit = DownloadScene.picture(Self.input(fraction: 1, time: 3.3, finished: 2.5, lit: false))
        XCTAssertEqual(Self.texts(in: lit).first, Text(string: "DONE", ink: .hot))
        XCTAssertEqual(lit, unlit, "no blinking element in the approved finished cassette (html:702)")

        // Stopped: two finished frames at different scene times draw alike,
        // hubs, rings and data line included.
        let other = DownloadScene.picture(Self.input(fraction: 1, time: 7.7, finished: 2))
        XCTAssertEqual(lit, other)
        XCTAssertTrue(Self.blocks(in: lit, .cool).isEmpty, "no data in flight once finished")
        XCTAssertFalse(Self.arcs(in: lit).contains { $0 == .cool }, "the mast's rings go dark")
    }

    func testRunningHubsTurnAndDataMovesWithTheClock() {
        let a = DownloadScene.picture(Self.input(fraction: 0.4, time: 1.0))
        let b = DownloadScene.picture(Self.input(fraction: 0.4, time: 1.125))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(Self.blocks(in: a, .cool).count, 7, "seven data blocks on the line")
        XCTAssertTrue(Self.blocks(in: a, .cool).allSatisfy { $0.minX >= 36.8 && $0.maxX <= 113.2 },
                      "data stays on the line between mast and cassette")
    }

    func testMastRingsLightInTurn() {
        // floor(time / 0.25) % 4 rings lit, two arcs each.
        for (time, lit) in [(0.0, 0), (0.25, 1), (0.5, 2), (0.75, 3), (1.0, 0)] {
            let d = DownloadScene.picture(Self.input(fraction: 0.4, time: time))
            XCTAssertEqual(Self.arcs(in: d).filter { $0 == .cool }.count, lit * 2, "at \(time)")
            XCTAssertEqual(Self.arcs(in: d).count, 6, "at \(time)")
        }
    }

    func testKeyTimeShowsTheMastMidPulse() {
        let d = DownloadScene.picture(Self.input(fraction: 0.4, time: DownloadScene.keyTime))
        XCTAssertEqual(Self.arcs(in: d).filter { $0 == .cool }.count, 4)
    }

    // MARK: - Mini

    func testMiniDestinationBlinks() {
        let lit = DownloadScene.mini(Self.input(fraction: 1, time: 3, finished: 1, lit: true))
        let unlit = DownloadScene.mini(Self.input(fraction: 1, time: 3, finished: 1.5, lit: false))
        XCTAssertNotEqual(lit, unlit)
        XCTAssertTrue(Self.roundedRects(in: lit).contains { $0.stroke == .hot }, "the cassette lights hot")
        XCTAssertTrue(Self.roundedRects(in: unlit).allSatisfy { $0.stroke == .foreground })
    }

    func testMiniAntennaPulsesOnEvenStepsWhileRunning() {
        XCTAssertEqual(Self.arcs(in: DownloadScene.mini(Self.input(fraction: 0.4, time: 0.25))).count, 2)
        XCTAssertEqual(Self.arcs(in: DownloadScene.mini(Self.input(fraction: 0.4, time: 0.375))).count, 0)
        XCTAssertEqual(Self.arcs(in: DownloadScene.mini(Self.input(fraction: 0.4, time: 0.25, finished: 1))).count, 0)
    }

    func testMiniStaysInsideItsStrip() {
        for time in [0.0, 0.125, 0.25, 3.3] {
            let d = DownloadScene.mini(Self.input(fraction: 0.4, time: time))
            XCTAssertTrue(CGRect(origin: .zero, size: BusyDrawing.miniSize).insetBy(dx: -0.5, dy: -0.5)
                .contains(d.bounds), "\(time): \(d.bounds)")
        }
    }

    // MARK: - Helpers

    struct Text: Equatable {
        var string: String
        var ink: BusyInk
    }

    static func texts(in d: BusyDrawing) -> [Text] {
        d.shapes.compactMap {
            if case let .text(string, _, _, _, ink) = $0 { return Text(string: string, ink: ink) }
            return nil
        }
    }

    static func roundedRects(in d: BusyDrawing) -> [(rect: CGRect, radius: CGFloat, stroke: BusyInk?, fill: BusyInk?)] {
        d.shapes.compactMap {
            if case let .roundedRect(rect, radius, stroke, fill) = $0 { return (rect, radius, stroke, fill) }
            return nil
        }
    }

    static func circles(in d: BusyDrawing) -> [(center: CGPoint, radius: CGFloat, stroke: BusyInk?, fill: BusyInk?)] {
        d.shapes.compactMap {
            if case let .circle(center, radius, stroke, fill) = $0 { return (center, radius, stroke, fill) }
            return nil
        }
    }

    static func arcs(in d: BusyDrawing) -> [BusyInk] {
        d.shapes.compactMap {
            if case let .arc(_, _, _, _, ink) = $0 { return ink }
            return nil
        }
    }

    /// Filled rects with no stroke: `block`s.
    static func blocks(in d: BusyDrawing, _ ink: BusyInk) -> [CGRect] {
        d.shapes.compactMap {
            if case let .rect(rect, nil, fill) = $0, fill == ink { return rect }
            return nil
        }
    }
}
#endif
