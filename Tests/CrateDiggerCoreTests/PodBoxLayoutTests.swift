import XCTest
@testable import CrateDiggerCore

/// The layout PodBox reads best (`Album Artist / YYYY Album`), and the
/// player's own readings of folder names: a year in front, a disc folder.
final class PodBoxLayoutTests: XCTestCase {
    private func track(albumArtist: String, album: String, year: Int?) -> LoadedTrack {
        LoadedTrack(track: AudioTrack(fileURL: URL(fileURLWithPath: "/Library/x/01.flac"), title: "01",
                                      artist: albumArtist, album: album),
                    metadata: ConversionMetadata(artist: albumArtist, albumArtist: albumArtist, album: album, year: year))
    }

    private func folder(_ preset: RockboxLayoutPreset, _ track: LoadedTrack) throws -> String {
        let template = try XCTUnwrap(preset.template)
        return "Music/" + OutputPathPlanner().buildOutputSubpath(for: track, templateConfig: template)
    }

    func testRecommendedTemplatePlansArtistYearAlbum() throws {
        XCTAssertEqual(try folder(.podBoxRecommended, track(albumArtist: "Beach House", album: "Teen Dream", year: 2010)),
                       "Music/Beach House/2010 Teen Dream")
        XCTAssertEqual(try folder(.artistAlbum, track(albumArtist: "Beach House", album: "Teen Dream", year: 2010)),
                       "Music/Beach House/Teen Dream")
    }

    func testMissingYearLeavesNoLeadingSpace() throws {
        XCTAssertEqual(try folder(.podBoxRecommended, track(albumArtist: "Beach House", album: "Teen Dream", year: nil)),
                       "Music/Beach House/Teen Dream")
    }

