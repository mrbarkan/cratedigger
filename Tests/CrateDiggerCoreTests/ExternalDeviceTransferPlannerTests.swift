#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class ExternalDeviceTransferPlannerTests: XCTestCase {
    func testRockboxProfilePlansConvertedArtistAlbumFoldersUnderMusicDirectory() {
        let planner = ExternalDeviceTransferPlanner()
        let profile = ExternalDeviceProfile.rockboxIPod(name: "Rockbox iPod")
        let mountedRoot = URL(fileURLWithPath: "/Volumes/IPOD", isDirectory: true)
        let track = makeDeviceTrack(
            fileURL: URL(fileURLWithPath: "/Library/HiFi/Boards of Canada/Geogaddi/01 Ready Lets Go.flac"),
            artist: "Boards of Canada",
            album: "Geogaddi",
            year: 2002
        )

        let plans = planner.planTransfers(
            tracks: [track],
            profile: profile,
            mountedAt: mountedRoot
        )

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].action, .convert)
        XCTAssertEqual(plans[0].conversionPreset?.outputFormat, .mp3)
        XCTAssertEqual(plans[0].conversionPreset?.bitrateKbps, 192)
        XCTAssertEqual(plans[0].destinationURL.path, "/Volumes/IPOD/Music/Boards of Canada/Geogaddi/01 Ready Lets Go.mp3")
        XCTAssertEqual(plans[0].relativeSubpath, "Boards of Canada/Geogaddi")
    }

    func testDirectFileProfilePlansConvertedFilesAtDeviceRoot() {
        let planner = ExternalDeviceTransferPlanner()
        let profile = ExternalDeviceProfile.directFilePlayer(name: "Shuffle")
        let mountedRoot = URL(fileURLWithPath: "/Volumes/SHUFFLE", isDirectory: true)
        let track = makeDeviceTrack(
            fileURL: URL(fileURLWithPath: "/Library/HiFi/Fennesz/Endless Summer/01 Made in Hong Kong.flac"),
            artist: "Fennesz",
            album: "Endless Summer",
            year: 2001
        )

        let plans = planner.planTransfers(
            tracks: [track],
            profile: profile,
            mountedAt: mountedRoot
        )

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].action, .convert)
        XCTAssertEqual(plans[0].conversionPreset?.outputFormat, .mp3)
        XCTAssertEqual(plans[0].destinationURL.path, "/Volumes/SHUFFLE/01 Made in Hong Kong.mp3")
        XCTAssertNil(plans[0].relativeSubpath)
    }

    func testCopyOriginalModePreservesSourceExtension() {
        let planner = ExternalDeviceTransferPlanner()
        var profile = ExternalDeviceProfile.genericStorage(name: "SD Card")
        profile.transferSettings.mode = .copyOriginals
        profile.transferSettings.folderStructureMode = .metadataTemplate
        profile.transferSettings.templateConfig = FolderTemplateConfig(
            preset: .custom,
            tokenOrder: [.albumArtist, .album, .disabled, .disabled, .disabled]
        )

        let mountedRoot = URL(fileURLWithPath: "/Volumes/SD", isDirectory: true)
        let track = makeDeviceTrack(
            fileURL: URL(fileURLWithPath: "/Library/HiFi/Burial/Untrue/02 Archangel.flac"),
            artist: "Burial",
            album: "Untrue",
            year: 2007
        )

        let plans = planner.planTransfers(
            tracks: [track],
            profile: profile,
            mountedAt: mountedRoot
        )

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].action, .copyOriginal)
        XCTAssertNil(plans[0].conversionPreset)
        XCTAssertNil(plans[0].conversionJob)
        XCTAssertEqual(plans[0].destinationURL.path, "/Volumes/SD/Music/Burial/Untrue/02 Archangel.flac")
    }

    func testDeviceProfilesPersistThroughPreferencesStore() {
        let suiteName = "CrateDiggerDeviceProfileTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PreferencesStore(defaults: defaults)
        let profile = ExternalDeviceProfile.directFilePlayer(
            name: "Gym Shuffle",
            rootBookmark: Data([1, 2, 3]),
            rootDisplayPath: "/Volumes/SHUFFLE"
        )

        store.upsertExternalDeviceProfile(profile)

        XCTAssertEqual(store.savedExternalDeviceProfiles, [profile])
    }
}

private func makeDeviceTrack(
    fileURL: URL,
    artist: String,
    album: String,
    year: Int
) -> LoadedTrack {
    let metadata = ConversionMetadata(
        artist: artist,
        albumArtist: artist,
        album: album,
        year: year
    )
    let track = AudioTrack(
        fileURL: fileURL,
        title: fileURL.deletingPathExtension().lastPathComponent,
        artist: artist,
        album: album
    )
    return LoadedTrack(track: track, metadata: metadata)
}
#endif
