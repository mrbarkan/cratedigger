import AppKit
import XCTest
@testable import CrateDiggerCore

final class FolderCoverArtWriterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cover-art-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A 1000 px red PNG — bigger than the sidecar limit, and a format the
    /// writer has to re-encode.
    private func sourceArtwork(size: Int = 1000) throws -> ArtworkAsset {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        return ArtworkAsset(
            source: .embedded,
            hash: "test",
            dimensions: ArtworkDimensions(width: size, height: size),
            data: png
        )
    }

    func testWritesOneBaselineJPEGPerFolder() throws {
        let albumA = root.appendingPathComponent("Album A", isDirectory: true)
        let albumB = root.appendingPathComponent("Album B", isDirectory: true)
        for folder in [albumA, albumB] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let artwork = try sourceArtwork()

        let written = FolderCoverArtWriter().write([albumA: artwork, albumB: artwork])

        XCTAssertEqual(written, 2)
        for folder in [albumA, albumB] {
            let cover = folder.appendingPathComponent("cover.jpg")
            let data = try Data(contentsOf: cover)
            XCTAssertEqual(data.prefix(2), Data([0xFF, 0xD8]), "not a JPEG")
            XCTAssertFalse(Self.isProgressive(data), "Rockbox can't decode progressive JPEG")
            let image = try XCTUnwrap(NSImage(data: data))
            XCTAssertLessThanOrEqual(Int(image.size.width), FolderCoverArtWriter.defaultMaxDimension)
            XCTAssertLessThanOrEqual(Int(image.size.height), FolderCoverArtWriter.defaultMaxDimension)
            XCTAssertEqual(Self.componentCount(data), 3, "cover must stay colour, not luma-only")
        }
    }

    func testSkipsFoldersThatDoNotExistAndEmptyArtwork() throws {
        let missing = root.appendingPathComponent("Never Written", isDirectory: true)
        let real = root.appendingPathComponent("Real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let empty = ArtworkAsset(source: .embedded, hash: "x",
                                 dimensions: ArtworkDimensions(width: 0, height: 0), data: Data())

        let written = FolderCoverArtWriter().write([missing: try sourceArtwork(), real: empty])

        XCTAssertEqual(written, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: real.appendingPathComponent("cover.jpg").path))
    }

    func testReplacesACoverAlreadyThere() throws {
        let album = root.appendingPathComponent("Album", isDirectory: true)
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        let cover = album.appendingPathComponent("cover.jpg")
        try Data("stale".utf8).write(to: cover)

        XCTAssertEqual(FolderCoverArtWriter().write([album: try sourceArtwork()]), 1)
        XCTAssertNotEqual(try Data(contentsOf: cover), Data("stale".utf8))
    }

    // MARK: - Representative audio file per folder

    func testPicksOneAudioFilePerFolderInNameOrder() throws {
        let fm = FileManager.default
        let albumA = root.appendingPathComponent("Artist/Album A", isDirectory: true)
        let albumB = root.appendingPathComponent("Artist/Album B", isDirectory: true)
        for folder in [albumA, albumB] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        for name in ["02 - Second.m4a", "01 - First.m4a", "cover.jpg", "notes.txt"] {
            try Data("x".utf8).write(to: albumA.appendingPathComponent(name))
        }
        try Data("x".utf8).write(to: albumB.appendingPathComponent("01 - Only.flac"))
        // AppleDouble twin macOS leaves on FAT devices — must never be chosen.
        try Data("x".utf8).write(to: albumB.appendingPathComponent("._01 - Only.flac"))

        // Compared by resolved path: the enumerator hands back the temp dir as
        // /private/var, and folder URLs built with `isDirectory: true` carry a
        // trailing slash — neither difference matters to a caller, which just
        // appends cover.jpg to the URL it was given.
        let found = Dictionary(
            uniqueKeysWithValues: FolderCoverArtWriter.representativeAudioFiles(under: root)
                .map { ($0.key.resolvingSymlinksInPath().path, $0.value.lastPathComponent) }
        )

        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found[albumA.resolvingSymlinksInPath().path], "01 - First.m4a")
        XCTAssertEqual(found[albumB.resolvingSymlinksInPath().path], "01 - Only.flac")
    }

    func testIgnoresFoldersWithNoAudio() throws {
        let art = root.appendingPathComponent("Scans", isDirectory: true)
        try FileManager.default.createDirectory(at: art, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: art.appendingPathComponent("back.jpg"))

        XCTAssertTrue(FolderCoverArtWriter.representativeAudioFiles(under: root).isEmpty)
    }

    // MARK: - JPEG marker helpers

    /// SOF2 = progressive; SOF0/SOF1 = baseline/extended sequential.
    private static func isProgressive(_ data: Data) -> Bool {
        frameHeader(data)?.marker == 0xC2
    }

    private static func componentCount(_ data: Data) -> Int? {
        frameHeader(data)?.components
    }

    private static func frameHeader(_ data: Data) -> (marker: UInt8, components: Int)? {
        let bytes = [UInt8](data)
        var i = 2
        while i + 3 < bytes.count, bytes[i] == 0xFF {
            let marker = bytes[i + 1]
            if marker == 0xDA { return nil }   // start of scan — no frame header found
            let length = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            if (0xC0...0xC3).contains(marker), i + 9 < bytes.count {
                return (marker, Int(bytes[i + 9]))
            }
            i += 2 + length
        }
        return nil
    }
}
