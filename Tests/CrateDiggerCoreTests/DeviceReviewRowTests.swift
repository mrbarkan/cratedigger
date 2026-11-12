#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// The text of one row of the "Already on <device>" sheet, and the sheet's
/// decidable state: which rows are answered, and whether it can be confirmed.
final class DeviceReviewRowTests: XCTestCase {
    private let copySettings = ExternalDeviceTransferSettings(mode: .copyOriginals)
    private let convertSettings = ExternalDeviceTransferSettings(mode: .convertDuringTransfer)

    // MARK: - Row text

    func testQualityUpgradeRowText() {
        let device = tracks(1...5, format: "MP3", kbps: 128, rate: 44_100, folder: "/Volumes/IPOD/Music/Miles Davis/Kind of Blue")
        let sent = tracks(1...11, format: "flac", kbps: 900, rate: 44_100, folder: "/Library/Miles Davis/Kind of Blue")
        let album = comparison(
            differences: [.audioForm, .artSize],
            sent: sent,
            changed: Array(zip(sent.prefix(5), device)),
            missing: Array(sent.dropFirst(5)),
            device: device,
            sentArt: 1400,
            deviceArt: 600
        )

        let row = DeviceReviewRow(album, settings: copySettings)

        XCTAssertEqual(row.id, album.identity)
        XCTAssertEqual(row.title, "Kind of Blue")
        XCTAssertEqual(row.artist, "Miles Davis")
        XCTAssertEqual(row.onDevice, "MP3 128k · 5 tracks · art 600 px")
        // Bit depth is not recorded for FLAC, so only the sample rate shows.
        XCTAssertEqual(row.sending, "FLAC 44.1 kHz · 11 tracks · art 1400 px")
        XCTAssertNil(row.note)
        XCTAssertFalse(row.isLeftAlone)
    }

    func testPCMShowsBitDepthAndContainer() {
        let device = tracks(1...2, format: "PCM_S16LE", kbps: 1411, rate: 44_100, folder: "/Volumes/IPOD/A")
        let sent = tracks(1...2, format: "pcm_s24be", kbps: 4608, rate: 96_000, folder: "/Library/A")
        let album = comparison(differences: [.audioForm], sent: sent, changed: Array(zip(sent, device)), device: device)

        let row = DeviceReviewRow(album, settings: copySettings)

        XCTAssertEqual(row.onDevice, "WAV 16/44.1 · 2 tracks · no art")
        XCTAssertEqual(row.sending, "AIFF 24/96 · 2 tracks · no art")
    }

    func testMixedFormatsSaySo() {
        var device = tracks(1...2, format: "MP3", kbps: 128, rate: 44_100, folder: "/Volumes/IPOD/A")
        device += tracks(3...3, format: "FLAC", kbps: nil, rate: 44_100, folder: "/Volumes/IPOD/A")
        let sent = tracks(1...3, format: "flac", kbps: nil, rate: 44_100, folder: "/Library/A")
        let album = comparison(differences: [.audioForm], sent: sent, changed: Array(zip(sent.prefix(2), device)), device: device)

        XCTAssertEqual(DeviceReviewRow(album, settings: copySettings).onDevice, "Mixed formats · 3 tracks · no art")
    }

    func testDifferentReleaseReplaceEffect() {
        let device = tracks(1...11, format: "MP3", kbps: 320, rate: 44_100, folder: "/Volumes/IPOD/A")
        let sent = tracks(1...5, format: "MP3", kbps: 320, rate: 44_100, folder: "/Library/A")
        let album = comparison(differences: [.differentRelease], sent: sent, device: device)

        XCTAssertEqual(
            DeviceReviewRow(album, settings: copySettings).replaceEffect,
            "Replaces the whole album, 11 tracks removed"
        )
    }

    func testDifferentReleaseWinsOverOtherDifferences() {
        let device = tracks(1...1, format: "MP3", kbps: 320, rate: 44_100, folder: "/Volumes/IPOD/A")
        let sent = tracks(1...1, format: "flac", kbps: nil, rate: 44_100, folder: "/Library/A")
        let album = comparison(differences: [.differentRelease, .audioForm], sent: sent, changed: Array(zip(sent, device)), device: device)

        XCTAssertEqual(
            DeviceReviewRow(album, settings: copySettings).replaceEffect,
            "Replaces the whole album, 1 track removed"
        )
    }

