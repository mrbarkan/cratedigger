#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

final class DSFFileTests: XCTestCase {
    /// Minimal valid stereo DSD64 DSF: header + one 4096-byte block per channel.
    private func makeDSF(samplingFrequency: UInt32 = 2_822_400,
                         channels: UInt32 = 2,
                         bitsPerSample: UInt32 = 1,
                         magic: String = "DSD ") throws -> URL {
        var data = Data()
        func le32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func le64(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let blockSize: UInt32 = 4096
        let dataPayload = Int(channels) * Int(blockSize)
        let totalSize = UInt64(28 + 52 + 12 + dataPayload)

        data.append(contentsOf: magic.utf8)          // "DSD "
        le64(28); le64(totalSize); le64(0)
        data.append(contentsOf: "fmt ".utf8)
        le64(52); le32(1); le32(0)                   // version, format id (DSD raw)
        le32(2)                                       // channel type: stereo
        le32(channels)
        le32(samplingFrequency)
        le32(bitsPerSample)
        le64(UInt64(blockSize) * 8)                  // sample count (bits/channel)
        le32(blockSize); le32(0)
        data.append(contentsOf: "data".utf8)
        le64(UInt64(12 + dataPayload))
        data.append(Data(repeating: 0x69, count: dataPayload))   // DSD silence

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).dsf")
        try data.write(to: url)
        return url
    }

    func testReadsStereoDSD64Header() throws {
        let url = try makeDSF()
        defer { try? FileManager.default.removeItem(at: url) }
        let info = try DSFFile.readInfo(url: url)
        XCTAssertEqual(info.channelCount, 2)
        XCTAssertEqual(info.dsdSampleRateHz, 2_822_400)
        XCTAssertTrue(info.lsbFirst)
        XCTAssertEqual(info.blockSizeBytes, 4096)
        XCTAssertEqual(info.sampleCountPerChannel, 4096 * 8)
        XCTAssertEqual(info.dataOffset, 28 + 52 + 12)
        XCTAssertEqual(info.dopFrameRateHz, 176_400, accuracy: 0.01)
        XCTAssertEqual(info.durationSeconds, Double(4096 * 8) / 2_822_400, accuracy: 1e-9)
    }

    func testRejectsNonDSF() throws {
        let url = try makeDSF(magic: "RIFF")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try DSFFile.readInfo(url: url)) { error in
            guard case DSFReadError.notDSF = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    /// The real thing: the SACD rip extracted this session, if it still exists.
    func testReadsRealSacdExtractDSFWhenPresent() throws {
        let real = URL(fileURLWithPath: "/private/tmp/claude-501/-Users-mrbarkan-Development-Code-CrateDigger/5c7247b3-db24-40a4-b0ed-a5c3d24bbadb/scratchpad/sacd-out/Wish You Were Here/Stereo/04 - Wish You Were Here.dsf")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: real.path))
        let info = try DSFFile.readInfo(url: real)
        XCTAssertEqual(info.channelCount, 2)
        XCTAssertEqual(info.dsdSampleRateHz, 2_822_400)
        XCTAssertTrue(info.lsbFirst)
        // ffprobe reported 333.46s for this track.
        XCTAssertEqual(info.durationSeconds, 333.46, accuracy: 0.5)
    }
}
#endif
