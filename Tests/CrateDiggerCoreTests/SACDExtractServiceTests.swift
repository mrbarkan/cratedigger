#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

final class SACDISOInspectorTests: XCTestCase {
    /// Writes `magic` at the SACD Master TOC offset (sector 510 × 2048 bytes).
    private func makeISO(magic: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).iso")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 510 * 2048)
        try handle.write(contentsOf: Data(magic.utf8))
        try handle.close()
        return url
    }

    func testRecognizesSACDMagic() throws {
        let iso = try makeISO(magic: "SACDMTOC")
        defer { try? FileManager.default.removeItem(at: iso) }
        XCTAssertTrue(SACDISOInspector.isSACDISO(iso))
    }

    func testRejectsOrdinaryISOAndShortFile() throws {
        let plain = try makeISO(magic: "CD001___")
        defer { try? FileManager.default.removeItem(at: plain) }
        XCTAssertFalse(SACDISOInspector.isSACDISO(plain))

        let tiny = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiny-\(UUID().uuidString).iso")
        try Data("hi".utf8).write(to: tiny)
        defer { try? FileManager.default.removeItem(at: tiny) }
        XCTAssertFalse(SACDISOInspector.isSACDISO(tiny))
    }
}
#endif
