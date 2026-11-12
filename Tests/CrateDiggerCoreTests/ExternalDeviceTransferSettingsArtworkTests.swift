#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// The embedded-art mode and the folder-art switch became stored settings.
/// Profiles saved before they existed must decode to exactly what those
/// devices did before: a Rockbox iPod stripped embedded art and wrote a
/// `cover.jpg`; every other device re-embedded when it had a size cap and kept
/// the source's art when it had none.
final class ExternalDeviceTransferSettingsArtworkTests: XCTestCase {

    // MARK: - Legacy profiles

    func testLegacyRockboxProfileDecodesStripPlusFolderArt() throws {
        let profile = try decode(Self.legacyRockboxJSON)

        XCTAssertEqual(profile.transferSettings.artworkMode, ArtworkMode.none)
        XCTAssertTrue(profile.transferSettings.writesFolderCoverArt)
        XCTAssertTrue(profile.usesFolderCoverArt)
        XCTAssertEqual(profile.transferSettings.artworkMaxDimension, 600)
        XCTAssertEqual(profile.transferSettings.conversionPreset?.artworkMode, ArtworkMode.none)
    }

    func testLegacyGenericProfileWithCapDecodesReembedNoFolderArt() throws {
        let profile = try decode(Self.legacyGenericJSON)

        XCTAssertEqual(profile.transferSettings.artworkMode, .compatReembed)
        XCTAssertFalse(profile.transferSettings.writesFolderCoverArt)
        XCTAssertFalse(profile.usesFolderCoverArt)
    }

    func testLegacyGenericProfileWithoutCapDecodesKeep() throws {
        let json = Self.legacyGenericJSON.replacingOccurrences(of: "\"artworkMaxDimension\" : 1024,\n", with: "")
        XCTAssertFalse(json.contains("artworkMaxDimension"), "fixture edit must take")

        let profile = try decode(json)

        XCTAssertNil(profile.transferSettings.artworkMaxDimension)
        XCTAssertEqual(profile.transferSettings.artworkMode, .preserve)
        XCTAssertFalse(profile.transferSettings.writesFolderCoverArt)
    }

    func testStoredKeysWinOverKind() throws {
        let rockbox = Self.legacyRockboxJSON.replacingOccurrences(
            of: "\"artworkMaxDimension\" : 600,",
            with: "\"artworkMaxDimension\" : 600, \"artworkMode\" : \"preserve\", \"writesFolderCoverArt\" : false,"
        )
        let generic = Self.legacyGenericJSON.replacingOccurrences(
            of: "\"artworkMaxDimension\" : 1024,",
            with: "\"artworkMaxDimension\" : 1024, \"artworkMode\" : \"none\", \"writesFolderCoverArt\" : true,"
        )

        let storedRockbox = try decode(rockbox)
        XCTAssertEqual(storedRockbox.transferSettings.artworkMode, .preserve)
        XCTAssertFalse(storedRockbox.usesFolderCoverArt)

        let storedGeneric = try decode(generic)
        XCTAssertEqual(storedGeneric.transferSettings.artworkMode, ArtworkMode.none)
        XCTAssertTrue(storedGeneric.usesFolderCoverArt)
    }

    func testEncodedProfileRoundTripsBothSettings() throws {
        var profile = ExternalDeviceProfile.genericStorage(name: "Stick")
        profile.transferSettings.artworkMode = .none
        profile.transferSettings.writesFolderCoverArt = true

        let decoded = try JSONDecoder().decode(ExternalDeviceProfile.self, from: JSONEncoder().encode(profile))

        XCTAssertEqual(decoded, profile)
    }

    func testSettingsAloneDecodeTheCapDefault() throws {
        // Without a profile around them, settings don't know the device kind.
        let settings = try JSONDecoder().decode(
            ExternalDeviceTransferSettings.self,
            from: Data(Self.legacyRockboxSettingsJSON.utf8)
        )

        XCTAssertEqual(settings.artworkMode, .compatReembed)
        XCTAssertFalse(settings.writesFolderCoverArt)
    }

    // MARK: - Built-in profiles

    func testRockboxFactoryIsStripPlusFolderArt() {
        let profile = ExternalDeviceProfile.rockboxIPod()

        XCTAssertEqual(profile.transferSettings.artworkMode, ArtworkMode.none)
        XCTAssertTrue(profile.usesFolderCoverArt)
    }

