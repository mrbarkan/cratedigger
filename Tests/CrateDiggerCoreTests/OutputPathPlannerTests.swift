#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class OutputPathPlannerTests: XCTestCase {
    func testSourceRelativePreservesNestedFolders() {
        let planner = OutputPathPlanner()
        let destinationRoot = URL(fileURLWithPath: "/Converted", isDirectory: true)
        let sourceRoot = URL(fileURLWithPath: "/Music", isDirectory: true)
        let loadedTrack = makeLoadedTrack(
            fileURL: URL(fileURLWithPath: "/Music/Artist/Album/Track 01.flac"),
            artist: "Artist",
            album: "Album",
            year: 2001
        )

        let planned = planner.planDestination(
            for: loadedTrack,
            preset: .genericAAC,
            destinationRoot: destinationRoot,
            sourceRoot: sourceRoot,
            folderMode: .sourceRelative,
            templateConfig: FolderTemplateConfig(preset: .yearArtistAlbum, tokenOrder: TemplatePreset.yearArtistAlbum.defaultTokenOrder)
        )

        XCTAssertEqual(planned.destinationURL.path, "/Converted/Artist/Album/Track 01.m4a")
        XCTAssertEqual(planned.relativeSubpath, "Artist/Album")
    }

    func testMetadataTemplateUsesConfiguredTokenOrder() {
        let planner = OutputPathPlanner()
        let loadedTrack = makeLoadedTrack(
            fileURL: URL(fileURLWithPath: "/Music/Loose Track.flac"),
            artist: "Boards of Canada",
            album: "Music Has the Right to Children",
            year: 1998
        )

        let planned = planner.planDestination(
            for: loadedTrack,
            preset: .genericAAC,
            destinationRoot: URL(fileURLWithPath: "/Converted", isDirectory: true),
            sourceRoot: nil,
            folderMode: .metadataTemplate,
            templateConfig: FolderTemplateConfig(
                preset: .custom,
                tokenOrder: [.year, .albumArtist, .album, .disabled, .disabled]
            )
        )

        XCTAssertEqual(planned.relativeSubpath, "1998/Boards of Canada/Music Has the Right to Children")
        XCTAssertEqual(planned.destinationURL.path, "/Converted/1998/Boards of Canada/Music Has the Right to Children/Loose Track.m4a")
    }

    func testCollisionHandlingAppendsNumericSuffixes() throws {
        try withTemporaryDirectory(prefix: "CrateDiggerOutputPlannerTests") { temporaryDirectory in
            let planner = OutputPathPlanner(fileManager: .default)
            let destinationRoot = temporaryDirectory.appendingPathComponent("Converted", isDirectory: true)
            try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

            let existingFile = destinationRoot.appendingPathComponent("Track 01.m4a")
            FileManager.default.createFile(atPath: existingFile.path, contents: Data())

            let loadedTrack = makeLoadedTrack(
                fileURL: temporaryDirectory.appendingPathComponent("Track 01.flac"),
                artist: "Artist",
                album: "Album",
                year: 2004
            )

            let planned = planner.planDestination(
                for: loadedTrack,
                preset: .genericAAC,
                destinationRoot: destinationRoot,
                sourceRoot: nil,
                folderMode: .flat,
                templateConfig: FolderTemplateConfig(preset: .yearArtistAlbum, tokenOrder: TemplatePreset.yearArtistAlbum.defaultTokenOrder),
                reservedDestinationPaths: [destinationRoot.appendingPathComponent("Track 01 (2).m4a").path]
            )

            XCTAssertEqual(planned.destinationURL.lastPathComponent, "Track 01 (3).m4a")
        }
    }

    func testCollisionHandlingIsCaseInsensitive() {
        // APFS destinations are case-insensitive by default: "Mix.m4a" and
        // "MIX.m4a" are the same file, so the second output must step aside.
        let planner = OutputPathPlanner()
        let destinationRoot = URL(fileURLWithPath: "/Converted", isDirectory: true)
        let templateConfig = FolderTemplateConfig(preset: .yearArtistAlbum, tokenOrder: TemplatePreset.yearArtistAlbum.defaultTokenOrder)

        let first = planner.planDestination(
            for: makeLoadedTrack(fileURL: URL(fileURLWithPath: "/Music/Mix.flac"), artist: "Artist", album: "Album", year: 2001),
            preset: .genericAAC,
            destinationRoot: destinationRoot,
            sourceRoot: nil,
            folderMode: .flat,
            templateConfig: templateConfig
        )
        XCTAssertEqual(first.destinationURL.lastPathComponent, "Mix.m4a")

        // Reserve the first path exactly the way the conversion/transfer callers do.
        let reserved: Set<String> = [first.destinationURL.standardizedFileURL.resolvingSymlinksInPath().path]
        let second = planner.planDestination(
            for: makeLoadedTrack(fileURL: URL(fileURLWithPath: "/Music/MIX.flac"), artist: "Artist", album: "Album", year: 2001),
            preset: .genericAAC,
            destinationRoot: destinationRoot,
            sourceRoot: nil,
            folderMode: .flat,
            templateConfig: templateConfig,
            reservedDestinationPaths: reserved
        )

        XCTAssertEqual(second.destinationURL.lastPathComponent, "MIX (2).m4a")
    }

    func testDotDotMetadataComponentCannotEscapeOutputRoot() {
        // A track tagged with album-artist ".." must not traverse above the
        // chosen destination root in metadataTemplate mode.
        let planner = OutputPathPlanner()
        let loadedTrack = makeLoadedTrack(
            fileURL: URL(fileURLWithPath: "/Music/Track 01.flac"),
            artist: "..",
            album: "Album",
            year: 2001
        )

        let planned = planner.planDestination(
            for: loadedTrack,
            preset: .genericAAC,
            destinationRoot: URL(fileURLWithPath: "/Converted", isDirectory: true),
            sourceRoot: nil,
            folderMode: .metadataTemplate,
            templateConfig: FolderTemplateConfig(preset: .artistYearAlbum, tokenOrder: TemplatePreset.artistYearAlbum.defaultTokenOrder)
        )

        XCTAssertEqual(planned.destinationURL.path, "/Converted/Unknown Artist/2001/Album/Track 01.m4a")
        XCTAssertFalse(planned.destinationURL.path.contains(".."))
    }

    func testSanitizerRejectsDotComponentsAndHiddenNames() {
        XCTAssertEqual(PathComponentSanitizer.sanitize(".", fallback: "Fallback"), "Fallback")
        XCTAssertEqual(PathComponentSanitizer.sanitize("..", fallback: "Fallback"), "Fallback")
        XCTAssertEqual(PathComponentSanitizer.sanitize(". .", fallback: "Fallback"), "Fallback")
        XCTAssertEqual(PathComponentSanitizer.sanitize(".hidden", fallback: "Fallback"), "hidden")
    }
}

private func makeLoadedTrack(
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
