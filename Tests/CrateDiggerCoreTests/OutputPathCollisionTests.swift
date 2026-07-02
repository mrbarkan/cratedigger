#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class OutputPathCollisionTests: XCTestCase {
    private func makeTempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cd-collision-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func track(named name: String, in dir: URL) -> LoadedTrack {
        LoadedTrack(
            track: AudioTrack(fileURL: dir.appendingPathComponent("\(name).flac"),
                              title: name, artist: "A", album: "B",
                              durationSeconds: 1, formatName: "FLAC"),
            metadata: ConversionMetadata(title: name, artist: "A", album: "B")
        )
    }

    func testAvoidExistingTrueStepsPastExistingFile() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let planner = OutputPathPlanner()
        let loaded = track(named: "Song", in: dir)

        // First plan → "Song.mp3"; create it on disk.
        let first = planner.planDestination(
            for: loaded, preset: .genericAAC, destinationRoot: dir, sourceRoot: dir,
            folderMode: .flat, templateConfig: FolderTemplateConfig(preset: .custom, tokenOrder: [])
        )
        XCTAssertEqual(first.destinationURL.deletingPathExtension().lastPathComponent, "Song")
        FileManager.default.createFile(atPath: first.destinationURL.path, contents: Data())

        // avoidExistingFiles: true → steps to "Song (2).mp3" (keep-both).
        let keepBoth = planner.planDestination(
            for: loaded, preset: .genericAAC, destinationRoot: dir, sourceRoot: dir,
            folderMode: .flat, templateConfig: FolderTemplateConfig(preset: .custom, tokenOrder: []),
            avoidExistingFiles: true
        )
        XCTAssertEqual(keepBoth.destinationURL.deletingPathExtension().lastPathComponent, "Song (2)")

        // avoidExistingFiles: false → canonical "Song.mp3" (so caller can skip/overwrite).
        let canonical = planner.planDestination(
            for: loaded, preset: .genericAAC, destinationRoot: dir, sourceRoot: dir,
            folderMode: .flat, templateConfig: FolderTemplateConfig(preset: .custom, tokenOrder: []),
            avoidExistingFiles: false
        )
        XCTAssertEqual(canonical.destinationURL.deletingPathExtension().lastPathComponent, "Song")
    }

    func testWithinBatchCollisionStillUniquifiedWhenNotAvoidingDisk() {
        // Two batch jobs to the same name must still differ even with
        // avoidExistingFiles: false (reserved-path uniquification).
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let planner = OutputPathPlanner()
        let loaded = track(named: "Dup", in: dir)

        let a = planner.planDestination(
            for: loaded, preset: .genericAAC, destinationRoot: dir, sourceRoot: dir,
            folderMode: .flat, templateConfig: FolderTemplateConfig(preset: .custom, tokenOrder: []),
            avoidExistingFiles: false
        )
        let reserved: Set<String> = [a.destinationURL.standardizedFileURL.resolvingSymlinksInPath().path]
        let b = planner.planDestination(
            for: loaded, preset: .genericAAC, destinationRoot: dir, sourceRoot: dir,
            folderMode: .flat, templateConfig: FolderTemplateConfig(preset: .custom, tokenOrder: []),
            reservedDestinationPaths: reserved, avoidExistingFiles: false
        )
        XCTAssertEqual(a.destinationURL.deletingPathExtension().lastPathComponent, "Dup")
        XCTAssertEqual(b.destinationURL.deletingPathExtension().lastPathComponent, "Dup (2)")
    }
}
#endif