    func testPartialReplaceEffectCounts() {
        let device = tracks(1...11, format: "MP3", kbps: 128, rate: 44_100, folder: "/Volumes/IPOD/A")
        let sent = tracks(1...5, format: "flac", kbps: nil, rate: 44_100, folder: "/Library/A")
        let upgrade = comparison(differences: [.audioForm], sent: sent, changed: Array(zip(sent, device)), device: device)
        XCTAssertEqual(DeviceReviewRow(upgrade, settings: copySettings).replaceEffect, "Replaces 5 of 11 tracks")

        // Missing tracks are written too, into the same folder.
        let more = tracks(1...7, format: "flac", kbps: nil, rate: 44_100, folder: "/Library/A")
        let shortDevice = Array(device.prefix(5))
        let filling = comparison(
            differences: [.audioForm],
            sent: more,
            changed: Array(zip(more.prefix(5), shortDevice)),
            missing: Array(more.dropFirst(5)),
            device: shortDevice
        )
        XCTAssertEqual(DeviceReviewRow(filling, settings: copySettings).replaceEffect, "Replaces all 5 tracks, adds 2")

        let one = comparison(
            differences: [.artSize],
            sent: Array(more.prefix(1)),
            changed: [(more[0], device[0])],
            device: Array(device.prefix(3))
        )
        XCTAssertEqual(DeviceReviewRow(one, settings: copySettings).replaceEffect, "Replaces 1 of 3 tracks")
    }

    func testTwoCopiesNote() {
        let device = tracks(1...3, format: "MP3", kbps: 128, rate: 44_100, folder: "/Volumes/IPOD/A")
        let sent = tracks(1...3, format: "flac", kbps: nil, rate: 44_100, folder: "/Library/A")
        let twice = comparison(differences: [.audioForm], sent: sent, changed: Array(zip(sent, device)), device: device, copies: 2)
        XCTAssertEqual(DeviceReviewRow(twice, settings: copySettings).note, "2 copies on device")

        let once = comparison(differences: [.audioForm], sent: sent, changed: Array(zip(sent, device)), device: device, copies: 1)
        XCTAssertNil(DeviceReviewRow(once, settings: copySettings).note)
    }

    func testPathTakenNote() {
        let sent = tracks(1...4, format: "flac", kbps: nil, rate: 44_100, folder: "/Library/A")
        // A New album whose planned name is held by a file nothing matched.
        let album = comparison(differences: [.pathTaken], sent: sent, missing: sent, device: [], copies: 0, sentArt: 500)
        let row = DeviceReviewRow(album, settings: copySettings)

        XCTAssertEqual(row.note, "A different file already uses this name")
        XCTAssertEqual(row.onDevice, "None of its tracks")
        XCTAssertEqual(row.sending, "FLAC 44.1 kHz · 4 tracks · art 500 px")
        XCTAssertEqual(row.replaceEffect, "Overwrites the file already using that name")

        let both = comparison(differences: [.pathTaken, .audioForm], sent: sent, missing: sent, device: [], copies: 2)
        XCTAssertEqual(
            DeviceReviewRow(both, settings: copySettings).note,
            "2 copies on device · A different file already uses this name"
        )
    }

    func testConvertDeviceOmitsFormatWhenNotCompared() {
        let device = tracks(1...5, format: "AAC", kbps: 256, rate: 44_100, folder: "/Volumes/IPOD/A")
        let sent = tracks(1...11, format: "flac", kbps: nil, rate: 96_000, folder: "/Library/A")
        let album = comparison(
            differences: [.artSize],
            sent: sent,
            changed: Array(zip(sent.prefix(5), device)),
            missing: Array(sent.dropFirst(5)),
            device: device,
            sentArt: 1024,
            deviceArt: 300
        )

        let row = DeviceReviewRow(album, settings: convertSettings)

        XCTAssertEqual(row.onDevice, "5 tracks · art 300 px")
        XCTAssertEqual(row.sending, "11 tracks · art 1024 px")
    }

