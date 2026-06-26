#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

final class VersionLabelTests: XCTestCase {
    private func album(format: String?, bitrate: Int?, sampleRate: Int?,
                       media: MediaFormat? = nil) -> Album {
        let t = AudioTrack(fileURL: URL(fileURLWithPath: "/tmp/x.\(format ?? "bin")"),
                           title: "S", artist: "A", album: "R",
                           formatName: format, bitrateKbps: bitrate, sampleRateHz: sampleRate)
        return Album(id: "a", artistID: "a", artistName: "A", title: "R", year: 2001,
                     artworkHash: nil, tracks: [LoadedTrack(track: t, metadata: ConversionMetadata())],
                     mediaFormat: media)
    }

    func testLosslessShowsSampleRate() {
        XCTAssertEqual(VersionLabel.formatBadge(for: album(format: "flac", bitrate: 900, sampleRate: 96000)),
                       "FLAC · 96 kHz")
    }

    func testLosslessNoSampleRate() {
        XCTAssertEqual(VersionLabel.formatBadge(for: album(format: "alac", bitrate: nil, sampleRate: nil)),
                       "ALAC")
    }

    func testLossyShowsBitrate() {
        XCTAssertEqual(VersionLabel.formatBadge(for: album(format: "mp3", bitrate: 320, sampleRate: 44100)),
                       "MP3 · 320")
    }

    func testMediaFormatSuffix() {
        XCTAssertEqual(VersionLabel.formatBadge(for: album(format: "flac", bitrate: nil, sampleRate: 44100, media: .vinyl)),
                       "FLAC · 44 kHz · Vinyl")
    }

    func testUnknownFormat() {
        XCTAssertEqual(VersionLabel.formatBadge(for: album(format: nil, bitrate: nil, sampleRate: nil)),
                       "—")
    }
}
#endif
