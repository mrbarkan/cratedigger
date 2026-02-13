#if canImport(XCTest)
import AppKit
import Foundation
import XCTest
@testable import CrateDiggerCore

final class ConversionServiceTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var fakeFFmpegURL: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrateDiggerConversionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        fakeFFmpegURL = temporaryDirectory.appendingPathComponent("ffmpeg")
        let stub = "#!/bin/sh\necho ffmpeg stub\n"
        guard let stubData = stub.data(using: .utf8) else {
            throw NSError(domain: "ConversionServiceTests", code: 10)
        }
        try stubData.write(to: fakeFFmpegURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeFFmpegURL.path)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: temporaryDirectory.path) {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testIPodAACPresetBuildsLegacyFriendlyArguments() throws {
        let service = try makeService(artworkPreparer: PassThroughArtworkPreparer())
        let sourceURL = temporaryDirectory.appendingPathComponent("source.wav")
        let outputURL = temporaryDirectory.appendingPathComponent("out.m4a")

        let queued = try service.enqueue([ConversionJob(sourceURL: sourceURL, destinationURL: outputURL)], presetID: "ipod_aac_192").first!
        let command = try service.preparedCommand(for: queued)

        XCTAssertTrue(argumentPairs(command.arguments).contains(ArgPair(flag: "-c:a", value: "aac")))
        XCTAssertTrue(argumentPairs(command.arguments).contains(ArgPair(flag: "-profile:a", value: "aac_low")))
        XCTAssertTrue(argumentPairs(command.arguments).contains(ArgPair(flag: "-ar", value: "44100")))
        XCTAssertTrue(argumentPairs(command.arguments).contains(ArgPair(flag: "-ac", value: "2")))
        XCTAssertTrue(argumentPairs(command.arguments).contains(ArgPair(flag: "-b:a", value: "192k")))
        XCTAssertFalse(argumentPairs(command.arguments).contains(ArgPair(flag: "-movflags", value: "use_metadata_tags")))
    }

    func testCompatReembedPlacesMapMetadataAfterAllInputs() throws {
        let service = try makeService(artworkPreparer: PassThroughArtworkPreparer())
        let sourceURL = temporaryDirectory.appendingPathComponent("source.flac")
        let outputURL = temporaryDirectory.appendingPathComponent("out.m4a")

        let artworkData = try makeImageData()
        let artwork = ArtworkAsset(
            source: .embedded,
            hash: "embedded-artwork",
            dimensions: ArtworkDimensions(width: 500, height: 500),
            data: artworkData
        )

        let metadata = ConversionMetadata(title: "Track", artwork: artwork)
        let queued = try service.enqueue(
            [ConversionJob(sourceURL: sourceURL, destinationURL: outputURL, metadata: metadata)],
            presetID: "ipod_aac_192"
        ).first!

        let command = try service.preparedCommand(for: queued)

        XCTAssertEqual(countOccurrences(of: "-i", in: command.arguments), 2)
        XCTAssertTrue(argumentPairs(command.arguments).contains(ArgPair(flag: "-map", value: "1:v:0")))
        XCTAssertTrue(command.arguments.contains("attached_pic"))
        XCTAssertTrue(argumentPairs(command.arguments).contains(ArgPair(flag: "-disposition:v:0", value: "attached_pic")))
        XCTAssertTrue(argumentPairs(command.arguments).contains(ArgPair(flag: "-metadata:s:v:0", value: "title=Album cover")))
        XCTAssertTrue(argumentPairs(command.arguments).contains(ArgPair(flag: "-metadata:s:v:0", value: "comment=Cover (front)")))

        let mapMetadataIndex = try XCTUnwrap(command.arguments.firstIndex(of: "-map_metadata"))
        let lastInputPathIndex = try XCTUnwrap(lastInputPathIndex(in: command.arguments))
        XCTAssertGreaterThan(mapMetadataIndex, lastInputPathIndex)
        XCTAssertEqual(command.arguments.last, outputURL.path)
    }

    func testMetadataOnlyPlacesMapMetadataInOutputOptionsSection() throws {
        let service = try makeService(artworkPreparer: PassThroughArtworkPreparer())
        let sourceURL = temporaryDirectory.appendingPathComponent("source.wav")
        let outputURL = temporaryDirectory.appendingPathComponent("out.m4a")

        let metadata = ConversionMetadata(title: "Track Without Artwork")
        let queued = try service.enqueue(
            [ConversionJob(sourceURL: sourceURL, destinationURL: outputURL, metadata: metadata)],
            presetID: "ipod_aac_192"
        ).first!

        let command = try service.preparedCommand(for: queued)

        XCTAssertEqual(countOccurrences(of: "-i", in: command.arguments), 1)
        XCTAssertTrue(argumentPairs(command.arguments).contains(ArgPair(flag: "-map_metadata", value: "0")))
        XCTAssertTrue(argumentPairs(command.arguments).contains(ArgPair(flag: "-map_metadata:s:a:0", value: "0:s:a:0")))
        XCTAssertTrue(argumentPairs(command.arguments).contains(ArgPair(flag: "-map_chapters", value: "0")))

        let sourceInputIndex = try XCTUnwrap(indexOfPair(flag: "-i", value: sourceURL.path, in: command.arguments))
        let mapMetadataIndex = try XCTUnwrap(command.arguments.firstIndex(of: "-map_metadata"))
        XCTAssertGreaterThan(mapMetadataIndex, sourceInputIndex + 1)
        XCTAssertLessThan(mapMetadataIndex, command.arguments.count - 1)
    }

    func testPreserveModeUsesSourceVideoMapWithoutExtraInput() throws {
        let preservePreset = ConversionPreset(
            id: "test_preserve_artwork",
            name: "Preserve Artwork",
            outputFormat: .aac,
            bitrateKbps: 192,
            sampleRateHz: 44_100,
            channels: 2,
            constantBitrate: false,
            deviceProfile: .generic,
            tagMode: .auto,
            artworkMode: .preserve
        )

        let service = try makeService(
            artworkPreparer: PassThroughArtworkPreparer(),
            presets: ConversionPreset.defaultPresets + [preservePreset]
        )
        let sourceURL = temporaryDirectory.appendingPathComponent("source.flac")
        let outputURL = temporaryDirectory.appendingPathComponent("out-preserve.m4a")

        let queued = try service.enqueue(
            [ConversionJob(sourceURL: sourceURL, destinationURL: outputURL)],
            presetID: "test_preserve_artwork"
        ).first!
        let command = try service.preparedCommand(for: queued)

        XCTAssertEqual(countOccurrences(of: "-i", in: command.arguments), 1)
        XCTAssertTrue(argumentPairs(command.arguments).contains(ArgPair(flag: "-map", value: "0:v?")))
        XCTAssertFalse(command.arguments.contains("-vn"))

        let mapMetadataIndex = try XCTUnwrap(command.arguments.firstIndex(of: "-map_metadata"))
        let sourceInputIndex = try XCTUnwrap(indexOfPair(flag: "-i", value: sourceURL.path, in: command.arguments))
        XCTAssertGreaterThan(mapMetadataIndex, sourceInputIndex + 1)
    }

    func testIPodMP3PresetForcesID3v23AndCBRFlags() throws {
        let service = try makeService(artworkPreparer: PassThroughArtworkPreparer())
        let sourceURL = temporaryDirectory.appendingPathComponent("source.flac")
        let outputURL = temporaryDirectory.appendingPathComponent("out.mp3")

        let queued = try service.enqueue([ConversionJob(sourceURL: sourceURL, destinationURL: outputURL)], presetID: "ipod_mp3_192").first!
        let command = try service.preparedCommand(for: queued)

        XCTAssertTrue(argumentPairs(command.arguments).contains(ArgPair(flag: "-c:a", value: "libmp3lame")))
        XCTAssertTrue(argumentPairs(command.arguments).contains(ArgPair(flag: "-id3v2_version", value: "3")))
        XCTAssertTrue(argumentPairs(command.arguments).contains(ArgPair(flag: "-write_id3v1", value: "1")))
        XCTAssertTrue(argumentPairs(command.arguments).contains(ArgPair(flag: "-write_xing", value: "0")))
    }

    func testCompatArtworkFailureFallsBackToSourceArtworkStreamWithWarning() throws {
        let service = try makeService(artworkPreparer: ThrowingArtworkPreparer())

        let artworkData = try makeImageData()
        let artwork = ArtworkAsset(
            source: .embedded,
            hash: "hash",
            dimensions: ArtworkDimensions(width: 500, height: 500),
            data: artworkData
        )

        let metadata = ConversionMetadata(title: "Track", artwork: artwork)
        let sourceURL = temporaryDirectory.appendingPathComponent("source.wav")
        let outputURL = temporaryDirectory.appendingPathComponent("out.m4a")

        let queued = try service.enqueue(
            [ConversionJob(sourceURL: sourceURL, destinationURL: outputURL, metadata: metadata)],
            presetID: "ipod_aac_192"
        ).first!

        let command = try service.preparedCommand(for: queued)

        XCTAssertNotNil(command.warning)
        XCTAssertTrue(argumentPairs(command.arguments).contains(ArgPair(flag: "-map", value: "0:a:0")))
        XCTAssertTrue(argumentPairs(command.arguments).contains(ArgPair(flag: "-map", value: "0:v?")))
        XCTAssertTrue(argumentPairs(command.arguments).contains(ArgPair(flag: "-c:v", value: "copy")))
        XCTAssertTrue(argumentPairs(command.arguments).contains(ArgPair(flag: "-disposition:v:0", value: "attached_pic")))
    }

    func testCompatReembedWithoutResolvedArtworkFallsBackToSourceArtworkStream() throws {
        let service = try makeService(artworkPreparer: PassThroughArtworkPreparer())
        let sourceURL = temporaryDirectory.appendingPathComponent("source.flac")
        let outputURL = temporaryDirectory.appendingPathComponent("out-no-artwork.m4a")

        let queued = try service.enqueue(
            [ConversionJob(sourceURL: sourceURL, destinationURL: outputURL, metadata: nil)],
            presetID: "ipod_aac_192"
        ).first!

        let command = try service.preparedCommand(for: queued)

        XCTAssertEqual(countOccurrences(of: "-i", in: command.arguments), 1)
        XCTAssertTrue(argumentPairs(command.arguments).contains(ArgPair(flag: "-map", value: "0:a:0")))
        XCTAssertTrue(argumentPairs(command.arguments).contains(ArgPair(flag: "-map", value: "0:v?")))
        XCTAssertTrue(argumentPairs(command.arguments).contains(ArgPair(flag: "-c:v", value: "copy")))
        XCTAssertTrue(argumentPairs(command.arguments).contains(ArgPair(flag: "-disposition:v:0", value: "attached_pic")))
        XCTAssertFalse(command.arguments.contains("-vn"))
    }

    func testMetadataIncludesAlbumArtistAndCompilation() throws {
        let service = try makeService(artworkPreparer: PassThroughArtworkPreparer())
        let sourceURL = temporaryDirectory.appendingPathComponent("source.flac")
        let outputURL = temporaryDirectory.appendingPathComponent("out.m4a")

        let metadata = ConversionMetadata(
            title: "Track",
            artist: "Track Artist",
            albumArtist: "Album Artist",
            album: "Album",
            compilation: true
        )

        let queued = try service.enqueue(
            [ConversionJob(sourceURL: sourceURL, destinationURL: outputURL, metadata: metadata)],
            presetID: "ipod_aac_192"
        ).first!
        let command = try service.preparedCommand(for: queued)
        let pairs = argumentPairs(command.arguments)

        XCTAssertTrue(pairs.contains(ArgPair(flag: "-metadata", value: "album_artist=Album Artist")))
        XCTAssertTrue(pairs.contains(ArgPair(flag: "-metadata", value: "albumartist=Album Artist")))
        XCTAssertTrue(pairs.contains(ArgPair(flag: "-metadata", value: "compilation=1")))
    }

    func testMetadataWritesTrackDiscTotalsAndCustomTags() throws {
        let service = try makeService(artworkPreparer: PassThroughArtworkPreparer())
        let sourceURL = temporaryDirectory.appendingPathComponent("source.flac")
        let outputURL = temporaryDirectory.appendingPathComponent("out.m4a")

        let metadata = ConversionMetadata(
            albumArtist: "Album Artist",
            trackNumber: 1,
            trackTotal: 9,
            discNumber: 1,
            discTotal: 2,
            customTagPairs: [
                MetadataTagPair(key: "BARCODE", value: "4943674082957"),
                MetadataTagPair(key: "CATALOG", value: "XLCD335J"),
                MetadataTagPair(key: "ARTIST", value: "ShouldNotOverrideCanonical")
            ]
        )

        let queued = try service.enqueue(
            [ConversionJob(sourceURL: sourceURL, destinationURL: outputURL, metadata: metadata)],
            presetID: "ipod_aac_192"
        ).first!
        let command = try service.preparedCommand(for: queued)
        let pairs = argumentPairs(command.arguments)

        XCTAssertTrue(pairs.contains(ArgPair(flag: "-metadata", value: "track=1/9")))
        XCTAssertTrue(pairs.contains(ArgPair(flag: "-metadata", value: "disc=1/2")))
        XCTAssertTrue(pairs.contains(ArgPair(flag: "-metadata", value: "BARCODE=4943674082957")))
        XCTAssertTrue(pairs.contains(ArgPair(flag: "-metadata", value: "CATALOG=XLCD335J")))
        XCTAssertFalse(pairs.contains(ArgPair(flag: "-metadata", value: "ARTIST=ShouldNotOverrideCanonical")))
    }

    func testCompatArtworkResizeOptionPassesMaxDimensionToArtworkPreparer() throws {
        let artworkData = try makeImageData()
        let artwork = ArtworkAsset(
            source: .embedded,
            hash: "artwork-resize",
            dimensions: ArtworkDimensions(width: 1000, height: 1000),
            data: artworkData
        )
        let metadata = ConversionMetadata(title: "Track", artwork: artwork)

        let resizePreset = ConversionPreset(
            id: "test_resize_artwork",
            name: "Resize Artwork",
            outputFormat: .aac,
            bitrateKbps: 192,
            sampleRateHz: 44_100,
            channels: 2,
            constantBitrate: false,
            deviceProfile: .generic,
            tagMode: .auto,
            artworkMode: .compatReembed,
            artworkMaxDimension: 300
        )

        let recorder = RecordingArtworkPreparer()
        let service = try makeService(
            artworkPreparer: recorder,
            presets: ConversionPreset.defaultPresets + [resizePreset]
        )
        let sourceURL = temporaryDirectory.appendingPathComponent("source.flac")
        let outputURL = temporaryDirectory.appendingPathComponent("out.m4a")

        let queued = try service.enqueue(
            [ConversionJob(sourceURL: sourceURL, destinationURL: outputURL, metadata: metadata)],
            presetID: "test_resize_artwork"
        ).first!
        _ = try service.preparedCommand(for: queued)

        XCTAssertEqual(recorder.recordedMaxDimension, 300)
    }

    func testMetadataPreservationDoesNotOverrideCoreTagsWithPartialValues() throws {
        let service = try makeService(artworkPreparer: PassThroughArtworkPreparer())
        let sourceURL = temporaryDirectory.appendingPathComponent("source.flac")
        let outputURL = temporaryDirectory.appendingPathComponent("out.m4a")

        let metadata = ConversionMetadata(
            title: "Track",
            artist: "Track Artist",
            albumArtist: "Album Artist",
            album: "Album",
            trackNumber: 1,
            discNumber: 1,
            year: 2008,
            genre: "Electronic",
            comment: "Test Comment",
            compilation: false
        )

        let queued = try service.enqueue(
            [ConversionJob(sourceURL: sourceURL, destinationURL: outputURL, metadata: metadata)],
            presetID: "ipod_aac_192"
        ).first!
        let command = try service.preparedCommand(for: queued)
        let pairs = argumentPairs(command.arguments)

        XCTAssertFalse(pairs.contains(ArgPair(flag: "-metadata", value: "title=Track")))
        XCTAssertFalse(pairs.contains(ArgPair(flag: "-metadata", value: "artist=Track Artist")))
        XCTAssertFalse(pairs.contains(ArgPair(flag: "-metadata", value: "album=Album")))
        XCTAssertFalse(pairs.contains(ArgPair(flag: "-metadata", value: "track=1")))
        XCTAssertFalse(pairs.contains(ArgPair(flag: "-metadata", value: "disc=1")))
        XCTAssertFalse(pairs.contains(ArgPair(flag: "-metadata", value: "date=2008")))
        XCTAssertFalse(pairs.contains(ArgPair(flag: "-metadata", value: "genre=Electronic")))
        XCTAssertFalse(pairs.contains(ArgPair(flag: "-metadata", value: "comment=Test Comment")))
    }

    func testGenericAACAutoTagModeDoesNotUseMDTAFlag() throws {
        let service = try makeService(artworkPreparer: PassThroughArtworkPreparer())
        let sourceURL = temporaryDirectory.appendingPathComponent("source.wav")
        let outputURL = temporaryDirectory.appendingPathComponent("out.m4a")

        let queued = try service.enqueue(
            [ConversionJob(sourceURL: sourceURL, destinationURL: outputURL)],
            preset: .genericAAC
        ).first!
        let command = try service.preparedCommand(for: queued)

        XCTAssertFalse(argumentPairs(command.arguments).contains(ArgPair(flag: "-movflags", value: "use_metadata_tags")))
    }

    func testEnqueueAllowsDeviceProfileOverride() throws {
        let service = try makeService(artworkPreparer: PassThroughArtworkPreparer())
        let sourceURL = temporaryDirectory.appendingPathComponent("source.wav")
        let outputURL = temporaryDirectory.appendingPathComponent("out.m4a")

        let queued = try service.enqueue(
            [ConversionJob(sourceURL: sourceURL, destinationURL: outputURL)],
            presetID: "ipod_aac_192",
            deviceProfile: .generic
        )

        XCTAssertEqual(queued.first?.preset.deviceProfile, .generic)
    }

    func testRunQueuedJobsProgressCallbackReportsCountsSerial() throws {
        let service = try makeService(artworkPreparer: PassThroughArtworkPreparer())
        let jobs = makeJobs(count: 3)
        _ = service.enqueue(jobs, preset: .ipodAAC(bitrate: 192))

        var callbacks: [(processed: Int, total: Int)] = []
        let results = service.runQueuedJobs(maxConcurrentWorkers: 1) { _, processedCount, totalCount in
            callbacks.append((processedCount, totalCount))
        }

        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(callbacks.count, 3)
        XCTAssertEqual(callbacks.map(\.processed), [1, 2, 3])
        XCTAssertEqual(Set(callbacks.map(\.total)), [3])
    }

    func testRunQueuedJobsProgressCallbackReportsCountsParallel() throws {
        let service = try makeService(artworkPreparer: PassThroughArtworkPreparer())
        let jobs = makeJobs(count: 5)
        _ = service.enqueue(jobs, preset: .ipodAAC(bitrate: 192))

        let callbackLock = NSLock()
        var callbacks: [(processed: Int, total: Int)] = []
        let results = service.runQueuedJobs(maxConcurrentWorkers: 3) { _, processedCount, totalCount in
            callbackLock.lock()
            callbacks.append((processedCount, totalCount))
            callbackLock.unlock()
        }

        XCTAssertEqual(results.count, 5)
        XCTAssertEqual(callbacks.count, 5)
        XCTAssertEqual(Set(callbacks.map(\.processed)), Set(1...5))
        XCTAssertEqual(Set(callbacks.map(\.total)), [5])
    }

    private func makeService(
        artworkPreparer: ArtworkPreparing,
        presets: [ConversionPreset] = ConversionPreset.defaultPresets
    ) throws -> ConversionService {
        try ConversionService(
            ffmpegExecutableURL: fakeFFmpegURL,
            presets: presets,
            artworkPreparer: artworkPreparer,
            commandRunner: StubCommandRunner(),
            fileManager: FileManager.default
        )
    }

    private func argumentPairs(_ args: [String]) -> Set<ArgPair> {
        var pairs: Set<ArgPair> = []
        guard args.count > 1 else {
            return pairs
        }

        for index in 0..<(args.count - 1) where args[index].hasPrefix("-") {
            let next = args[index + 1]
            if !next.hasPrefix("-") {
                pairs.insert(ArgPair(flag: args[index], value: next))
            }
        }

        return pairs
    }

    private func countOccurrences(of token: String, in args: [String]) -> Int {
        args.filter { $0 == token }.count
    }

    private func indexOfPair(flag: String, value: String, in args: [String]) -> Int? {
        guard args.count > 1 else {
            return nil
        }

        for index in 0..<(args.count - 1) {
            if args[index] == flag && args[index + 1] == value {
                return index
            }
        }

        return nil
    }

    private func lastInputPathIndex(in args: [String]) -> Int? {
        guard args.count > 1 else {
            return nil
        }

        var lastPathIndex: Int?
        for index in 0..<(args.count - 1) where args[index] == "-i" {
            lastPathIndex = index + 1
        }

        return lastPathIndex
    }

    private func makeImageData() throws -> Data {
        let image = NSImage(size: NSSize(width: 500, height: 500))
        image.lockFocus()
        NSColor.orange.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 500, height: 500)).fill()
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        else {
            throw NSError(domain: "ConversionServiceTests", code: 2)
        }

        return jpeg
    }

    private func makeJobs(count: Int) -> [ConversionJob] {
        (0..<count).map { index in
            let sourceURL = temporaryDirectory.appendingPathComponent("source-\(index).wav")
            let outputURL = temporaryDirectory.appendingPathComponent("out-\(index).m4a")
            return ConversionJob(sourceURL: sourceURL, destinationURL: outputURL)
        }
    }
}

