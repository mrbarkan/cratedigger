#if canImport(XCTest)
import AppKit
import CryptoKit
import Foundation
import XCTest
@testable import CrateDiggerCore

/// Art sizes are pixels everywhere: what a scan records, what the device
/// review predicts a transfer writes, and what the catalog patch records. A
/// DPI tag shrinks `NSImage.size` (points), which used to make every
/// DPI-tagged album read as differing in art right after a real scan.
final class DeviceArtPixelSizeTests: XCTestCase {
    private var scratch: URL!
    private var device: URL!
    /// 1400 px square, tagged 300 dpi: 336 points.
    private var coverData: Data!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceArtPixelSizeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        scratch = base.resolvingSymlinksInPath()
        device = scratch.appendingPathComponent("IPOD", isDirectory: true)
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
        coverData = try makeJPEGData(pixels: 1400, dpi: 300)
        // Precondition: the fixture really is a points/pixels case.
        let points = try XCTUnwrap(NSImage(data: coverData)).size.width
        XCTAssertLessThan(points, 1000, "fixture no longer reproduces the points/pixels divergence")
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - What a scan records

    func testScanRecordsThePixelSizeOfADPITaggedCover() async throws {
        let trackURL = try makeFile("Src/Kind of Blue/01 Track 1.flac", root: scratch)
        try coverData.write(to: trackURL.deletingLastPathComponent().appendingPathComponent("cover.jpg"))

        let resolved = await ArtworkService().resolveArtwork(trackURL: trackURL)

        XCTAssertEqual(resolved?.dimensions, ArtworkDimensions(width: 1400, height: 1400))
        XCTAssertEqual(ArtworkQuality.pixelSize(ofImageData: coverData), ArtworkDimensions(width: 1400, height: 1400))
    }

    // MARK: - Measuring what is sent

    /// The on-disk store holds 512 px thumbnails; drawing a cover from it
    /// must never pass for the full-resolution bytes a size is measured on.
    func testPixelSizesMeasureFullResolutionBytesNotStoredThumbnails() async throws {
        let sent = try librarySent(numbers: [1])
        let hash = try XCTUnwrap(sent[0].track.artworkHash)
        let store = ArtworkStore(directory: scratch.appendingPathComponent("Thumbnails"))
        _ = await ArtworkService(store: store).resolveArtwork(trackURL: sent[0].track.fileURL)
        XCTAssertTrue(store.contains(hash))

        // A fresh launch: the cover is drawn from the store first.
        let service = ArtworkService(store: store)
        let thumbnail = await service.thumbnailAsync(artworkHash: hash, maxPixel: 64)
        XCTAssertNotNil(thumbnail)

        let sizes = await service.pixelSizes(of: sent)

        XCTAssertEqual(sizes, [hash: ArtworkDimensions(width: 1400, height: 1400)])
    }

    func testPixelSizesLeaveOutArtWithNoBytesToRead() async throws {
        let audio = AudioTrack(
            fileURL: scratch.appendingPathComponent("Gone/01 Track 1.flac"),
            title: "Track 1", artist: "Miles Davis", album: "Kind of Blue", trackNumber: 1,
            artworkSource: .embedded, artworkHash: "deadbeef",
            artworkDimensions: ArtworkDimensions(width: 336, height: 336)
        )

        let sizes = await ArtworkService().pixelSizes(of: [LoadedTrack(track: audio, metadata: ConversionMetadata())])

        XCTAssertEqual(sizes, [:], "nothing to read: the caller keeps the recorded size")
    }

    // MARK: - The review

    /// The library recorded the cover in points (a record made before
    /// pixels); the device was sent it, then scanned for real. Measured, the
    /// album reads Present; trusting the recorded size it read as differing.
    func testDPITaggedAlbumIsPresentAfterARealScanOfTheDevice() async throws {
        let profile = folderArtProfile()
        let sent = try librarySent(numbers: [1, 2])
        let catalog = try await scannedDeviceCopy(of: sent, numbers: [1, 2])
        let sizes = await ArtworkService().pixelSizes(of: sent)
        let resolver = DeviceTransferResolver()

        let trusting = resolver.review(sending: sent, catalog: catalog, profile: profile, mountedAt: device, leftAlone: [])
        XCTAssertEqual(trusting.albums.map(\.status), [.differs], "precondition: the recorded points read as another size")
        XCTAssertEqual(trusting.albums.first?.differences, [.artSize])

        let measured = resolver.review(sending: sent, catalog: catalog, profile: profile, mountedAt: device,
                                       leftAlone: [], artPixelSizes: sizes)
        XCTAssertEqual(measured.albums.map(\.status), [.present])
        XCTAssertEqual(measured.albums.first?.sentArtPixels, 400)
        XCTAssertEqual(measured.albums.first?.deviceArtPixels, 400)
    }

