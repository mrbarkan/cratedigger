#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class QueueDragTests: XCTestCase {

    private let queue = (0..<4).map { _ in UUID() }

    func testADropLandsAheadOfTheRowUnderIt() throws {
        let move = try XCTUnwrap(QueueDrag.move(payload: QueueDrag.payload(for: queue[3]), before: queue[1], in: queue))
        XCTAssertEqual(move.from, 3)
        XCTAssertEqual(move.to, 1)
    }

    func testADropBelowTheLastRowGoesToTheEnd() throws {
        let move = try XCTUnwrap(QueueDrag.move(payload: QueueDrag.payload(for: queue[0]), before: nil, in: queue))
        XCTAssertEqual(move.from, 0)
        XCTAssertEqual(move.to, queue.count)
    }

    func testSomethingThatIsNotAQueuedRowIsNotAMove() {
        XCTAssertNil(QueueDrag.move(payload: "track::" + queue[0].uuidString, before: queue[1], in: queue))
        XCTAssertNil(QueueDrag.move(payload: "queue::not-a-uuid", before: queue[1], in: queue))
    }

    func testARowThatLeftTheQueueIsNotAMove() {
        XCTAssertNil(QueueDrag.move(payload: QueueDrag.payload(for: UUID()), before: queue[1], in: queue))
        XCTAssertNil(QueueDrag.move(payload: QueueDrag.payload(for: queue[0]), before: UUID(), in: queue))
    }
}
#endif
