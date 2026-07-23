#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

final class DoPPlaybackEngineTests: XCTestCase {
    /// Stereo DSD64 DSF, 2 blocks per channel: ch0 = 0xFF (full scale),
    /// ch1 = 0x69 (DSD silence).
    private func makeDSF() throws -> URL {
        var data = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func le64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let block = 4096
        data.append(contentsOf: "DSD ".utf8); le64(28); le64(UInt64(92 + 4 * block)); le64(0)
        data.append(contentsOf: "fmt ".utf8); le64(52); le32(1); le32(0); le32(2); le32(2)
        le32(2_822_400); le32(1); le64(UInt64(2 * block * 8)); le32(UInt32(block)); le32(0)
        data.append(contentsOf: "data".utf8); le64(UInt64(12 + 4 * block))
        data.append(Data(repeating: 0xFF, count: block))   // ch0 block 0
        data.append(Data(repeating: 0x69, count: block))   // ch1 block 0
        data.append(Data(repeating: 0xFF, count: block))   // ch0 block 1
        data.append(Data(repeating: 0x69, count: block))   // ch1 block 1
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dop-\(UUID().uuidString).dsf")
        try data.write(to: url)
        return url
    }

    private func loadedEngine() throws -> (DoPPlaybackEngine, URL) {
        let url = try makeDSF()
        let engine = DoPPlaybackEngine()
        let ready = expectation(description: "ready")
        engine.onItemReady = { ready.fulfill() }
        engine.replaceCurrentItem(url: url)
        wait(for: [ready], timeout: 5)
        return (engine, url)
    }

    func testLoadReportsDurationAndReady() throws {
        let (engine, url) = try loadedEngine()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(engine.durationSeconds, Double(2 * 4096 * 8) / 2_822_400, accuracy: 1e-6)
        XCTAssertEqual(engine.currentTimeSeconds, 0)
    }

    func testSeekClampsAndMoves() throws {
        let (engine, url) = try loadedEngine()
        defer { try? FileManager.default.removeItem(at: url) }
        engine.seek(toSeconds: engine.durationSeconds / 2)
        XCTAssertEqual(engine.currentTimeSeconds, engine.durationSeconds / 2, accuracy: 0.001)
        engine.seek(toSeconds: 999)
        XCTAssertEqual(engine.currentTimeSeconds, engine.durationSeconds, accuracy: 0.001)
        engine.seek(toSeconds: -5)
        XCTAssertEqual(engine.currentTimeSeconds, 0)
    }

    func testLevelsReflectChannelContent() throws {
        let (engine, url) = try loadedEngine()
        defer { try? FileManager.default.removeItem(at: url) }
        let levels = engine.currentLevels
        // ch0 all-ones = full scale; ch1 0x69 = DSD silence.
        XCTAssertGreaterThan(levels.left, 0.5)
        XCTAssertEqual(levels.right, 0, accuracy: 0.01)
    }

    func testFailedLoadFiresOnItemFailed() {
        let engine = DoPPlaybackEngine()
        let failed = expectation(description: "failed")
        engine.onItemFailed = { _ in failed.fulfill() }
        engine.replaceCurrentItem(url: URL(fileURLWithPath: "/no/such/file.dsf"))
        wait(for: [failed], timeout: 5)
    }
}
#endif
