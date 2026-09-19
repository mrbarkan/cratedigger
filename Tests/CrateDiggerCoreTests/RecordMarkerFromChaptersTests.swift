#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

final class RecordMarkerFromChaptersTests: XCTestCase {
    private func ch(_ s: Double, _ e: Double?, _ t: String) -> StreamChapter {
        StreamChapter(startSeconds: s, endSeconds: e, title: t)
    }

    func testEachChapterClosesOnTheNextOnesStart() {
        let m = RecordMarker.markers(from: [ch(0, 200, "A"), ch(180, nil, "B"), ch(400, nil, "C")], duration: 600)
        XCTAssertEqual(m.map(\.startSeconds), [0, 180, 400])
        XCTAssertEqual(m.map(\.endSeconds), [180, 400, 600])   // never overlaps, last closes on the file
        XCTAssertEqual(m.map(\.title), ["A", "B", "C"])
    }

    func testLastChapterFallsBackToItsOwnEndWithoutADuration() {
        let m = RecordMarker.markers(from: [ch(0, nil, "A"), ch(100, 250, "B")], duration: nil)
        XCTAssertEqual(m.last?.endSeconds, 250)
    }

    func testOpenEndedLastChapterWithNoDurationIsDropped() {
        let m = RecordMarker.markers(from: [ch(0, nil, "A"), ch(100, nil, "B"), ch(200, nil, "C")], duration: nil)
        XCTAssertEqual(m.map(\.title), ["A", "B"])
    }

    func testUnsortedInputIsSorted() {
        let m = RecordMarker.markers(from: [ch(100, nil, "B"), ch(0, nil, "A")], duration: 300)
        XCTAssertEqual(m.map(\.title), ["A", "B"])
    }

    func testSubSecondChaptersAreDropped() {
        let m = RecordMarker.markers(from: [ch(0, nil, "A"), ch(100, nil, "blip"), ch(100.4, nil, "B")], duration: 300)
        XCTAssertEqual(m.map(\.title), ["A", "B"])
    }

    func testFewerThanTwoChaptersMeansUndivided() {
        XCTAssertTrue(RecordMarker.markers(from: [], duration: 300).isEmpty)
        XCTAssertTrue(RecordMarker.markers(from: [ch(0, nil, "Only")], duration: 300).isEmpty)
    }
}
#endif
