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

    func testSecondRunWritesNothing() throws {
        let album = root.appendingPathComponent("Album", isDirectory: true)
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        let cover = album.appendingPathComponent("cover.jpg")
        let artwork = try sourceArtwork()
        XCTAssertEqual(FolderCoverArtWriter().write([album: artwork]), 1)
        let past = Date(timeIntervalSinceNow: -3600)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: cover.path)

        XCTAssertEqual(FolderCoverArtWriter().write([album: artwork]), 0, "the same bytes are not written again")

        let date = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: cover.path)[.modificationDate] as? Date)
        XCTAssertEqual(date.timeIntervalSince1970, past.timeIntervalSince1970, accuracy: 1)
    }

    func testNoTemporaryFileLeftInFolder() throws {
        let album = root.appendingPathComponent("Album", isDirectory: true)
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: album.appendingPathComponent("cover.jpg"))

        XCTAssertEqual(FolderCoverArtWriter().write([album: try sourceArtwork()]), 1)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: album.path), ["cover.jpg"])
    }

    func testDeviceWriterGetsEveryCoverAndCountsOnlyChanges() throws {
        let albumA = root.appendingPathComponent("Album A", isDirectory: true)
        let albumB = root.appendingPathComponent("Album B", isDirectory: true)
        for folder in [albumA, albumB] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        var asked: [URL] = []
        let writer = FolderCoverArtWriter(writeData: { data, url in
            XCTAssertEqual(data.prefix(2), Data([0xFF, 0xD8]))
            asked.append(url)
            return url.deletingLastPathComponent().lastPathComponent == "Album A"   // B was already there
        })

        XCTAssertEqual(writer.write([albumA: try sourceArtwork(), albumB: try sourceArtwork()]), 1)
        XCTAssertEqual(Set(asked.map(\.lastPathComponent)), ["cover.jpg"])
        XCTAssertEqual(asked.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: albumA.appendingPathComponent("cover.jpg").path),
                       "only the given writer writes")
    }

    func testAFailedCoverIsSkipped() throws {
        let album = root.appendingPathComponent("Album", isDirectory: true)
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        let writer = FolderCoverArtWriter(writeData: { _, _ in
            throw DeviceTransferDoorError.forbidden("a name ending in a dot or a space")
        })
        XCTAssertEqual(writer.write([album: try sourceArtwork()]), 0)
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

    // MARK: - Cover guarantees (PodBox phase 2)

    /// Seeded noise: the worst case for JPEG size.
    private func noiseArtwork(size: Int) throws -> ArtworkAsset {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        for i in bytes.indices where i % 4 != 3 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            bytes[i] = UInt8(truncatingIfNeeded: state >> 33)
        }
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32))
        bytes.withUnsafeBufferPointer { rep.bitmapData!.update(from: $0.baseAddress!, count: $0.count) }
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        return ArtworkAsset(source: .embedded, hash: "noise", dimensions: ArtworkDimensions(width: size, height: size),
                            data: png)
    }

    /// A progressive JPEG in, a baseline JPEG out: the player's decoder
    /// handles baseline only.
    func testCoverIsBaselineJPEG() throws {
        let image = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(sourceArtwork(size: 800).data)))
        let progressive = try XCTUnwrap(image.representation(using: .jpeg, properties: [.progressive: true]))
        XCTAssertTrue(Self.isProgressive(progressive), "the input must really be progressive")
        let folder = root.appendingPathComponent("Album", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let source = ArtworkAsset(source: .embedded, hash: "progressive",
                                  dimensions: ArtworkDimensions(width: 800, height: 800), data: progressive)
        XCTAssertEqual(FolderCoverArtWriter().write([folder: source]), 1)
        let cover = try Data(contentsOf: folder.appendingPathComponent("cover.jpg"))
        XCTAssertEqual(cover.prefix(2), Data([0xFF, 0xD8]))
        XCTAssertFalse(Self.isProgressive(cover))
        XCTAssertFalse(cover.contains(Data([0xFF, 0xC2])), "no progressive frame marker anywhere")
    }

    func testCoverFromNoiseSourceIsUnder512KB() throws {
        let folder = root.appendingPathComponent("Noise", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(FolderCoverArtWriter().write([folder: try noiseArtwork(size: 2_000)]), 1)
        let cover = try Data(contentsOf: folder.appendingPathComponent("cover.jpg"))
        XCTAssertLessThanOrEqual(cover.count, 512 * 1024)
        XCTAssertFalse(Self.isProgressive(cover))
    }

    // MARK: - JPEG marker helpers

    /// SOF2 = progressive; SOF0/SOF1 = baseline/extended sequential.
    // MARK: - Ordinary conversions

    private let kindOfBlue = AlbumFolderKey(artistBucket: "Miles Davis", album: "Kind of Blue", year: "1959")
    private let bitchesBrew = AlbumFolderKey(artistBucket: "Miles Davis", album: "Bitches Brew", year: "1970")

    private func landing(_ folder: String, _ album: AlbumFolderKey, art: ArtworkAsset?) -> FolderCoverArtWriter.ConversionLanding {
        FolderCoverArtWriter.ConversionLanding(folder: root.appendingPathComponent(folder, isDirectory: true),
                                               album: album, artwork: art)
    }

    func testConversionCoversOneAlbumFolderEach() throws {
        let art = try sourceArtwork()
        let landed = [
            landing("Miles Davis/Kind of Blue", kindOfBlue, art: art),
            landing("Miles Davis/Kind of Blue", kindOfBlue, art: art),
            landing("Miles Davis/Bitches Brew", bitchesBrew, art: nil),
            landing("Miles Davis/Bitches Brew", bitchesBrew, art: art)
        ]

        let covers = FolderCoverArtWriter.conversionCovers(
            landed: landed, planned: landed, destinationRoot: root, folderMode: .metadataTemplate, hasCover: { _ in false }
        )

        XCTAssertEqual(Set(covers.keys.map(\.lastPathComponent)), ["Kind of Blue", "Bitches Brew"])
    }

    /// The user's own cover.jpg is never replaced by an ordinary conversion.
    func testConversionNeverReplacesACoverAlreadyThere() throws {
        let art = try sourceArtwork()
        let folder = root.appendingPathComponent("Miles Davis/Kind of Blue", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: folder.appendingPathComponent("cover.jpg"))
        let landed = [landing("Miles Davis/Kind of Blue", kindOfBlue, art: art)]

        let covers = FolderCoverArtWriter.conversionCovers(
            landed: landed, planned: landed, destinationRoot: root, folderMode: .metadataTemplate,
            hasCover: { FolderCoverArtWriter.hasCover(in: $0) }
        )

        XCTAssertTrue(covers.isEmpty)
    }

    func testConversionSkipsTheFlatRootAndFoldersHoldingSeveralAlbums() throws {
        let art = try sourceArtwork()
        let flat = [landing("", kindOfBlue, art: art)]
        XCTAssertTrue(FolderCoverArtWriter.conversionCovers(
            landed: flat, planned: flat, destinationRoot: root, folderMode: .flat, hasCover: { _ in false }
        ).isEmpty, "flat mode: every album lands in the root")

        // Source-relative into one folder: two albums share it. Bitches Brew
        // failed to convert but still names the folder as shared.
        let landed = [landing("Mixed", kindOfBlue, art: art)]
        let planned = landed + [landing("Mixed", bitchesBrew, art: art)]
        XCTAssertTrue(FolderCoverArtWriter.conversionCovers(
            landed: landed, planned: planned, destinationRoot: root, folderMode: .sourceRelative, hasCover: { _ in false }
        ).isEmpty)
    }

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