    /// Controller ruling: an existing custom template (no flag) keeps exactly
    /// the paths it produced before, even when it groups the same tokens as
    /// the PodBox preset, so an album already on a device as "Unknown Year X"
    /// is never written again as "X".
    func testExistingCustomTemplateKeepsUnknownYear() throws {
        let existing = FolderTemplateConfig(preset: .custom, tokenOrder: [.albumArtist, .year, .album, .disabled, .disabled],
                                            separators: [.slash, .space])
        let noYear = track(albumArtist: "Beach House", album: "Teen Dream", year: nil)
        XCTAssertEqual(OutputPathPlanner().buildOutputSubpath(for: noYear, templateConfig: existing),
                       "Beach House/Unknown Year Teen Dream")
        XCTAssertEqual(RockboxLayoutPreset.matching(existing), .custom, "it is not the preset, which would drop the year")

        // Saved and read back, it stays the same template, byte for byte.
        let data = try JSONEncoder().encode(existing)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("omitsMissingYear"))
        XCTAssertEqual(try JSONDecoder().decode(FolderTemplateConfig.self, from: data), existing)
        let preset = try XCTUnwrap(RockboxLayoutPreset.podBoxRecommended.template)
        XCTAssertEqual(try JSONDecoder().decode(FolderTemplateConfig.self, from: JSONEncoder().encode(preset)), preset)
    }

    /// A year that is its folder's only token keeps the old fallback.
    func testMissingYearAloneInItsFolderIsUnchanged() {
        let template = FolderTemplateConfig(preset: .artistYearAlbum, tokenOrder: TemplatePreset.artistYearAlbum.defaultTokenOrder)
        XCTAssertEqual(OutputPathPlanner().buildOutputSubpath(
            for: track(albumArtist: "Beach House", album: "Teen Dream", year: nil), templateConfig: template),
            "Beach House/Unknown Year/Teen Dream")
    }

    func testArtistFolderKeyEqualsTagKey() throws {
        for artist in ["AC/DC", "Björk", "Simon & Garfunkel", "The The", "Sigur Rós", "Beatles, The"] {
            let planned = try folder(.podBoxRecommended, track(albumArtist: artist, album: "Album", year: 2000))
            let artistFolder = planned.split(separator: "/")[1]
            XCTAssertEqual(PodBoxArtName.key(String(artistFolder)), PodBoxArtName.key(artist), "\(artist) -> \(artistFolder)")
        }
    }

    func testPresetTitlesAndCaptions() {
        XCTAssertEqual(RockboxLayoutPreset.allCases.map(\.title), ["PodBox recommended", "Artist / Album", "Custom"])
        XCTAssertEqual(RockboxLayoutPreset.allCases.map(\.caption),
                       ["Artist / 2010 Album", "Artist / Album", "Set in the transfer panel"])
        XCTAssertNil(RockboxLayoutPreset.custom.template)
        XCTAssertEqual(RockboxLayoutPreset.podBoxRecommended.template,
                       FolderTemplateConfig(preset: .custom, tokenOrder: [.albumArtist, .year, .album, .disabled, .disabled],
                                            separators: [.slash, .space], omitsMissingYear: true))
    }

    func testMatchingRoundTrips() throws {
        for preset in [RockboxLayoutPreset.podBoxRecommended, .artistAlbum] {
            XCTAssertEqual(RockboxLayoutPreset.matching(try XCTUnwrap(preset.template)), preset)
        }
        // Separators that change nothing still match.
        XCTAssertEqual(RockboxLayoutPreset.matching(FolderTemplateConfig(
            preset: .custom, tokenOrder: [.albumArtist, .year, .album, .disabled, .disabled],
            separators: [.slash, .space, .slash, .space], omitsMissingYear: true)), .podBoxRecommended)
        XCTAssertEqual(RockboxLayoutPreset.matching(FolderTemplateConfig(
            preset: .custom, tokenOrder: [.albumArtist, .album, .disabled, .disabled, .disabled],
            separators: [.slash, .slash, .slash, .slash])), .artistAlbum)
    }

    func testMatchingUnknownIsCustom() {
        XCTAssertEqual(RockboxLayoutPreset.matching(FolderTemplateConfig(
            preset: .artistYearAlbum, tokenOrder: TemplatePreset.artistYearAlbum.defaultTokenOrder)), .custom)
        XCTAssertEqual(RockboxLayoutPreset.matching(FolderTemplateConfig(
            preset: .custom, tokenOrder: [.albumArtist, .year, .album, .disabled, .disabled])), .custom,
            "Artist / Year / Album in three folders is not the recommended layout")
        XCTAssertEqual(RockboxLayoutPreset.matching(FolderTemplateConfig(
            preset: .custom, tokenOrder: [.album, .albumArtist, .disabled, .disabled, .disabled])), .custom)
    }

    func testYearParse() {
        XCTAssertEqual(PodBoxFolderYear.parse("2010 Teen Dream"), 2010)
        XCTAssertNil(PodBoxFolderYear.parse("1106 Blue Weekend"))
        XCTAssertNil(PodBoxFolderYear.parse("20101 Album"))
        XCTAssertEqual(PodBoxFolderYear.parse("1999"), 1999)
        XCTAssertNil(PodBoxFolderYear.parse("2100 X"))
        XCTAssertNil(PodBoxFolderYear.parse("199"))
        XCTAssertEqual(PodBoxFolderYear.parse("1984-Remaster"), 1984)
        XCTAssertNil(PodBoxFolderYear.parse("١٩٩٩ Arabic digits"), "ASCII digits only")
    }

    func testDiscFolders() {
        for yes in ["CD1", "Disc 2", "disk_3", "disc-04", "CD 1", "DISC.12"] {
            XCTAssertTrue(PodBoxDiscFolder.isDiscFolder(yes), yes)
        }
        for no in ["Disc 1 of 2", "Disco", "CD", "Disc A", "CD1 Bonus", "My CD1", ""] {
            XCTAssertFalse(PodBoxDiscFolder.isDiscFolder(no), no)
        }
    }

    func testMisreadYears() {
        let notes = PodBoxLayoutNotes.misreadYears(plannedAlbumFolders: [
            ("Music/George Michael/1984", 1984),
            ("Music/Van Halen/1984", nil),
            ("Music/Prince/1999", 1982),
            ("Music/Beach House/2010 Teen Dream", 2010),
            ("Music/Blur/Parklife", 1994),
        ])
        XCTAssertEqual(notes.map(\.folder), ["Music/Van Halen/1984", "Music/Prince/1999"])
        XCTAssertEqual(notes.map(\.parsed), [1984, 1999])
        XCTAssertEqual(notes.map(\.tag), [nil, 1982])
    }

    func testExistingRockboxFactoryTemplateIsUnchanged() {
        let template = ExternalDeviceProfile.rockboxIPod().transferSettings.templateConfig
        XCTAssertEqual(template, FolderTemplateConfig(preset: .custom,
                                                      tokenOrder: [.albumArtist, .album, .disabled, .disabled, .disabled]))
        XCTAssertEqual(RockboxLayoutPreset.matching(template), .artistAlbum)
    }
}
