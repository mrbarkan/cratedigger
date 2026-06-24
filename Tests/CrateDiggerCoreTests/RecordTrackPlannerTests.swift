import XCTest
@testable import CrateDiggerCore

final class RecordTrackPlannerTests: XCTestCase {

    private func dividedTrack(markers: [RecordMarker]?) -> LoadedTrack {
        let metadata = ConversionMetadata(
            artist: "Stan Getz", albumArtist: "Getz / Gilberto",
            album: "Getz/Gilberto", year: 1964, genre: "Bossa Nova"
        )
        let audio = AudioTrack(fileURL: URL(fileURLWithPath: "/Music/Getz Side A.aiff"),
                               title: "Side A", artist: "Stan Getz", album: "Getz/Gilberto")
        return LoadedTrack(track: audio, metadata: metadata, recordMarkers: markers)
    }

    func testEmptyForUndividedTrack() {
        XCTAssertTrue(RecordTrackPlanner.trackPlans(for: dividedTrack(markers: nil)).isEmpty)
        XCTAssertTrue(RecordTrackPlanner.trackPlans(for: dividedTrack(markers: [])).isEmpty)
    }

    func testInheritsAlbumTagsAndNumbersSequentially() {
        let track = dividedTrack(markers: [
            RecordMarker(startSeconds: 0, endSeconds: 200, title: "The Girl from Ipanema"),
            RecordMarker(startSeconds: 200, endSeconds: 400, title: "Doralice"),
            RecordMarker(startSeconds: 400, endSeconds: 600, title: "Para Machucar Meu Coração")
        ])
        let plans = RecordTrackPlanner.trackPlans(for: track)

        XCTAssertEqual(plans.count, 3)
        // Album-level tags inherited from the source file.
        XCTAssertEqual(plans[0].metadata.album, "Getz/Gilberto")
        XCTAssertEqual(plans[0].metadata.albumArtist, "Getz / Gilberto")
        XCTAssertEqual(plans[0].metadata.year, 1964)
        XCTAssertEqual(plans[0].metadata.genre, "Bossa Nova")
        // Per-track title + sequential number/total.
        XCTAssertEqual(plans.map { $0.metadata.title }, ["The Girl from Ipanema", "Doralice", "Para Machucar Meu Coração"])
        XCTAssertEqual(plans.map { $0.metadata.trackNumber }, [1, 2, 3])
        XCTAssertEqual(plans.allSatisfy { $0.metadata.trackTotal == 3 }, true)
        // Segments carried through.
        XCTAssertEqual(plans[1].startSeconds, 200, accuracy: 0.001)
        XCTAssertEqual(plans[1].endSeconds, 400, accuracy: 0.001)
    }

    func testBaseNameIsZeroPaddedNumberPlusTitle() {
        let markers = (1...12).map {
            RecordMarker(startSeconds: Double($0) * 100, endSeconds: Double($0) * 100 + 90, title: "Song \($0)")
        }
        let plans = RecordTrackPlanner.trackPlans(for: dividedTrack(markers: markers))
        XCTAssertEqual(plans.first?.baseName, "01 Song 1")
        XCTAssertEqual(plans.last?.baseName, "12 Song 12")
    }

    func testBaseMetadataOverrideIsRespected() {
        let track = dividedTrack(markers: [RecordMarker(startSeconds: 0, endSeconds: 100, title: "A")])
        let override = ConversionMetadata(album: "Custom Album", year: 2000)
        let plans = RecordTrackPlanner.trackPlans(for: track, baseMetadata: override)
        XCTAssertEqual(plans[0].metadata.album, "Custom Album")
        XCTAssertEqual(plans[0].metadata.year, 2000)
        XCTAssertEqual(plans[0].metadata.title, "A")
    }

    // MARK: - OutputPathPlanner naming via baseNameOverride

    func testBaseNameOverrideNamesSplitFilesAndAvoidsCollisions() {
        let planner = OutputPathPlanner()
        let root = URL(fileURLWithPath: "/Converted", isDirectory: true)
        let track = dividedTrack(markers: [RecordMarker(startSeconds: 0, endSeconds: 100, title: "x")])

        var reserved: Set<String> = []
        var paths: [String] = []
        // Two tracks happen to share a sanitized stem → must not collide.
        for stem in ["01 Intro", "02 Intro"] {
            let planned = planner.planDestination(
                for: track,
                preset: .genericAAC,
                destinationRoot: root,
                sourceRoot: nil,
                folderMode: .flat,
                templateConfig: FolderTemplateConfig(preset: .yearArtistAlbum,
                                                     tokenOrder: TemplatePreset.yearArtistAlbum.defaultTokenOrder),
                reservedDestinationPaths: reserved,
                baseNameOverride: stem
            )
            paths.append(planned.destinationURL.path)
            reserved.insert(planned.destinationURL.path)
        }

        XCTAssertEqual(paths[0], "/Converted/01 Intro.m4a")
        XCTAssertEqual(paths[1], "/Converted/02 Intro.m4a")
        XCTAssertNotEqual(paths[0], paths[1])
    }
}