    func testLeftAloneIsCarried() {
        let device = tracks(1...2, format: "MP3", kbps: 128, rate: 44_100, folder: "/Volumes/IPOD/A")
        let sent = tracks(1...2, format: "flac", kbps: nil, rate: 44_100, folder: "/Library/A")
        let album = comparison(differences: [.audioForm], sent: sent, changed: Array(zip(sent, device)), device: device, leftAlone: true)

        XCTAssertTrue(DeviceReviewRow(album, settings: copySettings).isLeftAlone)
    }

    // MARK: - Rows and summary for a review

    func testRowsListAskedAlbumsThenLeftAloneOnRequest() {
        let device = tracks(1...2, format: "MP3", kbps: 128, rate: 44_100, folder: "/Volumes/IPOD/A")
        let sent = tracks(1...2, format: "flac", kbps: nil, rate: 44_100, folder: "/Library/A")
        let asked = comparison(album: "Asked", differences: [.audioForm], sent: sent, changed: Array(zip(sent, device)), device: device)
        let remembered = comparison(album: "Remembered", differences: [.audioForm], sent: sent, changed: Array(zip(sent, device)), device: device, leftAlone: true)
        let fresh = comparison(album: "Fresh", status: .new, differences: [], sent: sent, missing: sent, device: [], copies: 0)
        let review = DeviceTransferReview(albums: [remembered, fresh, asked])

        XCTAssertEqual(DeviceReviewRow.rows(for: review, settings: copySettings, includingLeftAlone: false).map(\.title), ["Asked"])
        XCTAssertEqual(
            DeviceReviewRow.rows(for: review, settings: copySettings, includingLeftAlone: true).map(\.title),
            ["Asked", "Remembered"]
        )
        XCTAssertEqual(DeviceReviewRow.leftAloneCount(in: review), 1)
    }

    func testSummaryLine() {
        let device = tracks(1...3, format: "MP3", kbps: 128, rate: 44_100, folder: "/Volumes/IPOD/A")
        let sent = tracks(1...3, format: "MP3", kbps: 128, rate: 44_100, folder: "/Library/A")
        let new = comparison(album: "New", status: .new, differences: [], sent: sent, missing: sent, device: [], copies: 0)
        let present = comparison(album: "Present", status: .present, differences: [], sent: sent, same: sent, device: device)
        let gaps = comparison(album: "Gaps", status: .gaps, differences: [], sent: sent, missing: Array(sent.suffix(1)), same: Array(sent.prefix(2)), device: Array(device.prefix(2)))

        XCTAssertEqual(
            DeviceReviewRow.summary(of: DeviceTransferReview(albums: [new, present, gaps])),
            "3 new · 5 already there · 1 album to finish"
        )
        XCTAssertEqual(DeviceReviewRow.summary(of: DeviceTransferReview(albums: [new])), "3 new")
        XCTAssertEqual(
            DeviceReviewRow.summary(of: DeviceTransferReview(albums: [gaps, gaps])),
            "4 already there · 2 albums to finish"
        )
        XCTAssertEqual(DeviceReviewRow.summary(of: DeviceTransferReview(albums: [])), "Nothing else to send")
    }

    // MARK: - State

    func testCanConfirmNeedsEveryRow() {
        let rows = sampleRows()
        var state = DeviceReviewState()
        XCTAssertFalse(state.canConfirm(rows: rows), "nothing is pre-selected")

        state.decisions[rows[0].id] = .replace
        XCTAssertFalse(state.canConfirm(rows: rows))

        state.decisions[rows[1].id] = .keepBoth
        XCTAssertTrue(state.canConfirm(rows: rows))

        // A row shown later (the left-alone toggle) needs an answer too.
        let more = rows + [row(album: "Third")]
        XCTAssertFalse(state.canConfirm(rows: more))
    }

