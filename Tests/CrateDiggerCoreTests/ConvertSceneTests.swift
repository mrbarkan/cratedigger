#if canImport(XCTest)
import CoreGraphics
import XCTest
@testable import CrateDiggerCore

/// The convert scene's own invariants (spec §11.1): a lossy file is squashed
/// flat under the press, a lossless one keeps its height and gets a new box,
/// the labels follow the file through the press and vanish when unknown, the
/// press parks with a blinking OK at the finish, and the mini's flat block
/// sits centred on the dashed line.
final class ConvertSceneTests: XCTestCase {
    /// A convert frame at raw scene `time` (one file passes every 2.4 s, so
    /// `time` 1.32 is u = 0.55, the file sitting squashed under the press).
    static func input(lossless: Bool, time: TimeInterval,
                      labels: BusyLabels = BusyLabels(source: "FLAC", target: "MP3"),
                      finished: TimeInterval? = nil, lit: Bool = true) -> BusySceneInput {
        BusySceneInput(progress: BusyProgress(completed: 3, total: 10, lossless: lossless),
                       labels: labels, time: time, unitTime: 0, unitFraction: 0,
                       finished: finished, markLit: lit, still: false, blinking: finished != nil)
    }

    /// Scene time at `u` through the first file's 2.4 s pass.
    static func time(atU u: Double) -> TimeInterval { u * ConvertScene.period }

    // MARK: - The press

    func testLossyFlattensTheFileUnderThePress() throws {
        let d = ConvertScene.picture(Self.input(lossless: false, time: Self.time(atU: 0.55)))
        let file = try XCTUnwrap(Self.fileRect(in: d))
        XCTAssertLessThanOrEqual(file.height, 14)
        XCTAssertEqual(file.maxY, 82, accuracy: 1e-9, "the file stands on the belt")
        XCTAssertEqual(file.midX, 120, accuracy: 1e-9, "under the press")
        XCTAssertFalse(Self.coolRects(in: d).contains { $0.contains(file) }, "lossy gets no new box")
    }

    func testLosslessReboxesWithoutSquashing() throws {
        let d = ConvertScene.picture(Self.input(lossless: true, time: Self.time(atU: 0.55)))
        let file = try XCTUnwrap(Self.fileRect(in: d))
        XCTAssertEqual(file.height, 40, accuracy: 1e-9)
        XCTAssertTrue(Self.coolRects(in: d).contains { $0.contains(file) }, "a cool box surrounds the file")
    }

    func testFileIsFullHeightBeforeThePress() throws {
        for lossless in [false, true] {
            let d = ConvertScene.picture(Self.input(lossless: lossless, time: Self.time(atU: 0.2)))
            let file = try XCTUnwrap(Self.fileRect(in: d))
            XCTAssertEqual(file.height, 40, accuracy: 1e-9)
            XCTAssertTrue(Self.coolRects(in: d).isEmpty, "no box before the press")
        }
    }

    func testKeyFrameShowsTheFileUnderThePress() throws {
        let lossy = ConvertScene.picture(Self.input(lossless: false, time: ConvertScene.keyTime))
        XCTAssertLessThanOrEqual(try XCTUnwrap(Self.fileRect(in: lossy)).height, 14)
        let lossless = ConvertScene.picture(Self.input(lossless: true, time: ConvertScene.keyTime))
        let file = try XCTUnwrap(Self.fileRect(in: lossless))
        XCTAssertTrue(Self.coolRects(in: lossless).contains { $0.contains(file) })
    }

    func testEachFileGetsItsOwnBars() {
        let first = ConvertScene.picture(Self.input(lossless: true, time: Self.time(atU: 0.2)))
        let second = ConvertScene.picture(Self.input(lossless: true, time: Self.time(atU: 0.2) + ConvertScene.period))
        XCTAssertNotEqual(Self.coolLines(in: first), Self.coolLines(in: second))
    }

    // MARK: - Labels

    func testLabelsFollowTheFileThroughThePress() {
        let before = ConvertScene.picture(Self.input(lossless: false, time: Self.time(atU: 0.2)))
        XCTAssertEqual(Self.texts(in: before).map(\.text), ["FLAC"])
        XCTAssertEqual(Self.texts(in: before).first?.ink, .dim)

        let after = ConvertScene.picture(Self.input(lossless: false, time: Self.time(atU: 0.8)))
        XCTAssertEqual(Self.texts(in: after).map(\.text), ["MP3"])
        XCTAssertEqual(Self.texts(in: after).first?.ink, .hot)
    }

    func testLabelsOmittedWhenMissing() {
        for u in [0.2, 0.55, 0.8] {
            for lossless in [false, true] {
                let d = ConvertScene.picture(Self.input(lossless: lossless, time: Self.time(atU: u),
                                                        labels: BusyLabels()))
                XCTAssertTrue(Self.texts(in: d).isEmpty, "u \(u) lossless \(lossless)")
            }
        }
        // Only the missing one goes: a known target still prints after the press.
        let targetOnly = ConvertScene.picture(Self.input(lossless: false, time: Self.time(atU: 0.8),
                                                         labels: BusyLabels(target: "AAC")))
        XCTAssertEqual(Self.texts(in: targetOnly).map(\.text), ["AAC"])
        let sourceOnly = ConvertScene.picture(Self.input(lossless: false, time: Self.time(atU: 0.8),
                                                         labels: BusyLabels(source: "WAV")))
        XCTAssertTrue(Self.texts(in: sourceOnly).isEmpty)
    }

