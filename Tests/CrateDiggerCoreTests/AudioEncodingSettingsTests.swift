#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

final class AudioEncodingSettingsTests: XCTestCase {
    // MARK: - Normalization

    func testLosslessFormatsDropTheBitrate() {
        for format in [OutputFormat.alac, .flac, .wav, .aiff] {
            let settings = AudioEncodingSettings(format: format, bitrateKbps: 320).normalized()
            XCTAssertNil(settings.bitrateKbps, "\(format) has no bitrate to choose")
            XCTAssertFalse(format.usesBitrate)
        }
    }

    func testLossyFormatsAlwaysCarryABitrate() {
        XCTAssertEqual(AudioEncodingSettings(format: .aac).normalized().bitrateKbps, OutputFormat.defaultBitrateKbps)
        XCTAssertEqual(AudioEncodingSettings(format: .mp3, bitrateKbps: 999).normalized().bitrateKbps, OutputFormat.defaultBitrateKbps)
        XCTAssertEqual(AudioEncodingSettings(format: .mp3, bitrateKbps: 320).normalized().bitrateKbps, 320)
    }

    func testLossyFormatsHaveNoBitDepthOrCompressionLevel() {
        let settings = AudioEncodingSettings(format: .aac, bitrateKbps: 256, bitDepth: 24, flacCompressionLevel: 8).normalized()
        XCTAssertNil(settings.bitDepth)
        XCTAssertNil(settings.flacCompressionLevel)
    }

    /// libopus refuses 44.1 kHz and ffmpeg fails the job, so Opus must never
    /// carry the rate the Patch Bay used to default to.
    func testOpusNeverCarriesAnExplicitSampleRate() {
        let settings = AudioEncodingSettings(format: .opus, bitrateKbps: 160, sampleRateHz: 44_100).normalized()
        XCTAssertNil(settings.sampleRateHz)
        XCTAssertEqual(OutputFormat.opus.sampleRateOptions, [nil])
    }

    func testLossyFormatsDropHiResRates() {
        XCTAssertNil(AudioEncodingSettings(format: .mp3, sampleRateHz: 96_000).normalized().sampleRateHz)
        XCTAssertEqual(AudioEncodingSettings(format: .flac, sampleRateHz: 96_000).normalized().sampleRateHz, 96_000)
    }

    func testFLACAndALACCanFollowTheSourceResolution() {
        let flac = AudioEncodingSettings(format: .flac).normalized()
        XCTAssertNil(flac.sampleRateHz)
        XCTAssertNil(flac.bitDepth)
        XCTAssertNil(AudioEncodingSettings(format: .alac).normalized().bitDepth)
    }

    /// WAV and AIFF are fixed PCM codecs, so they need a depth named; 16 is
    /// what they wrote before the choice existed.
    func testPCMFormatsDefaultTo16Bit() {
        XCTAssertEqual(AudioEncodingSettings(format: .wav).normalized().bitDepth, 16)
        XCTAssertEqual(AudioEncodingSettings(format: .aiff, bitDepth: 24).normalized().bitDepth, 24)
        XCTAssertFalse(OutputFormat.wav.bitDepthOptions.contains(nil))
    }

    func testCompressionLevelIsFLACOnly() {
        XCTAssertEqual(AudioEncodingSettings(format: .flac).normalized().flacCompressionLevel, OutputFormat.defaultFLACCompressionLevel)
        XCTAssertEqual(AudioEncodingSettings(format: .flac, flacCompressionLevel: 8).normalized().flacCompressionLevel, 8)
        XCTAssertNil(AudioEncodingSettings(format: .alac, flacCompressionLevel: 8).normalized().flacCompressionLevel)
    }

    // MARK: - Summary

    func testSummaryNamesWhatTheFormatHonours() {
        XCTAssertEqual(AudioEncodingSettings(format: .flac, sampleRateHz: 44_100, bitDepth: 16).summary, "FLAC · 16-bit · 44.1 kHz")
        XCTAssertEqual(AudioEncodingSettings(format: .alac).summary, "ALAC · Source resolution")
        XCTAssertEqual(AudioEncodingSettings(format: .flac, bitDepth: 24).summary, "FLAC · 24-bit · Source rate")
        XCTAssertEqual(AudioEncodingSettings(format: .aac, bitrateKbps: 256, sampleRateHz: 44_100).summary, "AAC · 256 kbps · 44.1 kHz")
        XCTAssertEqual(AudioEncodingSettings(format: .opus, bitrateKbps: 160).summary, "Opus · 160 kbps · 48 kHz")
        XCTAssertEqual(AudioEncodingSettings(format: .mp3, bitrateKbps: 320).summary, "MP3 · 320 kbps")
    }

    // MARK: - Size estimate

    func testLossyEstimateIsTheBitrate() {
        XCTAssertEqual(AudioEncodingSettings(format: .mp3, bitrateKbps: 320).estimatedKbps(sourceSampleRateHz: 96_000), 320)
    }

    func testLosslessEstimateFollowsTheSourceWhenKept() {
        let flac = AudioEncodingSettings(format: .flac)
        // 44.1 kHz × 16-bit × 2 ch = 1411.2 kbps, at ~60%.
        XCTAssertEqual(flac.estimatedKbps(sourceSampleRateHz: 44_100), 1411.2 * 0.6, accuracy: 0.01)
        // A 96 kHz source is taken as 24-bit.
        XCTAssertEqual(flac.estimatedKbps(sourceSampleRateHz: 96_000), 4608 * 0.6, accuracy: 0.01)
        let wav = AudioEncodingSettings(format: .wav, sampleRateHz: 48_000, bitDepth: 24)
        XCTAssertEqual(wav.estimatedKbps(sourceSampleRateHz: 44_100), 2304, accuracy: 0.01)
    }
}
#endif
