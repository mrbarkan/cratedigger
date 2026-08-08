#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

final class TrackColumnTests: XCTestCase {
    private func track(title: String = "Song", trackNumber: Int? = 3,
                       duration: Double = 215, year: Int? = 1998,
                       bitrate: Int? = 298, sampleRate: Int? = 44100,
                       albumArtist: String? = "Air", genre: String? = "Electronic") -> LoadedTrack {
        var audio = AudioTrack(fileURL: URL(fileURLWithPath: "/tmp/\(title).m4a"),
                               title: title, artist: "Air", album: "Moon Safari",
                               durationSeconds: duration)
        audio.trackNumber = trackNumber
        audio.year = year
        audio.bitrateKbps = bitrate
        audio.sampleRateHz = sampleRate
        audio.formatName = "alac"
        var metadata = ConversionMetadata()
        metadata.albumArtist = albumArtist
        metadata.genre = genre
        return LoadedTrack(track: audio, metadata: metadata)
    }

    func testCellValues() {
        let t = track()
        XCTAssertEqual(TrackColumn.trackNumber.value(for: t), "3")
        XCTAssertEqual(TrackColumn.title.value(for: t), "Song")
        XCTAssertEqual(TrackColumn.duration.value(for: t), "3:35")
        XCTAssertEqual(TrackColumn.albumArtist.value(for: t), "Air")
        XCTAssertEqual(TrackColumn.genre.value(for: t), "Electronic")
        XCTAssertEqual(TrackColumn.year.value(for: t), "1998")
        XCTAssertEqual(TrackColumn.format.value(for: t), "ALAC")
        XCTAssertEqual(TrackColumn.bitrate.value(for: t), "298 kbps")
        XCTAssertEqual(TrackColumn.sampleRate.value(for: t), "44.1 kHz")
    }

    /// A missing tag reads as a blank cell, not a placeholder — a table of "—"
    /// is harder to scan than a table with holes in it.
    func testMissingTagsRenderEmpty() {
        let t = track(trackNumber: nil, year: nil, bitrate: nil, sampleRate: nil,
                      albumArtist: nil, genre: nil)
        for column in [TrackColumn.trackNumber, .year, .bitrate, .sampleRate, .albumArtist, .genre] {
            XCTAssertEqual(column.value(for: t), "", "\(column) should be blank when unset")
        }
    }

    /// A vinyl-side rip runs past the hour; m:ss would show "83:20".
    func testDurationGrowsAnHoursFieldWhenItNeedsOne() {
        XCTAssertEqual(TrackColumn.durationText(215), "3:35")
        XCTAssertEqual(TrackColumn.durationText(59), "0:59")
        XCTAssertEqual(TrackColumn.durationText(5000), "1:23:20")
        XCTAssertEqual(TrackColumn.durationText(0), "")
        XCTAssertEqual(TrackColumn.durationText(.nan), "")
    }

    func testSavedSelectionRoundTrips() {
        let saved = [TrackColumn.title, .artist, .album].map(\.rawValue)
        XCTAssertEqual(TrackColumn.selection(fromSaved: saved), [.title, .artist, .album])
    }

    /// A preference written by a later version, or edited by hand, must not be
    /// able to produce a table with no columns in it.
    func testSelectionSurvivesAStalePreference() {
        XCTAssertEqual(TrackColumn.selection(fromSaved: []), TrackColumn.defaultSelection)
        XCTAssertEqual(TrackColumn.selection(fromSaved: ["nonsense", "gone"]), TrackColumn.defaultSelection)
        // Title is required: reinstated rather than silently missing.
        XCTAssertEqual(TrackColumn.selection(fromSaved: ["artist"]), [.title, .artist])
        // Duplicates collapse.
        XCTAssertEqual(TrackColumn.selection(fromSaved: ["title", "title", "artist"]), [.title, .artist])
    }

    /// Only the four the browser can actually order by claim a sort field.
    func testOnlySortableColumnsAdvertiseASortField() {
        XCTAssertEqual(TrackColumn.title.sortField, .title)
        XCTAssertEqual(TrackColumn.duration.sortField, .duration)
        XCTAssertNil(TrackColumn.genre.sortField)
        XCTAssertNil(TrackColumn.format.sortField)
    }
}
#endif