    func testOtherFactoriesKeepTheirArtAndWriteNoCovers() {
        XCTAssertEqual(ExternalDeviceProfile.genericStorage().transferSettings.artworkMode, .compatReembed)
        XCTAssertFalse(ExternalDeviceProfile.genericStorage().usesFolderCoverArt)
        XCTAssertEqual(ExternalDeviceProfile.directFilePlayer().transferSettings.artworkMode, .compatReembed)
        XCTAssertFalse(ExternalDeviceProfile.directFilePlayer().usesFolderCoverArt)
    }

    func testSuggestedRockboxProfileIsStripPlusFolderArt() throws {
        try withTemporaryDirectory(prefix: "suggest-rockbox") { dir in
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent(".rockbox"), withIntermediateDirectories: true)
            let device = MountedDevice(name: "IPOD", volumeURL: dir)

            let profile = DeviceProfileSuggester.suggestedProfile(for: device)

            XCTAssertEqual(profile.kind, .rockboxIPod)
            XCTAssertEqual(profile.transferSettings.artworkMode, ArtworkMode.none)
            XCTAssertTrue(profile.usesFolderCoverArt)
        }
    }

    // MARK: - Preset

    func testPresetReadsArtworkMode() {
        var settings = ExternalDeviceTransferSettings(artworkMaxDimension: 600)
        XCTAssertEqual(settings.conversionPreset?.artworkMode, .compatReembed)

        settings.artworkMode = .preserve
        XCTAssertEqual(settings.conversionPreset?.artworkMode, .preserve)

        settings.artworkMode = .none
        XCTAssertEqual(settings.conversionPreset?.artworkMode, ArtworkMode.none)
        XCTAssertEqual(settings.conversionPreset?.artworkMaxDimension, 600)

        // Folder art is a sidecar beside the files; it never touches the preset.
        settings.artworkMode = .compatReembed
        settings.writesFolderCoverArt = true
        XCTAssertEqual(settings.conversionPreset?.artworkMode, .compatReembed)

        settings.mode = .copyOriginals
        XCTAssertNil(settings.conversionPreset)
    }

    func testInitTakesStripLiterally() {
        // `.none` must mean Strip, never an optional's nil falling back to a default.
        XCTAssertEqual(
            ExternalDeviceTransferSettings(artworkMaxDimension: 600, artworkMode: .none).artworkMode,
            ArtworkMode.none
        )
        XCTAssertEqual(ExternalDeviceTransferSettings().artworkMode, .compatReembed)
    }

    // MARK: - Fixtures

    private func decode(_ json: String) throws -> ExternalDeviceProfile {
        try JSONDecoder().decode(ExternalDeviceProfile.self, from: Data(json.utf8))
    }

    /// `ExternalDeviceProfile.rockboxIPod(name: "Old iPod")` as the encoder
    /// wrote it before `artworkMode` and `writesFolderCoverArt` existed.
    private static let legacyRockboxJSON = """
    {
      "createdAt" : 0,
      "id" : "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
      "kind" : "rockbox_ipod",
      "musicDirectorySubpath" : "Music",
      "name" : "Old iPod",
      "transferSettings" : \(legacyRockboxSettingsJSON),
      "updatedAt" : 0
    }
    """

    private static let legacyRockboxSettingsJSON = """
    {
        "artworkMaxDimension" : 600,
        "bitrateKbps" : 192,
        "deviceProfile" : "generic",
        "folderStructureMode" : "metadata_template",
        "mode" : "convert_during_transfer",
        "outputFormat" : "mp3",
        "sampleRateHz" : 44100,
        "templateConfig" : {
          "preset" : "custom",
          "separators" : [

          ],
          "tokenOrder" : [
            "album_artist",
            "album",
            "disabled",
            "disabled",
            "disabled"
          ]
        }
      }
    """

    /// `ExternalDeviceProfile.genericStorage(name: "Stick")`, same vintage.
    private static let legacyGenericJSON = """
    {
      "createdAt" : 0,
      "id" : "3F2504E0-4F89-41D3-9A0C-0305E82C3302",
      "kind" : "generic_external_storage",
      "musicDirectorySubpath" : "Music",
      "name" : "Stick",
      "transferSettings" : {
        "artworkMaxDimension" : 1024,
        "bitrateKbps" : 192,
        "deviceProfile" : "generic",
        "folderStructureMode" : "metadata_template",
        "mode" : "convert_during_transfer",
        "outputFormat" : "aac",
        "sampleRateHz" : 44100,
        "templateConfig" : {
          "preset" : "artistYearAlbum",
          "separators" : [

          ],
          "tokenOrder" : [
            "album_artist",
            "year",
            "album"
          ]
        }
      },
      "updatedAt" : 0
    }
    """
}
#endif
