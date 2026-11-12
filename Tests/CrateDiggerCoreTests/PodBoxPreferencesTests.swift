import XCTest
@testable import CrateDiggerCore

final class PodBoxPreferencesTests: XCTestCase {
    /// A Rockbox iPod profile exactly as this branch encoded it before
    /// `podBox` existed (PreferencesStore's default JSONEncoder, keys sorted).
    private let savedBeforePodBox = """
    {"createdAt":800000000,"id":"6F1C2A4E-8B3D-4F5A-9C7E-1D2B3A4C5E6F","kind":"rockbox_ipod","musicDirectorySubpath":"Music","name":"PodBox iPod","transferSettings":{"artworkMaxDimension":600,"artworkMode":"none","bitrateKbps":192,"deviceProfile":"generic","folderStructureMode":"metadata_template","mode":"convert_during_transfer","outputFormat":"mp3","sampleRateHz":44100,"templateConfig":{"preset":"custom","separators":[],"tokenOrder":["album_artist","album","disabled","disabled","disabled"]},"writesFolderCoverArt":true},"updatedAt":800000100,"volumeUUID":"00000000-1111-2222-3333-444444444444"}
    """

    func testProfileSavedWithoutPodBoxDecodesNil() throws {
        let profile = try JSONDecoder().decode(ExternalDeviceProfile.self, from: Data(savedBeforePodBox.utf8))
        XCTAssertNil(profile.podBox)
        XCTAssertEqual(profile.podBoxPreferences, PodBoxPreferences())
        XCTAssertEqual(profile.name, "PodBox iPod")
        XCTAssertEqual(profile.kind, .rockboxIPod)
        XCTAssertEqual(profile.transferSettings.templateConfig.tokenOrder,
                       [.albumArtist, .album, .disabled, .disabled, .disabled])

        // Saving it again adds nothing while podBox is still nil.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(String(decoding: try encoder.encode(profile), as: UTF8.self), savedBeforePodBox)
    }

    func testDefaultsAreOffForPictures() {
        let preferences = PodBoxPreferences()
        XCTAssertEqual(preferences.artistPictures, .off)
        XCTAssertFalse(preferences.findsArtistPicturesAutomatically, "nothing is fetched until the owner asks")
        XCTAssertNil(preferences.lastSeenFirmware)
        XCTAssertEqual(preferences.passedChecks, [])

        XCTAssertNil(ExternalDeviceProfile.rockboxIPod().podBox)
        XCTAssertEqual(ExternalDeviceProfile.rockboxIPod().podBoxPreferences.artistPictures, .off)
        XCTAssertEqual(ExternalDeviceProfile(name: "x").podBoxPreferences.artistPictures, .off)
    }

    func testPartialPodBoxObjectDecodesWithDefaults() throws {
        let partial = try JSONDecoder().decode(PodBoxPreferences.self, from: Data(#"{"artistPictures":"artworkFolder"}"#.utf8))
        XCTAssertEqual(partial.artistPictures, .artworkFolder)
        XCTAssertFalse(partial.findsArtistPicturesAutomatically)
        XCTAssertNil(partial.lastSeenFirmware)
        XCTAssertEqual(partial.passedChecks, [])

        let empty = try JSONDecoder().decode(PodBoxPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, PodBoxPreferences())

        // Inside a profile too.
        let withPodBox = savedBeforePodBox.replacingOccurrences(
            of: #""name":"PodBox iPod","#, with: #""name":"PodBox iPod","podBox":{"passedChecks":["M5"]},"#)
        let profile = try JSONDecoder().decode(ExternalDeviceProfile.self, from: Data(withPodBox.utf8))
        XCTAssertEqual(profile.podBox?.passedChecks, ["M5"])
        XCTAssertEqual(profile.podBoxPreferences.artistPictures, .off)
    }

    func testUnknownPodBoxValueDoesNotLoseTheProfile() throws {
        let newer = savedBeforePodBox.replacingOccurrences(
            of: #""name":"PodBox iPod","#,
            with: #""name":"PodBox iPod","podBox":{"artistPictures":"somewhereNew","passedChecks":["M5"]},"#)
        let profile = try JSONDecoder().decode(ExternalDeviceProfile.self, from: Data(newer.utf8))
        XCTAssertEqual(profile.name, "PodBox iPod")
        XCTAssertNil(profile.podBox)
        XCTAssertEqual(profile.podBoxPreferences.artistPictures, .off)

        let list = "[" + newer + "," + savedBeforePodBox + "]"
        XCTAssertEqual(try JSONDecoder().decode([ExternalDeviceProfile].self, from: Data(list.utf8)).count, 2)
    }

    /// A profile saved with the retired `sweepsAppleDouble` key still reads.
    func testRetiredSweepKeyIsIgnored() throws {
        let old = try JSONDecoder().decode(PodBoxPreferences.self,
                                           from: Data(#"{"sweepsAppleDouble":false,"passedChecks":["M5"]}"#.utf8))
        XCTAssertEqual(old.passedChecks, ["M5"])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(old), as: UTF8.self).contains("sweepsAppleDouble"))
    }

    func testRoundTrip() throws {
        var preferences = PodBoxPreferences()
        preferences.artistPictures = .artistFolders
        preferences.findsArtistPicturesAutomatically = true
        preferences.lastSeenFirmware = "PodBox layout 5"
        preferences.passedChecks = ["M5", "M12"]
        var profile = ExternalDeviceProfile.rockboxIPod()
        profile.podBox = preferences

        let decoded = try JSONDecoder().decode(ExternalDeviceProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded.podBox, preferences)
        XCTAssertEqual(decoded, profile)
        XCTAssertEqual(ExternalDeviceProfile(name: "y", podBox: preferences).podBox, preferences)
    }
}
