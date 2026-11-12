#if canImport(XCTest)
import CrateDiggerCore
import XCTest
@testable import CrateDiggerApp

/// A convert-mode device run is seeded into the CNVRT cockpit from the
/// device's settings, and the cockpit's selection is then the truth for the
/// run: the device review plans with settings built back from it. The two
/// directions must agree, or the review compares against a layout or art the
/// run never writes.
final class DeviceSelectionSettingsTests: XCTestCase {

    private func userSelection() -> ConversionOptionsSelection {
        ConversionOptionsSelection(
            batchScope: .queue,
            outputFormat: .flac,
            bitrate: nil,
            sampleRate: 96_000,
            bitDepth: 24,
            flacCompressionLevel: 8,
            artworkMode: .preserve,
            artworkMaxDimension: nil,
            folderStructureMode: .flat,
            applyMode: .applyAll,
            templatePreset: .yearArtistAlbum,
            tokenOrder: FolderTokenOrder.normalize(TemplatePreset.yearArtistAlbum.defaultTokenOrder),
            separators: []
        )
    }

    private func deviceSettings() -> ExternalDeviceTransferSettings {
        ExternalDeviceTransferSettings(
            mode: .convertDuringTransfer,
            outputFormat: .mp3,
            bitrateKbps: 256,
            sampleRateHz: 44_100,
            artworkMaxDimension: 500,
            artworkMode: .none,
            writesFolderCoverArt: true,
            deviceProfile: .ipodLegacySafe,
            folderStructureMode: .metadataTemplate,
            templateConfig: FolderTemplateConfig(
                preset: .artistYearAlbum,
                tokenOrder: FolderTokenOrder.normalize(TemplatePreset.artistYearAlbum.defaultTokenOrder),
                separators: [.space, .slash]
            )
        )
    }

    func testSelectionRoundTripsThroughSettings() {
        let settings = deviceSettings()
        let seeded = userSelection().seeded(from: settings)
        XCTAssertEqual(seeded.deviceTransferSettings(over: settings), settings)
    }

    /// The device's stored art mode reaches the cockpit (a Strip device used
    /// to get there only by an override for Rockbox), and the archival knobs
    /// a device stores nothing for are not carried onto it.
    func testSeedingTakesTheDevicesArtAndLayout() {
        let seeded = userSelection().seeded(from: deviceSettings())
        XCTAssertEqual(seeded.outputFormat, .mp3)
        XCTAssertEqual(seeded.bitrate, 256)
        XCTAssertEqual(seeded.sampleRate, 44_100)
        XCTAssertEqual(seeded.artworkMode, ArtworkMode.none)
        XCTAssertEqual(seeded.artworkMaxDimension, 500)
        XCTAssertEqual(seeded.folderStructureMode, .metadataTemplate)
        XCTAssertEqual(seeded.templatePreset, .artistYearAlbum)
        XCTAssertEqual(seeded.separators, [.space, .slash])
        XCTAssertNil(seeded.bitDepth)
        XCTAssertNil(seeded.flacCompressionLevel)
        // What the device doesn't decide stays the user's.
        XCTAssertEqual(seeded.batchScope, .queue)
        XCTAssertEqual(seeded.applyMode, .applyAll)
    }

    /// Changes made in the cockpit after seeding are what the run writes; the
    /// settings the selection has no row for stay the device's.
    func testCockpitChangesReachTheSettingsAndTheRestStaysTheDevices() {
        let base = deviceSettings()
        var selection = userSelection().seeded(from: base)
        selection.outputFormat = .aac
        selection.bitrate = 128
        selection.artworkMode = .compatReembed
        selection.artworkMaxDimension = 300
        selection.folderStructureMode = .flat

        let settings = selection.deviceTransferSettings(over: base)
        XCTAssertEqual(settings.outputFormat, .aac)
        XCTAssertEqual(settings.bitrateKbps, 128)
        XCTAssertEqual(settings.artworkMode, .compatReembed)
        XCTAssertEqual(settings.artworkMaxDimension, 300)
        XCTAssertEqual(settings.folderStructureMode, .flat)
        XCTAssertTrue(settings.writesFolderCoverArt)
        XCTAssertEqual(settings.deviceProfile, .ipodLegacySafe)
    }

    /// The Folder Art row is seeded from the device and goes back to it: what
    /// the review compares (the stored switch) is what the cockpit showed.
    func testFolderArtSwitchSeedsAndReturns() {
        let base = deviceSettings()
        var selection = userSelection().seeded(from: base)
        XCTAssertTrue(selection.writesFolderCoverArt)

        selection.writesFolderCoverArt = false
        XCTAssertFalse(selection.deviceTransferSettings(over: base).writesFolderCoverArt)

        var off = base
        off.writesFolderCoverArt = false
        XCTAssertFalse(userSelection().seeded(from: off).writesFolderCoverArt)
    }

    /// A selection saved before the switch existed decodes with it off, and
    /// one saved with it keeps it.
    func testSelectionDecodesWithoutTheFolderArtKey() throws {
        var selection = userSelection()
        selection.writesFolderCoverArt = true
        let encoded = try JSONEncoder().encode(selection)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["writesFolderCoverArt"] as? Bool, true)
        XCTAssertTrue(try JSONDecoder().decode(ConversionOptionsSelection.self, from: encoded).writesFolderCoverArt)

        object.removeValue(forKey: "writesFolderCoverArt")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ConversionOptionsSelection.self, from: legacy)
        XCTAssertFalse(decoded.writesFolderCoverArt)
        XCTAssertEqual(decoded.outputFormat, .flac)
    }

    /// A run from the cockpit always converts, whatever the stored mode says
    /// by the time Go is pressed: the planner then names files by the output
    /// format, as the jobs write them.
    func testSettingsAlwaysConvert() {
        var base = deviceSettings()
        base.mode = .copyOriginals
        let settings = userSelection().seeded(from: base).deviceTransferSettings(over: base)
        XCTAssertEqual(settings.mode, .convertDuringTransfer)
    }
}
#endif
