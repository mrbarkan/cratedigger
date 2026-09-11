#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// One album folder is one album, whatever its files' tags disagree about.
/// Each of these three disagreements used to shatter a release into several
/// albums that then sorted apart in the browser.
final class AlbumReconciliationTests: XCTestCase {

    private func track(
        _ file: String,
        artist: String = "",
        albumArtist: String? = nil,
        album: String,
        year: Int? = nil,
        disc: Int? = nil,
        compilation: Bool? = nil
    ) -> LoadedTrack {
        let url = URL(fileURLWithPath: file)
        let audio = AudioTrack(
            fileURL: url, title: url.deletingPathExtension().lastPathComponent,
            artist: artist, album: album, formatName: "flac",
            year: year, discNumber: disc
        )
        let metadata = ConversionMetadata(
            artist: artist.isEmpty ? nil : artist, albumArtist: albumArtist, album: album,
            compilation: compilation, discNumber: disc, year: year
        )
        return LoadedTrack(track: audio, metadata: metadata)
    }

    private func albums(_ tracks: [LoadedTrack]) -> [Album] {
        LibraryIndex.build(from: tracks).allAlbums
    }

    // MARK: - Disc suffixes in the album tag

    func testDiscSuffixInAlbumTagStaysOneAlbum() {
        let result = albums([
            track("/m/X/Album/CD1/01.flac", artist: "X", album: "Album (Disc 1)", year: 1999, disc: 1),
            track("/m/X/Album/CD2/01.flac", artist: "X", album: "Album (Disc 2)", year: 1999, disc: 2)
        ])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].title, "Album")
        XCTAssertEqual(result[0].tracks.count, 2)
    }

    func testDiscSuffixVariantsAllStrip() {
        let cases = [
            "Album (Disc 1)", "Album [CD 2]", "Album - Disc 3", "Album, CD4",
            "Album Disc 5", "Album (Disc 1 of 2)", "Album (cd1)"
        ]
        for title in cases {
            XCTAssertEqual(OutputPathPlanner.strippingDiscSuffix(title), "Album", title)
        }
    }

    func testDiscOnlyTitleIsLeftAlone() {
        // Stripping would leave nothing, so the tag stands as written.
        XCTAssertEqual(OutputPathPlanner.strippingDiscSuffix("Disc 2"), "Disc 2")
    }

    func testUnrelatedTrailingNumberSurvives() {
        XCTAssertEqual(OutputPathPlanner.strippingDiscSuffix("Album Vol. 2"), "Album Vol. 2")
        XCTAssertEqual(OutputPathPlanner.strippingDiscSuffix("Blonde on Blonde"), "Blonde on Blonde")
    }

    func testDiscSubfolderNamesFoldIntoTheAlbumFolder() {
        // Picard's default is "{disc} - {media}"; other rippers write "Disc 1
        // - Live", "CD 2 (Bonus)" or a bare "1". All of them are one album.
        let planner = OutputPathPlanner()
        for sub in ["01 - Digital Media", "2 - CD", "Disc 1 - Live", "CD 2 (Bonus)", "1", "Disk_03", "D2"] {
            let t = track("/m/X/Album/\(sub)/01.flac", artist: "X", album: "Album")
            XCTAssertEqual(planner.albumSourceFolder(for: t), "/m/X/Album", sub)
        }
        // A numbered *album* folder is not a disc folder: a year, or a name
        // that only ends in a number.
        for sub in ["1994 - Album", "Album 2", "Vol. 3", "Take 5"] {
            let t = track("/m/X/\(sub)/01.flac", artist: "X", album: "Album")
            XCTAssertEqual(planner.albumSourceFolder(for: t), "/m/X/\(sub)", sub)
        }
    }

    func testSeparateDiscFoldersKeepTheirOwnTitles() {
        // Two disc folders that are NOT disc-named subfolders of one album are
        // still two albums, and must keep the titles that tell them apart —
        // that is what the auto box-set fold labels its members with.
        let result = albums([
            track("/m/Box Disc 1/01.flac", artist: "X", album: "Box Disc 1", year: 1999),
            track("/m/Box Disc 2/01.flac", artist: "X", album: "Box Disc 2", year: 1999)
        ])
        XCTAssertEqual(Set(result.map(\.title)), ["Box Disc 1", "Box Disc 2"])
    }

    // MARK: - Compilations and soundtracks with no album-artist tag

    func testSoundtrackWithoutCompilationFlagReunitesUnderVariousArtists() {
        let result = albums([
            track("/m/OST/Pulp Fiction/01.flac", artist: "Dick Dale", album: "Pulp Fiction", year: 1994),
            track("/m/OST/Pulp Fiction/02.flac", artist: "Kool & the Gang", album: "Pulp Fiction", year: 1994),
            track("/m/OST/Pulp Fiction/03.flac", artist: "Al Green", album: "Pulp Fiction", year: 1994)
        ])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].artistName, "Various Artists")
        XCTAssertEqual(result[0].tracks.count, 3)
    }

    func testExplicitAlbumArtistOutranksPerTrackArtists() {
        let result = albums([
            track("/m/A/Live/01.flac", artist: "Band feat. Guest", albumArtist: "Band", album: "Live", year: 2004),
            track("/m/A/Live/02.flac", artist: "Band", albumArtist: "Band", album: "Live", year: 2004)
        ])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].artistName, "Band")
    }

    func testDifferentFoldersAreStillDifferentAlbums() {
        // Reconciliation is per folder: a compilation must not swallow a
        // same-titled album that lives somewhere else.
        let result = albums([
            track("/m/Comp/Hits/01.flac", artist: "A", album: "Hits", year: 1990),
            track("/m/Comp/Hits/02.flac", artist: "B", album: "Hits", year: 1990),
            track("/m/Solo/Hits/01.flac", artist: "C", album: "Hits", year: 1990)
        ])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Set(result.map(\.artistName)), ["Various Artists", "C"])
    }

    func testLooseUntaggedFilesStillSplitPerArtist() {
        // No album tag: these are not one album, they are a pile of files.
        let result = albums([
            track("/m/Downloads/01.flac", artist: "A", album: ""),
            track("/m/Downloads/02.flac", artist: "B", album: "")
        ])
        XCTAssertEqual(result.count, 2)
    }

    // MARK: - The conversion output planner agrees with the browser

    func testSoundtrackConvertsIntoOneFolder() {
        let planner = OutputPathPlanner()
        let tracks = [
            track("/m/OST/Pulp Fiction/01.flac", artist: "Dick Dale", album: "Pulp Fiction", year: 1994),
            track("/m/OST/Pulp Fiction/02.flac", artist: "Kool & the Gang", album: "Pulp Fiction", year: 1994),
            track("/m/OST/Pulp Fiction/03.flac", artist: "Al Green", album: "Pulp Fiction", year: 1994)
        ]
        let keys = planner.albumFolderKeys(for: tracks)
        let subpaths = Set(tracks.map {
            planner.buildOutputSubpath(
                for: $0,
                templateConfig: FolderTemplateConfig(
                    preset: .custom,
                    tokenOrder: [.year, .albumArtist, .album, .disabled, .disabled]
                ),
                albumKey: keys[$0.track.id]
            )
        })
        XCTAssertEqual(subpaths, ["1994/Various Artists/Pulp Fiction"])
    }

    func testMultiDiscConvertsIntoOneFolder() {
        let planner = OutputPathPlanner()
        let tracks = [
            track("/m/X/Album/CD1/01.flac", artist: "X", album: "Album (Disc 1)", year: 1999, disc: 1),
            track("/m/X/Album/CD2/01.flac", artist: "X", album: "Album (Disc 2)", year: 1999, disc: 2)
        ]
        let keys = planner.albumFolderKeys(for: tracks)
        // Reserve as we go, exactly as `planConversionJobs` does.
        var reserved = Set<String>()
        var destinations: [PlannedOutputPath] = []
        for track in tracks {
            let planned = planner.planDestination(
                for: track,
                preset: .genericAAC,
                destinationRoot: URL(fileURLWithPath: "/Converted", isDirectory: true),
                sourceRoot: nil,
                folderMode: .metadataTemplate,
                templateConfig: FolderTemplateConfig(
                    preset: .custom,
                    tokenOrder: [.albumArtist, .album, .disabled, .disabled, .disabled]
                ),
                reservedDestinationPaths: reserved,
                avoidExistingFiles: false,
                albumKey: keys[track.track.id]
            )
            reserved.insert(planned.destinationURL.standardizedFileURL.resolvingSymlinksInPath().path)
            destinations.append(planned)
        }
        XCTAssertEqual(Set(destinations.map(\.relativeSubpath)), ["X/Album"])
        // Both discs open with a track 01: the planner's collision-safe naming
        // is what keeps them from overwriting each other in the shared folder.
        XCTAssertEqual(destinations.count, Set(destinations.map(\.destinationURL.path)).count)
    }

    func testALoneTrackStillPlansFromItsOwnTags() {
        // No batch to reconcile against: the per-track key is all there is.
        let planner = OutputPathPlanner()
        let lone = track("/m/OST/Pulp Fiction/01.flac", artist: "Dick Dale", album: "Pulp Fiction", year: 1994)
        let subpath = planner.buildOutputSubpath(
            for: lone,
            templateConfig: FolderTemplateConfig(
                preset: .custom,
                tokenOrder: [.year, .albumArtist, .album, .disabled, .disabled]
            )
        )
        XCTAssertEqual(subpath, "1994/Dick Dale/Pulp Fiction")
    }

    // MARK: - Year disagreement

    func testPerTrackYearsDoNotSplitAnAlbum() {
        let result = albums([
            track("/m/X/Album/01.flac", artist: "X", album: "Album", year: 1999),
            track("/m/X/Album/02.flac", artist: "X", album: "Album", year: 1999),
            track("/m/X/Album/03.flac", artist: "X", album: "Album", year: 2007)
        ])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].year, 1999, "the year the album mostly agrees on wins")
    }
}
#endif
