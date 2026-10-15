#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

/// Which jobs get a mini on the annunciator rail, and how many fit. The width
/// ladder is the 1200 pt minimum window's guard: the cluster drops a mini, then
/// both, then the "+N" too, and never clips.
final class BusyRailTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    // MARK: Entries

    func testOwnScreenIsExcluded() {
        var l = BusyLedger(screen: .conversion, at: t0)
        _ = l.begin(.convert, on: .conversion, at: at(0))
        let scan = l.begin(.scan, on: .scan, at: at(1))
        XCTAssertEqual(BusyRail.entries(l).map(\.id), [scan])
    }

    /// The ledger only marks a record seen while its screen is on the glass,
    /// and retires it as soon as the glass leaves, so a seen record never
    /// reaches the rail by either road: on its screen it is the picture, and
    /// off it it is gone.
    func testRunningAndUnseenAreIncludedAndSeenIsExcluded() {
        var l = BusyLedger(screen: .other, at: t0)
        let running = l.begin(.scan, on: .scan, at: at(0))
        let unseen = l.begin(.download, on: .dub, at: at(1))
        l.finish(unseen, .completed, at: at(5))
        let seen = l.begin(.convert, on: .conversion, at: at(2))
        l.finish(seen, .completed, at: at(6))
        XCTAssertEqual(BusyRail.entries(l).map(\.id), [running, unseen, seen],
                       "finished but unseen: all three blink or run on the rail")

        l.show(.conversion, at: at(7))
        _ = l.settle(at: at(20))
        XCTAssertNotNil(l.record(seen)?.seenAt)
        XCTAssertEqual(BusyRail.entries(l).map(\.id), [running, unseen])

        l.show(.other, at: at(30))
        XCTAssertNil(l.record(seen), "leaving retires the seen job")
        XCTAssertEqual(BusyRail.entries(l).map(\.id), [running, unseen])
    }

    func testEntriesAreInStartOrder() {
        var l = BusyLedger(screen: .other, at: t0)
        let a = l.begin(.transfer, on: .devices, at: at(0))
        let b = l.begin(.scan, on: .scan, at: at(1))
        let c = l.begin(.download, on: .dub, at: at(2))
        l.finish(a, .completed, at: at(3))
        XCTAssertEqual(BusyRail.entries(l).map(\.id), [a, b, c],
                       "finishing never reshuffles the rail")
    }

    func testOtherScreenQualifiesEveryJob() {
        var l = BusyLedger(screen: .other, at: t0)
        let ids = [l.begin(.rip, on: .dub, at: at(0)),
                   l.begin(.convert, on: .conversion, at: at(1)),
                   l.begin(.scan, on: .scan, at: at(2)),
                   l.begin(.transfer, on: .devices, at: at(3))]
        XCTAssertEqual(BusyRail.entries(l).map(\.id), ids, "compact pins NOW, which is .other")
    }

    // MARK: Layout

    private func threeEntries() -> [BusyJobRecord] {
        var l = BusyLedger(screen: .other, at: t0)
        _ = l.begin(.rip, on: .dub, at: at(0))
        _ = l.begin(.convert, on: .conversion, at: at(1))
        _ = l.begin(.scan, on: .scan, at: at(2))
        return BusyRail.entries(l)
    }

    func testWidthLadderTwoPlusOverflow() {
        let e = threeEntries()
        let layout = BusyRail.layout(e, available: 300, overflowLabelWidth: 16)
        XCTAssertEqual(layout, BusyRailLayout(shown: [e[0].id, e[1].id], overflow: 1, width: 246))
    }

    func testWidthLadderOnePlusOverflow() {
        let e = threeEntries()
        let layout = BusyRail.layout(e, available: 240, overflowLabelWidth: 16)
        XCTAssertEqual(layout, BusyRailLayout(shown: [e[0].id], overflow: 2, width: 138))
    }

    func testWidthLadderOverflowOnly() {
        let e = threeEntries()
        let layout = BusyRail.layout(e, available: 100, overflowLabelWidth: 16)
        XCTAssertEqual(layout, BusyRailLayout(shown: [], overflow: 3, width: 30))
    }

    func testWidthLadderEmptyRatherThanClipped() {
        let e = threeEntries()
        let layout = BusyRail.layout(e, available: 20, overflowLabelWidth: 16)
        XCTAssertEqual(layout, BusyRailLayout(shown: [], overflow: 0, width: 0))
    }

    func testAtMostTwoShownEvenWithRoom() {
        let e = threeEntries()
        let layout = BusyRail.layout(e, available: 10_000, overflowLabelWidth: 16)
        XCTAssertEqual(layout.shown.count, 2)
        XCTAssertEqual(layout.overflow, 1)
    }

    func testTwoEntriesThatExactlyFitNeedNoLabel() {
        let e = Array(threeEntries().prefix(2))
        let layout = BusyRail.layout(e, available: 218, overflowLabelWidth: 16)
        XCTAssertEqual(layout, BusyRailLayout(shown: [e[0].id, e[1].id], overflow: 0, width: 218))
    }

    func testZeroEntriesTakeNoWidth() {
        let layout = BusyRail.layout([], available: 500, overflowLabelWidth: 16)
        XCTAssertEqual(layout, BusyRailLayout(shown: [], overflow: 0, width: 0))
    }
}
#endif
