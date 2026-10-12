#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

final class PhysicalMediumTests: XCTestCase {
    private let blank = AudioEncodingSettings(format: .aac, bitrateKbps: 192, sampleRateHz: 44_100)

    /// Every key, pressed on every medium, must light itself: otherwise the
    /// bank would go dark the moment it was pressed.
    func testEveryTierReadsBackAsItselfOnEveryMedium() {
        for medium in PhysicalMedium.allCases {
            for tier in RipTier.allCases {
                let settings = tier.settings(for: medium, keeping: blank)
                XCTAssertEqual(RipTier.matching(settings, medium: medium), tier, "\(medium) \(tier)")
            }
        }
    }

    func testCDTiers() {
        XCTAssertEqual(RipTier.exact.settings(for: .cd, keeping: blank),
                       AudioEncodingSettings(format: .wav, sampleRateHz: 44_100, bitDepth: 16))
        XCTAssertEqual(RipTier.lossless.settings(for: .cd, keeping: blank),
                       AudioEncodingSettings(format: .flac, sampleRateHz: 44_100, bitDepth: 16, flacCompressionLevel: 8))
        XCTAssertEqual(RipTier.lossy.settings(for: .cd, keeping: blank),
                       AudioEncodingSettings(format: .aac, bitrateKbps: 192, sampleRateHz: 44_100))
    }

    func testSACDRendersDSDAs24Bit88k() {
        let lossless = RipTier.lossless.settings(for: .sacd, keeping: blank)
        XCTAssertEqual(lossless.bitDepth, 24)
        XCTAssertEqual(lossless.sampleRateHz, 88_200)
    }

    func testHiResDiscsKeepTheSourceRateAndEncodeLossyAt48k() {
        for medium in [PhysicalMedium.bluRay, .bluRayAudio, .dvdAudio] {
            XCTAssertNil(RipTier.lossless.settings(for: medium, keeping: blank).sampleRateHz, "\(medium)")
            XCTAssertEqual(RipTier.lossy.settings(for: medium, keeping: blank).sampleRateHz, 48_000, "\(medium)")
        }
    }

    /// A 1:1 WAV can't follow the source's depth, so it must never fall back
    /// to WAV's 16-bit default and truncate a 24-bit capture.
    func testExactNeverTruncatesAnAnalogCapture() {
        XCTAssertEqual(RipTier.exact.settings(for: .vinyl, keeping: blank).bitDepth, 24)
        XCTAssertEqual(RipTier.exact.settings(for: .anySource, keeping: blank).bitDepth, 24)
    }

    func testAnySourceLosslessKeepsEachFilesResolution() {
        let settings = RipTier.lossless.settings(for: .anySource, keeping: blank)
        XCTAssertNil(settings.bitDepth)
        XCTAssertNil(settings.sampleRateHz)
    }

    func testTiersKeepTheFlavourAlreadyChosen() {
        let alac = AudioEncodingSettings(format: .alac)
        XCTAssertEqual(RipTier.lossless.settings(for: .cd, keeping: alac).format, .alac)
        let mp3 = AudioEncodingSettings(format: .mp3, bitrateKbps: 320)
        let lossy = RipTier.lossy.settings(for: .vinyl, keeping: mp3)
        XCTAssertEqual(lossy.format, .mp3)
        XCTAssertEqual(lossy.bitrateKbps, 320)
        let aiff = AudioEncodingSettings(format: .aiff)
        XCTAssertEqual(RipTier.exact.settings(for: .cd, keeping: aiff).format, .aiff)
        let flac5 = AudioEncodingSettings(format: .flac, flacCompressionLevel: 5)
        XCTAssertEqual(RipTier.lossless.settings(for: .cd, keeping: flac5).flacCompressionLevel, 5)
    }

    func testOpusLossyStaysOpusAt48k() {
        let opus = AudioEncodingSettings(format: .opus, bitrateKbps: 160)
        let lossy = RipTier.lossy.settings(for: .cd, keeping: opus)
        XCTAssertEqual(lossy.format, .opus)
        XCTAssertNil(lossy.sampleRateHz)
        XCTAssertEqual(RipTier.matching(lossy, medium: .cd), .lossy)
    }

    func testEditedResolutionReadsAsNoTier() {
        let flac48 = AudioEncodingSettings(format: .flac, sampleRateHz: 48_000, bitDepth: 16, flacCompressionLevel: 8)
        XCTAssertNil(RipTier.matching(flac48, medium: .cd))
    }

    func testGroupedCoversEveryMediumOnce() {
        let all = PhysicalMedium.grouped.flatMap(\.media)
        XCTAssertEqual(all.count, PhysicalMedium.allCases.count)
        XCTAssertEqual(Set(all).count, all.count)
    }
}
#endif
