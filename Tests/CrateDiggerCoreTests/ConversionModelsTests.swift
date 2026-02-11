#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

final class ConversionModelsTests: XCTestCase {
    func testALACUsesM4AExtension() {
        XCTAssertEqual(OutputFormat.alac.fileExtension, "m4a")

        let preset = ConversionPreset(
            id: "alac_test",
            name: "ALAC Test",
            outputFormat: .alac,
            bitrateKbps: nil,
            sampleRateHz: 44_100,
            channels: 2,
            constantBitrate: false,
            deviceProfile: .generic,
            tagMode: .mp4Atoms,
            artworkMode: .compatReembed
        )
        XCTAssertEqual(preset.outputExtension, "m4a")
    }

    func testAACStillUsesM4AExtension() {
        XCTAssertEqual(OutputFormat.aac.fileExtension, "m4a")
    }

    func testMP3ExtensionUnchanged() {
        XCTAssertEqual(OutputFormat.mp3.fileExtension, "mp3")
    }
}
#endif