    func testSetAll() {
        let rows = sampleRows()
        var state = DeviceReviewState()
        state.decisions[rows[0].id] = .leave

        state.setAll(.replace, rows: rows)
        XCTAssertEqual(state.decisions[rows[0].id], .replace)
        XCTAssertEqual(state.decisions[rows[1].id], .replace)
        XCTAssertTrue(state.canConfirm(rows: rows))

        state.setAll(.keepBoth, rows: Array(rows.prefix(1)))
        XCTAssertEqual(state.decisions[rows[0].id], .keepBoth)
        XCTAssertEqual(state.decisions[rows[1].id], .replace, "only the rows given")
    }

    func testLeftAloneRowsArePresetToLeave() {
        let remembered = row(album: "Remembered", leftAlone: true)
        let answered = row(album: "Answered", leftAlone: true)
        let asked = row(album: "Asked")
        var state = DeviceReviewState()
        state.decisions[answered.id] = .replace

        state.presetLeftAlone(rows: [asked, remembered, answered])

        XCTAssertNil(state.decisions[asked.id])
        XCTAssertEqual(state.decisions[remembered.id], .leave)
        XCTAssertEqual(state.decisions[answered.id], .replace, "an answer the user gave is kept")
    }

    func testResultHoldsOnlyVisibleRows() {
        let shown = row(album: "Shown")
        let hidden = row(album: "Hidden", leftAlone: true)
        var state = DeviceReviewState()
        state.decisions[shown.id] = .keepBoth
        state.decisions[hidden.id] = .replace   // answered, then the toggle was turned off

        XCTAssertEqual(state.result(rows: [shown]), [shown.id: .keepBoth])
    }

    // MARK: - Fixtures

    private func sampleRows() -> [DeviceReviewRow] {
        [row(album: "First"), row(album: "Second")]
    }

    private func row(album: String, leftAlone: Bool = false) -> DeviceReviewRow {
        let device = tracks(1...1, format: "MP3", kbps: 128, rate: 44_100, folder: "/Volumes/IPOD/\(album)")
        let sent = tracks(1...1, format: "flac", kbps: nil, rate: 44_100, folder: "/Library/\(album)")
        return DeviceReviewRow(
            comparison(album: album, differences: [.audioForm], sent: sent, changed: Array(zip(sent, device)), device: device, leftAlone: leftAlone),
            settings: copySettings
        )
    }

    private func tracks(
        _ numbers: ClosedRange<Int>,
        format: String,
        kbps: Int?,
        rate: Int,
        folder: String
    ) -> [LoadedTrack] {
        numbers.map { number in
            let url = URL(fileURLWithPath: folder).appendingPathComponent(String(format: "%02d Track %d.\(format.lowercased())", number, number))
            let audio = AudioTrack(
                fileURL: url,
                title: "Track \(number)",
                artist: "Miles Davis",
                album: "Kind of Blue",
                formatName: format,
                bitrateKbps: kbps,
                sampleRateHz: rate,
                trackNumber: number
            )
            let metadata = ConversionMetadata(
                title: "Track \(number)",
                artist: "Miles Davis",
                album: "Kind of Blue",
                trackNumber: number
            )
            return LoadedTrack(track: audio, metadata: metadata)
        }
    }

    private func comparison(
        album: String = "Kind of Blue",
        status: DeviceAlbumStatus = .differs,
        differences: Set<DeviceAlbumDifference>,
        sent: [LoadedTrack],
        changed: [(LoadedTrack, LoadedTrack)] = [],
        missing: [LoadedTrack] = [],
        same: [LoadedTrack] = [],
        device: [LoadedTrack],
        copies: Int = 1,
        sentArt: Int? = nil,
        deviceArt: Int? = nil,
        leftAlone: Bool = false
    ) -> DeviceAlbumComparison {
        DeviceAlbumComparison(
            identity: DeviceAlbumIdentity(artist: "Miles Davis", album: album),
            displayArtist: "Miles Davis",
            displayAlbum: album,
            status: status,
            differences: differences,
            sent: sent,
            missing: missing,
            same: same,
            changed: changed.map { (sent: $0.0, device: $0.1) },
            deviceTracks: device,
            deviceFolder: device.first?.track.fileURL.deletingLastPathComponent(),
            deviceCopyCount: copies,
            sentArtPixels: sentArt,
            deviceArtPixels: deviceArt,
            isLeftAlone: leftAlone
        )
    }
}
#endif
