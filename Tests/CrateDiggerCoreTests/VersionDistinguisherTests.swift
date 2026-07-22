#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

final class VersionDistinguisherTests: XCTestCase {
    private func album(title: String, year: Int?, format: String = "flac",
                       bitrate: Int? = 900, sampleRate: Int? = 44100,
                       path: String = "/tmp/x.flac") -> Album {
        let t = AudioTrack(fileURL: URL(fileURLWithPath: path), title: "Track", artist: "Radiohead",
                           album: title, formatName: format, bitrateKbps: bitrate,
                           sampleRateHz: sampleRate, year: year)
        return Album(id: title, artistID: "radiohead", artistName: "Radiohead", title: title,
                     year: year, artworkHash: nil,
                     tracks: [LoadedTrack(track: t, metadata: ConversionMetadata())])
    }

    func testCommonBaseTitleStripsCatalogSuffix() {
        XCTAssertEqual(
            VersionDistinguisher.commonBaseTitle(["OK Computer", "OK Computer (TOSHIBA-EMI TOCP-50201)"]),
            "OK Computer"
        )
    }

    func testCommonBaseTitleIsCaseInsensitive() {
        // "Riot on…" vs "Riot On…" is one title with inconsistent casing — the
        // base is the whole title, not the prefix up to the first case mismatch.
        XCTAssertEqual(
            VersionDistinguisher.commonBaseTitle(["Riot on an Empty Street", "Riot On An Empty Street"]),
            "Riot on an Empty Street"
        )
    }

    func testLabelsFallBackToFormatWhenTitlesDifferOnlyByCase() {
        let aac = album(title: "Riot on an Empty Street", year: 2004, format: "aac",
                        bitrate: 262, path: "/tmp/a/x.m4a")
        let flac = album(title: "Riot On An Empty Street", year: 2004, format: "flac",
                         path: "/tmp/b/x.flac")
        let labels = VersionDistinguisher.labels(for: [aac, flac])
        // A case-only difference is no distinguisher — fall through to format.
        XCTAssertEqual(labels, [VersionLabel.formatBadge(for: aac), VersionLabel.formatBadge(for: flac)])
    }

    func testCommonBaseTitleFallsBackToShortestWhenNoSharedPrefix() {
        // No meaningful common prefix → shortest title.
        XCTAssertEqual(VersionDistinguisher.commonBaseTitle(["Kid A", "Amnesiac"]), "Kid A")
    }

    func testLabelsExtractsCatalogFromAlbumTitle() {
        let standard = album(title: "OK Computer", year: 1997)
        let japan = album(title: "OK Computer (TOSHIBA-EMI TOCP-50201)", year: 1997)
        let labels = VersionDistinguisher.labels(for: [standard, japan])
        XCTAssertEqual(labels[1], "TOSHIBA-EMI TOCP-50201")
    }

    func testLabelsFallBackToYearWhenTitlesIdentical() {
        let original = album(title: "OK Computer", year: 1997)
        let remaster = album(title: "OK Computer", year: 2017)
        XCTAssertEqual(VersionDistinguisher.labels(for: [original, remaster]), ["1997", "2017"])
    }

    func testLabelsFallBackToFormatWhenTitleAndYearIdentical() {
        let flac = album(title: "Discovery", year: 2001, format: "flac", sampleRate: 44100)
        let mp3 = album(title: "Discovery", year: 2001, format: "mp3", bitrate: 320, sampleRate: 44100)
        let labels = VersionDistinguisher.labels(for: [flac, mp3])
        XCTAssertEqual(labels, ["FLAC · 44 kHz", "MP3 · 320"])
    }

    func testLabelsFallBackToFolderWhenEverythingElseMatches() {
        let a = album(title: "Discovery", year: 2001, path: "/Music/Discovery US/01.flac")
        let b = album(title: "Discovery", year: 2001, path: "/Music/Discovery JP/01.flac")
        let labels = VersionDistinguisher.labels(for: [a, b])
        XCTAssertEqual(labels, ["Discovery US", "Discovery JP"])
    }
}
#endif