    /// What the plan copies carries the measured size to the catalog patch,
    /// so a send followed by a review of the patched catalog reads Present.
    func testMeasuredSizesReachTheCatalogPatch() async throws {
        let profile = folderArtProfile()
        let sent = try librarySent(numbers: [1, 2])
        let sizes = await ArtworkService().pixelSizes(of: sent)
        let resolver = DeviceTransferResolver()

        let review = resolver.review(sending: sent, catalog: [], profile: profile, mountedAt: device,
                                     leftAlone: [], artPixelSizes: sizes)
        let plan = try resolver.resolve(review, decisions: [:], profile: profile, mountedAt: device)
        XCTAssertEqual(plan.copies.map(\.source.track.artworkDimensions),
                       Array(repeating: ArtworkDimensions(width: 1400, height: 1400), count: 2))

        let patched = plan.copies.map {
            DeviceCatalogStore.writtenTrack(source: $0.source, destination: $0.destinationURL, preset: nil,
                                            writesFolderCoverArt: profile.usesFolderCoverArt)
        }
        XCTAssertEqual(patched.map(\.track.artworkDimensions?.longEdge), [400, 400])
        for copy in plan.copies { try makeFile(relative(copy.destinationURL)) }

        let again = resolver.review(sending: sent, catalog: patched, profile: profile, mountedAt: device,
                                    leftAlone: [], artPixelSizes: sizes)
        XCTAssertEqual(again.albums.map(\.status), [.present])
    }

    // MARK: - Fixtures

    /// A copy-mode device that gets a folder cover, as a Rockbox player does.
    private func folderArtProfile() -> ExternalDeviceProfile {
        var profile = ExternalDeviceProfile.genericStorage(name: "Test")
        profile.transferSettings.mode = .copyOriginals
        profile.transferSettings.writesFolderCoverArt = true
        return profile
    }

    /// Library tracks with the DPI-tagged cover beside them, recorded the way
    /// a record made before pixel sizes was: the point size.
    private func librarySent(numbers: [Int]) throws -> [LoadedTrack] {
        let folder = "Src/Kind of Blue"
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent(folder), withIntermediateDirectories: true)
        try coverData.write(to: scratch.appendingPathComponent("\(folder)/cover.jpg"))
        let image = try XCTUnwrap(NSImage(data: coverData))
        let points = ArtworkDimensions(width: Int(image.size.width.rounded()), height: Int(image.size.height.rounded()))
        let hash = SHA256Hex(coverData)
        return try numbers.map { number in
            let url = try makeFile("\(folder)/0\(number) Track \(number).flac", root: scratch)
            return track(url: url, number: number, artSource: .folderImage, hash: hash, dimensions: points)
        }
    }

    /// The device copy as a scan of it reads it: the files written, the
    /// cover the transfer writes beside them, and the scan's own art record.
    private func scannedDeviceCopy(of sent: [LoadedTrack], numbers: [Int]) async throws -> [LoadedTrack] {
        let folder = device.appendingPathComponent("Music/Miles Davis/1959/Kind of Blue", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = try XCTUnwrap(sent.first?.track.artworkHash)
        let asset = ArtworkAsset(source: .folderImage, hash: source,
                                 dimensions: ArtworkDimensions(width: 1400, height: 1400), data: coverData)
        XCTAssertEqual(FolderCoverArtWriter().write([folder: asset]), 1)

        let scanner = ArtworkService()
        var tracks: [LoadedTrack] = []
        for number in numbers {
            let url = try makeFile("Music/Miles Davis/1959/Kind of Blue/0\(number) Track \(number).flac")
            let resolved = await scanner.resolveArtwork(trackURL: url)
            let art = try XCTUnwrap(resolved)
            tracks.append(track(url: url, number: number, artSource: art.source, hash: art.hash, dimensions: art.dimensions))
        }
        return tracks
    }

    private func track(url: URL, number: Int, artSource: ArtworkSource, hash: String, dimensions: ArtworkDimensions) -> LoadedTrack {
        let audio = AudioTrack(
            fileURL: url, title: "Track \(number)", artist: "Miles Davis", album: "Kind of Blue",
            formatName: "FLAC", bitrateKbps: 900, sampleRateHz: 44_100, year: 1959, trackNumber: number,
            artworkSource: artSource, artworkHash: hash, artworkDimensions: dimensions
        )
        let metadata = ConversionMetadata(title: "Track \(number)", artist: "Miles Davis", album: "Kind of Blue",
                                          trackNumber: number, year: 1959)
        return LoadedTrack(track: audio, metadata: metadata)
    }

    @discardableResult
    private func makeFile(_ relativePath: String, root: URL? = nil) throws -> URL {
        let url = (root ?? device).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }

    private func relative(_ url: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(device.path.count + 1))
    }

    private func SHA256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