private struct ArgPair: Hashable {
    let flag: String
    let value: String
}

private struct StubCommandRunner: CommandRunning {
    func run(executableURL: URL, arguments: [String]) throws -> CommandOutput {
        CommandOutput(terminationStatus: 0, standardOutput: "ok", standardError: "")
    }
}

private struct PassThroughArtworkPreparer: ArtworkPreparing {
    func prepareCompatibleArtwork(asset: ArtworkAsset, profile: DeviceProfile) throws -> ArtworkAsset {
        asset
    }
}

private struct ThrowingArtworkPreparer: ArtworkPreparing {
    func prepareCompatibleArtwork(asset: ArtworkAsset, profile: DeviceProfile) throws -> ArtworkAsset {
        throw NSError(domain: "ConversionServiceTests", code: 3)
    }
}

private final class RecordingArtworkPreparer: ArtworkPreparing {
    var recordedMaxDimension: Int?

    func prepareCompatibleArtwork(asset: ArtworkAsset, profile: DeviceProfile) throws -> ArtworkAsset {
        asset
    }

    func prepareCompatibleArtwork(asset: ArtworkAsset, profile: DeviceProfile, maxDimension: Int?) throws -> ArtworkAsset {
        recordedMaxDimension = maxDimension
        return asset
    }
}
#endif