    func testLongestLabelStaysOnTheGlassAtTheBeltEnds() {
        let long = BusyLabels(source: "ABCDEFGHIJKL", target: "ABCDEFGHIJKL")
        for u in [0.0, 0.99] {
            let d = ConvertScene.picture(Self.input(lossless: false, time: Self.time(atU: u), labels: long))
            XCTAssertTrue(BusySceneTests.isInside(d), "u \(u): \(d.bounds)")
        }
    }

    // MARK: - Finished

    func testPressParksAndOKBlinksWhenFinished() {
        // Finished mid-squash: the press is parked up anyway, and the file is gone.
        let lit = ConvertScene.picture(Self.input(lossless: false, time: Self.time(atU: 0.55), finished: 1, lit: true))
        XCTAssertNil(Self.fileRect(in: lit), "no file on the belt once finished")
        XCTAssertTrue(lit.shapes.contains(.rect(CGRect(x: 100, y: 20, width: 40, height: 4),
                                                stroke: .foreground, fill: .background)),
                      "the plate is parked at the top")
        XCTAssertEqual(Self.texts(in: lit).map(\.text), ["OK"])
        XCTAssertEqual(Self.texts(in: lit).first?.ink, .hot)

        let unlit = ConvertScene.picture(Self.input(lossless: false, time: Self.time(atU: 0.55), finished: 1.5, lit: false))
        XCTAssertTrue(Self.texts(in: unlit).isEmpty)
    }

    func testBeltStopsWhenFinished() {
        let a = ConvertScene.picture(Self.input(lossless: true, time: 7.125, finished: 1, lit: true))
        let b = ConvertScene.picture(Self.input(lossless: true, time: 3.5, finished: 6, lit: true))
        XCTAssertEqual(a, b, "a finished picture does not depend on when the job ran or finished")
    }

    // MARK: - Mini

    func testMiniFlatBlockIsCentredOnTheLine() throws {
        let lossy = ConvertScene.mini(Self.input(lossless: false, time: 1))
        let block = try XCTUnwrap(Self.destinationRects(in: lossy).first)
        XCTAssertEqual(block.midY, 6, accuracy: 0.05)
        XCTAssertLessThan(block.height, 6, "lossy is a flat block")

        let lossless = ConvertScene.mini(Self.input(lossless: true, time: 1))
        let rects = Self.destinationRects(in: lossless)
        XCTAssertEqual(rects.count, 2, "a cool box round a tall file")
        for rect in rects { XCTAssertEqual(rect.midY, 6, accuracy: 0.05) }
    }

    func testMiniDestinationBlinksWhenFinished() {
        let lit = ConvertScene.mini(Self.input(lossless: false, time: 1, finished: 1, lit: true))
        let unlit = ConvertScene.mini(Self.input(lossless: false, time: 1, finished: 1.5, lit: false))
        XCTAssertTrue(lit.shapes.contains { if case .rect(_, .hot, _) = $0 { return true }; return false })
        XCTAssertFalse(unlit.shapes.contains { if case .rect(_, .hot, _) = $0 { return true }; return false })
    }

    func testMiniSourceIsATallFile() {
        let d = ConvertScene.mini(Self.input(lossless: false, time: 1))
        XCTAssertTrue(d.shapes.contains(.rect(CGRect(x: 3, y: 1.2, width: 5.5, height: 9.6),
                                              stroke: .foreground, fill: nil)))
    }

    // MARK: - Helpers

    /// The file on the belt: the last foreground-outlined, background-filled
    /// rect (after the press head and the plate, which are drawn first).
    /// Nil when only those two are drawn.
    static func fileRect(in d: BusyDrawing) -> CGRect? {
        let boxes = d.shapes.compactMap { shape -> CGRect? in
            if case let .rect(rect, .foreground, .background) = shape { return rect }
            return nil
        }
        return boxes.count > 2 ? boxes.last : nil
    }

    static func coolRects(in d: BusyDrawing) -> [CGRect] {
        d.shapes.compactMap { shape in
            if case let .rect(rect, .cool, nil) = shape { return rect }
            return nil
        }
    }

    static func coolLines(in d: BusyDrawing) -> [BusyShape] {
        d.shapes.filter { if case .line(_, _, .cool, _) = $0 { return true }; return false }
    }

    static func texts(in d: BusyDrawing) -> [(text: String, ink: BusyInk)] {
        d.shapes.compactMap { shape in
            if case let .text(text, _, _, _, ink) = shape { return (text, ink) }
            return nil
        }
    }

    /// The mini destination's outlined rects, right of the track.
    static func destinationRects(in d: BusyDrawing) -> [CGRect] {
        d.shapes.compactMap { shape in
            if case let .rect(rect, stroke, _) = shape, stroke != nil, rect.minX > 80 { return rect }
            return nil
        }
    }
}
#endif
