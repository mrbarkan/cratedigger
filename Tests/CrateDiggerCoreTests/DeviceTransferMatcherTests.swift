#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class DeviceTransferMatcherTests: XCTestCase {
    private let matcher = DeviceTransferMatcher()
    private let copySettings = ExternalDeviceTransferSettings(mode: .copyOriginals)
    private let convertSettings = ExternalDeviceTransferSettings(
        mode: .convertDuringTransfer, outputFormat: .mp3, bitrateKbps: 192, artworkMaxDimension: 1024
    )

    // MARK: - Status

    func testEmptyDeviceIsNew() {
        let sending = album("/Src/Kind of Blue", numbers: [1, 2])
        let other = album("/Device/Music/Bitches Brew", album: "Bitches Brew", numbers: [1])

        let result = compare(sending, other)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].status, .new)
        XCTAssertEqual(result[0].missing.map(\.track.title), ["Track 1", "Track 2"])
        XCTAssertTrue(result[0].same.isEmpty)
        XCTAssertTrue(result[0].changed.isEmpty)
        XCTAssertEqual(result[0].deviceCopyCount, 0)
        XCTAssertNil(result[0].deviceFolder)
        XCTAssertTrue(result[0].differences.isEmpty)
    }

    func testAllSameIsPresent() {
        let sending = album("/Src/Kind of Blue", numbers: [1, 2, 3])
        let device = album("/Device/Music/Miles Davis/Kind of Blue", numbers: [1, 2, 3])

        let result = compare(sending, device)

        XCTAssertEqual(result.map(\.status), [.present])
        XCTAssertEqual(result[0].same.count, 3)
        XCTAssertTrue(result[0].missing.isEmpty)
        XCTAssertEqual(result[0].deviceCopyCount, 1)
        XCTAssertEqual(result[0].deviceFolder?.path, "/Device/Music/Miles Davis/Kind of Blue")
        XCTAssertEqual(result[0].deviceTracks.count, 3)
    }

    func testSubsetOfFullDeviceAlbumIsPresent() {
        let sending = album("/Src/Kind of Blue", numbers: [2, 4])
        let device = album("/Device/Music/Kind of Blue", numbers: [1, 2, 3, 4, 5])

        XCTAssertEqual(compare(sending, device).map(\.status), [.present])
    }

    func testPartialDeviceAlbumIsGaps() {
        let sending = album("/Src/Kind of Blue", numbers: [1, 2, 3, 4])
        let device = album("/Device/Music/Kind of Blue", numbers: [1, 2])

        let result = compare(sending, device)

        XCTAssertEqual(result.map(\.status), [.gaps])
        XCTAssertEqual(result[0].missing.map(\.track.title), ["Track 3", "Track 4"])
        XCTAssertEqual(result[0].same.map(\.track.title), ["Track 1", "Track 2"])
        XCTAssertEqual(result[0].deviceFolder?.path, "/Device/Music/Kind of Blue")
        XCTAssertTrue(result[0].differences.isEmpty)
    }

    func testDisjointTracksOfSameAlbumAreGaps() {
        let sending = album("/Src/Kind of Blue", numbers: [2, 4])
        let device = album("/Device/Music/Kind of Blue", numbers: [1, 3])

        let result = compare(sending, device)

        XCTAssertEqual(result.map(\.status), [.gaps])
        XCTAssertEqual(result[0].missing.count, 2)
        XCTAssertEqual(result[0].deviceFolder?.path, "/Device/Music/Kind of Blue")
    }

    // MARK: - Audio form

    func testBetterFormatDiffersOnCopyDevice() {
        let sending = album("/Src/Kind of Blue", numbers: [1, 2], format: "FLAC", bitrate: 900)
        let device = album("/Device/Music/Kind of Blue", numbers: [1, 2], format: "MP3", bitrate: 128, ext: "mp3")

        let result = compare(sending, device)

        XCTAssertEqual(result.map(\.status), [.differs])
        XCTAssertEqual(result[0].differences, [.audioForm])
        XCTAssertEqual(result[0].changed.count, 2)
        XCTAssertEqual(result[0].changed.first?.device.track.formatName, "MP3")
        XCTAssertTrue(result[0].same.isEmpty)
    }

    func testLosslessBitrateIsIgnoredOnCopyDevice() {
        let sending = album("/Src/Kind of Blue", numbers: [1], format: "FLAC", bitrate: 912)
        let device = album("/Device/Music/Kind of Blue", numbers: [1], format: "flac", bitrate: 887)

        XCTAssertEqual(compare(sending, device).map(\.status), [.present])
    }

    func testFormatIgnoredOnConvertDevice() {
        let sending = album("/Src/Kind of Blue", numbers: [1, 2], format: "FLAC", bitrate: 900)
        let device = album("/Device/Music/Kind of Blue", numbers: [1, 2], format: "MP3", bitrate: 128, ext: "mp3")

        let result = compare(sending, device, settings: convertSettings)

        XCTAssertEqual(result.map(\.status), [.present])
    }

    // MARK: - Art

    func testArtSizeDiffers() {
        let sending = album("/Src/Kind of Blue", numbers: [1, 2], art: 1400)
        let device = album("/Device/Music/Kind of Blue", numbers: [1, 2], art: 600)

        let result = compare(sending, device)

        XCTAssertEqual(result.map(\.status), [.differs])
        XCTAssertEqual(result[0].differences, [.artSize])
        XCTAssertEqual(result[0].sentArtPixels, 1400)
        XCTAssertEqual(result[0].deviceArtPixels, 600)
        XCTAssertEqual(result[0].changed.count, 2)
    }

    func testDeviceWithoutArtDiffersWhenArtWouldBeSent() {
        let sending = album("/Src/Kind of Blue", numbers: [1], art: 1400)
        let device = album("/Device/Music/Kind of Blue", numbers: [1], art: nil)

        let result = compare(sending, device)

        XCTAssertEqual(result.map(\.status), [.differs])
        XCTAssertEqual(result[0].differences, [.artSize])
    }

    func testNoArtOnEitherSideIsSame() {
        let sending = album("/Src/Kind of Blue", numbers: [1], art: nil)
        let device = album("/Device/Music/Kind of Blue", numbers: [1], art: 600)

        // Nothing would be sent, so the device's art is not a difference.
        XCTAssertEqual(compare(sending, device).map(\.status), [.present])
    }

    func testConvertModeComparesArtAfterTheCap() {
        let sending = album("/Src/Kind of Blue", numbers: [1], art: 1400)
        let capped = album("/Device/Music/Kind of Blue", numbers: [1], art: 1024)
        let smaller = album("/Device/Music/Kind of Blue", numbers: [1], art: 600)

        let same = compare(sending, capped, settings: convertSettings)
        XCTAssertEqual(same.map(\.status), [.present])
        XCTAssertEqual(same[0].sentArtPixels, 1024)

        var uncapped = convertSettings
        uncapped.artworkMaxDimension = nil
        let differs = compare(sending, smaller, settings: uncapped)
        XCTAssertEqual(differs.map(\.status), [.differs])
        XCTAssertEqual(differs[0].sentArtPixels, 1400)
    }

    func testCopyModeIgnoresSentFolderImageArt() {
        // The library resolved a cover.jpg; copying the audio file does not carry it.
        let sending = album("/Src/Kind of Blue", numbers: [1, 2], art: 1400, artSource: .folderImage)
        let device = album("/Device/Music/Kind of Blue", numbers: [1, 2], art: nil)

        let result = compare(sending, device)

        XCTAssertEqual(result.map(\.status), [.present])
        XCTAssertNil(result[0].sentArtPixels)
    }

    func testDeviceRemoteArtIsIgnored() {
        // Remote art cached by the device scan is not on the device.
        let sending = album("/Src/Kind of Blue", numbers: [1], art: 600)
        let device = album("/Device/Music/Kind of Blue", numbers: [1], art: 600, artSource: .remote)

        let result = compare(sending, device)

        XCTAssertEqual(result.map(\.status), [.differs])
        XCTAssertEqual(result[0].differences, [.artSize])
        XCTAssertNil(result[0].deviceArtPixels)
    }

    func testDeviceFolderImageArtCounts() {
        let sending = album("/Src/Kind of Blue", numbers: [1], art: 600)
        let device = album("/Device/Music/Kind of Blue", numbers: [1], art: 600, artSource: .folderImage)

        XCTAssertEqual(compare(sending, device).map(\.status), [.present])
    }

    func testConvertModeWithCapReembedsResolvedArtFromAnySource() {
        let sending = album("/Src/Kind of Blue", numbers: [1], art: 1400, artSource: .folderImage)
        let device = album("/Device/Music/Kind of Blue", numbers: [1], art: 1024)

        let result = compare(sending, device, settings: convertSettings)

        XCTAssertEqual(result.map(\.status), [.present])
        XCTAssertEqual(result[0].sentArtPixels, 1024)
    }

    func testConvertModeWithoutCapKeepsOnlyEmbeddedArt() {
        var keep = convertSettings
        keep.artworkMaxDimension = nil
        let sending = album("/Src/Kind of Blue", numbers: [1], art: 1400, artSource: .folderImage)
        let device = album("/Device/Music/Kind of Blue", numbers: [1], art: nil)

        let result = compare(sending, device, settings: keep)

        XCTAssertEqual(result.map(\.status), [.present])
        XCTAssertNil(result[0].sentArtPixels)
    }

    func testConvertModeCapBelowFloorClampsTo120() {
        var tiny = convertSettings
        tiny.artworkMaxDimension = 50
        let sending = album("/Src/Kind of Blue", numbers: [1], art: 1400)
        let device = album("/Device/Music/Kind of Blue", numbers: [1], art: 120)

        let result = compare(sending, device, settings: tiny)

        XCTAssertEqual(result.map(\.status), [.present])
        XCTAssertEqual(result[0].sentArtPixels, 120)
    }

    func testSameArtSizeDifferentHashIsSame() {
        var sending = album("/Src/Kind of Blue", numbers: [1, 2], art: 600)
        sending = sending.map { withArtHash($0, "source-hash") }
        var device = album("/Device/Music/Kind of Blue", numbers: [1, 2], art: 600)
        device = device.map { withArtHash($0, "device-hash") }

        XCTAssertEqual(compare(sending, device).map(\.status), [.present])
    }

    // MARK: - Different release

    func testDifferentTitleAtSameSlotIsDifferentRelease() {
        let sending = album("/Src/Kind of Blue", numbers: [1, 2])
        let device = [
            track(album: "Kind of Blue", number: 1, title: "Track 1", path: "/Device/Music/Kind of Blue/01.flac"),
            track(album: "Kind of Blue", number: 2, title: "Something Else", path: "/Device/Music/Kind of Blue/02.flac"),
        ]

        let result = compare(sending, device)

        XCTAssertEqual(result.map(\.status), [.differs])
        XCTAssertEqual(result[0].differences, [.differentRelease])
    }

    func testDifferentTrackTotalIsDifferentRelease() {
        let sending = album("/Src/Kind of Blue", numbers: [1, 2], trackTotal: 5)
        let device = album("/Device/Music/Kind of Blue", numbers: [1, 2], trackTotal: 11)

        let result = compare(sending, device)

        XCTAssertEqual(result.map(\.status), [.differs])
        XCTAssertEqual(result[0].differences, [.differentRelease])
    }

    func testDifferentTrackTotalOnDisjointTracksIsDifferentRelease() {
        let sending = album("/Src/Kind of Blue", numbers: [2, 4], trackTotal: 5)
        let device = album("/Device/Music/Kind of Blue", numbers: [1, 3], trackTotal: 11)

        XCTAssertEqual(compare(sending, device).map(\.status), [.differs])
    }

    func testTrackTotalOnOneSideOnlyIsNotADifference() {
        let sending = album("/Src/Kind of Blue", numbers: [1, 2], trackTotal: 5)
        let device = album("/Device/Music/Kind of Blue", numbers: [1, 2], trackTotal: nil)

        XCTAssertEqual(compare(sending, device).map(\.status), [.present])
    }

    // MARK: - Identity

    func testYearDoesNotSplitIdentity() {
        let sending = album("/Src/Kind of Blue", numbers: [1, 2], year: 1997)
        let device = album("/Device/Music/Kind of Blue", numbers: [1, 2], year: 1959)

        XCTAssertEqual(compare(sending, device).map(\.status), [.present])
    }

    func testIdentityFoldsCaseDiacriticsAndDiscSuffix() {
        let sending = [track(album: "Café Society (Disc 1)", artist: "Beyoncé", number: 1, title: "Track 1",
                             path: "/Src/Cafe/01.flac")]
        let device = [track(album: "CAFE SOCIETY", artist: "beyonce", number: 1, title: "track 1",
                            path: "/Device/Music/Cafe/01.flac")]

        let ids = DeviceAlbumIdentity.identities(for: sending + device)
        XCTAssertEqual(ids[sending[0].track.id], ids[device[0].track.id])
        XCTAssertEqual(compare(sending, device).map(\.status), [.present])
    }

    func testCompilationWithoutAlbumArtistIsOneAlbum() {
        let artists = ["Nina Simone", "Chet Baker", "Bill Evans"]
        let sending = artists.enumerated().map { index, artist in
            track(album: "Late Night Jazz", artist: artist, number: index + 1, title: "Song \(index + 1)",
                  path: "/Src/Late Night Jazz/0\(index + 1).flac")
        }
        let device = artists.enumerated().map { index, artist in
            track(album: "Late Night Jazz", artist: artist, number: index + 1, title: "Song \(index + 1)",
                  path: "/Device/Music/Various Artists/Late Night Jazz/0\(index + 1).flac")
        }

        let result = compare(sending, device)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].status, .present)
        XCTAssertEqual(result[0].same.count, 3)
        XCTAssertEqual(result[0].displayArtist, "Various Artists")
        XCTAssertEqual(result[0].displayAlbum, "Late Night Jazz")
    }

    // MARK: - Several copies

    func testTwoCopiesOneSameIsPresent() {
        let sending = album("/Src/Kind of Blue", numbers: [1, 2], format: "FLAC", bitrate: 900)
        let mp3Copy = album("/Device/Music/Kind of Blue", numbers: [1, 2], format: "MP3", bitrate: 128, ext: "mp3")
        let flacCopy = album("/Device/Music/Kind of Blue (2)", numbers: [1, 2], format: "FLAC", bitrate: 900)

        let result = compare(sending, mp3Copy + flacCopy)

        XCTAssertEqual(result.map(\.status), [.present])
        XCTAssertEqual(result[0].deviceCopyCount, 2)
        XCTAssertEqual(result[0].deviceFolder?.path, "/Device/Music/Kind of Blue (2)")
    }

    func testTwoCopiesPicksMostMatched() {
        let sending = album("/Src/Kind of Blue", numbers: [1, 2, 3, 4], format: "FLAC", bitrate: 900)
        let small = album("/Device/Music/Kind of Blue", numbers: [1], format: "MP3", bitrate: 128, ext: "mp3")
        let large = album("/Device/Music/Kind of Blue (2)", numbers: [1, 2, 3], format: "MP3", bitrate: 128, ext: "mp3")

        let result = compare(sending, small + large)

        XCTAssertEqual(result.map(\.status), [.differs])
        XCTAssertEqual(result[0].deviceCopyCount, 2)
        XCTAssertEqual(result[0].deviceFolder?.path, "/Device/Music/Kind of Blue (2)")
        XCTAssertEqual(result[0].changed.count, 3)
        XCTAssertEqual(result[0].missing.count, 1)
        XCTAssertEqual(result[0].deviceTracks.count, 3)
    }

    func testTiedCopiesPreferTheUnsuffixedFolder() {
        let sending = album("/Src/Kind of Blue", numbers: [1], format: "FLAC", bitrate: 900)
        let second = album("/Device/Music/Kind of Blue (2)", numbers: [1], format: "MP3", bitrate: 128, ext: "mp3")
        let first = album("/Device/Music/Kind of Blue", numbers: [1], format: "MP3", bitrate: 128, ext: "mp3")

        let result = compare(sending, second + first)

        XCTAssertEqual(result[0].deviceFolder?.path, "/Device/Music/Kind of Blue")
    }

    // MARK: - Review focus

    func testNoTrackNumbersMatchByTitle() {
        let sending = ["Song A", "Song B", "Song C"].map {
            track(album: "Loose", number: nil, title: $0, path: "/Src/Loose/\($0).flac")
        }
        let device = ["song a", "Song B"].map {
            track(album: "Loose", number: nil, title: $0, path: "/Device/Music/Loose/\($0).flac")
        }

        let result = compare(sending, device)

        XCTAssertEqual(result.map(\.status), [.gaps])
        XCTAssertEqual(result[0].same.map(\.track.title), ["Song A", "Song B"])
        XCTAssertEqual(result[0].missing.map(\.track.title), ["Song C"])
    }

    func testNumberOnOneSideOnlyFallsBackToTitle() {
        let sending = [track(album: "Loose", number: 3, title: "Song A", path: "/Src/Loose/03 Song A.flac")]
        let device = [track(album: "Loose", number: nil, title: "Song A", path: "/Device/Music/Loose/Song A.flac")]

        XCTAssertEqual(compare(sending, device).map(\.status), [.present])
    }

    func testSlotMatchesBeforeTitleFallback() {
        // The unnumbered MP3 comes first and would title-match the device's
        // track 1 if pairing went in list order, leaving the numbered FLAC
        // (the same form as the device copy) unmatched.
        let loose = track(album: "Kind of Blue", number: nil, title: "Track 1", format: "MP3", bitrate: 128,
                          path: "/Src/Kind of Blue/Track 1.mp3")
        let numbered = track(album: "Kind of Blue", number: 1, title: "Track 1",
                             path: "/Src/Kind of Blue/01 Track 1.flac")
        let device = album("/Device/Music/Kind of Blue", numbers: [1])

        let result = compare([loose, numbered], device)

        XCTAssertEqual(result.map(\.status), [.gaps])
        XCTAssertEqual(result[0].same.map(\.track.fileURL.path), ["/Src/Kind of Blue/01 Track 1.flac"])
        XCTAssertEqual(result[0].missing.map(\.track.fileURL.path), ["/Src/Kind of Blue/Track 1.mp3"])
    }

    func testDuplicateSourcePathsCountedOnce() {
        let one = album("/Src/Kind of Blue", numbers: [1, 2])
        let sending = one + one
        let device = album("/Device/Music/Kind of Blue", numbers: [1, 2])

        let result = compare(sending, device)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].sent.count, 2)
        XCTAssertEqual(result[0].status, .present)

        let empty = compare(sending, [])
        XCTAssertEqual(empty[0].missing.count, 2)
    }

    func testLeftAloneFlagged() throws {
        let sending = album("/Src/Kind of Blue", numbers: [1], format: "FLAC", bitrate: 900)
        let device = album("/Device/Music/Kind of Blue", numbers: [1], format: "MP3", bitrate: 128, ext: "mp3")
        let identity = try XCTUnwrap(DeviceAlbumIdentity.identities(for: sending)[sending[0].track.id])

        let result = matcher.compare(sending: sending, catalog: device, settings: copySettings, leftAlone: [identity])

        XCTAssertEqual(result.map(\.status), [.differs])
        XCTAssertTrue(result[0].isLeftAlone)
        XCTAssertFalse(compare(sending, device)[0].isLeftAlone)
    }

    func testResultsKeepSendingOrder() {
        let first = album("/Src/B", album: "Bitches Brew", numbers: [1])
        let second = album("/Src/K", album: "Kind of Blue", numbers: [1])

        let result = compare(first + second, [])

        XCTAssertEqual(result.map(\.displayAlbum), ["Bitches Brew", "Kind of Blue"])
    }

    // MARK: - Fixtures

    private func compare(
        _ sending: [LoadedTrack],
        _ catalog: [LoadedTrack],
        settings: ExternalDeviceTransferSettings? = nil
    ) -> [DeviceAlbumComparison] {
        matcher.compare(sending: sending, catalog: catalog, settings: settings ?? copySettings, leftAlone: [])
    }

    private func album(
        _ folder: String,
        album: String = "Kind of Blue",
        numbers: [Int],
        format: String = "FLAC",
        bitrate: Int? = 900,
        ext: String = "flac",
        art: Int? = nil,
        artSource: ArtworkSource = .embedded,
        trackTotal: Int? = nil,
        year: Int? = nil
    ) -> [LoadedTrack] {
        numbers.map { number in
            track(album: album, number: number, title: "Track \(number)", format: format, bitrate: bitrate,
                  path: "\(folder)/0\(number) Track \(number).\(ext)", art: art, artSource: artSource,
                  trackTotal: trackTotal, year: year)
        }
    }

    private func track(
        album: String,
        artist: String = "Miles Davis",
        albumArtist: String? = nil,
        disc: Int? = nil,
        number: Int?,
        title: String,
        format: String = "FLAC",
        bitrate: Int? = 900,
        path: String,
        art: Int? = nil,
        artSource: ArtworkSource = .embedded,
        trackTotal: Int? = nil,
        year: Int? = nil
    ) -> LoadedTrack {
        let audio = AudioTrack(
            fileURL: URL(fileURLWithPath: path),
            title: title,
            artist: artist,
            album: album,
            formatName: format,
            bitrateKbps: bitrate,
            sampleRateHz: 44_100,
            year: year,
            trackNumber: number,
            trackTotal: trackTotal,
            discNumber: disc,
            artworkSource: art == nil ? .none : artSource,
            artworkDimensions: art.map { ArtworkDimensions(width: $0, height: $0) }
        )
        let metadata = ConversionMetadata(
            title: title,
            artist: artist,
            albumArtist: albumArtist,
            album: album,
            trackNumber: number,
            trackTotal: trackTotal,
            discNumber: disc,
            year: year
        )
        return LoadedTrack(track: audio, metadata: metadata)
    }

    private func withArtHash(_ loaded: LoadedTrack, _ hash: String) -> LoadedTrack {
        var audio = loaded.track
        audio.artworkHash = hash
        return LoadedTrack(track: audio, metadata: loaded.metadata)
    }
}
#endif
