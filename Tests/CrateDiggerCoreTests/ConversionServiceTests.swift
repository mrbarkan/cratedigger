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
        XCTAssertTrue(argumentPairs(command.arguments).contains(ArgPair(flag: "-movflags", value: "use_metadata_tags")))
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

    func testCompatArtworkFailureFallsBackToAudioOnlyWithWarning() throws {
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
        XCTAssertFalse(command.arguments.contains("attached_pic"))
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
#endif
