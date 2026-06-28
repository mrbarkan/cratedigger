#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

final class RealisticScenariosTests: XCTestCase {
    
    // MARK: - Mocks & Helpers
    
    class MockMetadataProbe: MetadataProbing {
        var mockedMetadata: [URL: ProbedMetadata] = [:]
        func probe(url: URL) throws -> ProbedMetadata {
            let standardURL = url.standardizedFileURL.resolvingSymlinksInPath()
            if let metadata = mockedMetadata[standardURL] {
                return metadata
            }
            if let matchingPair = mockedMetadata.first(where: { $0.key.lastPathComponent == url.lastPathComponent }) {
                return matchingPair.value
            }
            return ProbedMetadata(formatTags: [:], streams: [])
        }
    }
    
    class MockCommandRunner: CommandRunning {
        var runCalls: [(executableURL: URL, arguments: [String])] = []
        var nextOutput: CommandOutput = CommandOutput(terminationStatus: 0, standardOutput: "", standardError: "")
        
        func run(executableURL: URL, arguments: [String]) throws -> CommandOutput {
            runCalls.append((executableURL, arguments))
            return nextOutput
        }
    }
    
    class PassThroughArtworkPreparer: ArtworkPreparing {
        func prepareCompatibleArtwork(asset: ArtworkAsset, profile: DeviceProfile) throws -> ArtworkAsset {
            return asset
        }
    }
    
    // Mock URLProtocol for Subsonic API testing
    class MockURLProtocol: URLProtocol {
        static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data?))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override class func requestIsCacheEquivalent(_ a: URLRequest, to b: URLRequest) -> Bool { false }
        override func stopLoading() {}

        override func startLoading() {
            guard let handler = MockURLProtocol.requestHandler else {
                XCTFail("MockURLProtocol.requestHandler is not set")
                return
            }
            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if let data = data {
                    client?.urlProtocol(self, didLoad: data)
                }
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    // MARK: - Scenario 1: Scan & Index
    func testScenario1_ScanAndBuildIndex() async throws {
        try await withTemporaryDirectory(prefix: "Scenario1") { tempDir in
            let fileManager = FileManager.default
            
            // Create dummy files
            let track1URL = tempDir.appendingPathComponent("track1.mp3")
            let track2URL = tempDir.appendingPathComponent("track2.flac")
            let track3URL = tempDir.appendingPathComponent("track3.m4a")
            
            try "dummy mp3".write(to: track1URL, atomically: true, encoding: .utf8)
            try "dummy flac".write(to: track2URL, atomically: true, encoding: .utf8)
            try "dummy m4a".write(to: track3URL, atomically: true, encoding: .utf8)
            
            // Set up mock metadata probe with standardized URLs
            let mockProbe = MockMetadataProbe()
            mockProbe.mockedMetadata[track1URL.standardizedFileURL.resolvingSymlinksInPath()] = ProbedMetadata(
                formatTags: ["artist": "Boards of Canada", "album": "Music Has the Right to Children", "title": "Wildlife Analysis", "track": "01", "disc": "1"],
                streams: [ProbedStreamMetadata(index: 0, codecType: "audio", codecName: "mp3", tags: [:], dispositions: [:])]
            )
            mockProbe.mockedMetadata[track2URL.standardizedFileURL.resolvingSymlinksInPath()] = ProbedMetadata(
                formatTags: ["artist": "Boards of Canada", "album": "Music Has the Right to Children", "title": "An Eagle in Your Mind", "track": "02", "disc": "1"],
                streams: [ProbedStreamMetadata(index: 0, codecType: "audio", codecName: "flac", tags: [:], dispositions: [:])]
            )
            mockProbe.mockedMetadata[track3URL.standardizedFileURL.resolvingSymlinksInPath()] = ProbedMetadata(
                formatTags: ["artist": "Aphex Twin", "album": "Selected Ambient Works 85-92", "title": "Xtal", "track": "1", "disc": "1"],
                streams: [ProbedStreamMetadata(index: 0, codecType: "audio", codecName: "aac", tags: [:], dispositions: [:])]
            )
            
            let scanner = LibraryScanService(
                fileManager: fileManager,
                artworkService: ArtworkService(),
                remoteArtworkService: nil,
                metadataProbe: mockProbe
            )
            
            let tracks = await scanner.scanFolder(tempDir)
            
            // Evaluation check 1: Scanning found all 3 files
            XCTAssertEqual(tracks.count, 3)
            
            // Evaluation check 2: Check indexing/grouping
            let index = LibraryIndex.build(from: tracks)
            XCTAssertEqual(index.artists.count, 2)
            
            let artists = index.artists.map { $0.name }
            XCTAssertTrue(artists.contains("Boards of Canada"))
            XCTAssertTrue(artists.contains("Aphex Twin"))
            
            let bocArtist = index.artists.first(where: { $0.name == "Boards of Canada" })
            XCTAssertNotNil(bocArtist)
            XCTAssertEqual(bocArtist?.albums.count, 1)
            
            let album = bocArtist?.albums.first
            XCTAssertEqual(album?.title, "Music Has the Right to Children")
            XCTAssertEqual(album?.tracks.count, 2)
            
            // Evaluation check 3: Track sorting (Wildlife Analysis track 1 should be before An Eagle in Your Mind track 2)
            XCTAssertEqual(album?.tracks[0].track.title, "Wildlife Analysis")
            XCTAssertEqual(album?.tracks[1].track.title, "An Eagle in Your Mind")
        }
    }
    
    // MARK: - Scenario 2: Metadata Probing and Normalization
    func testScenario2_MetadataProbingAndNormalization() throws {
        // Feeds raw and messy tags into normalization logic
        let rawTags: [String: String] = [
            "artist": "Aphex Twin",
            "album": "Drukqs",
            "albumartist": "Aphex Twin",
            "title": "Avril 14th",
            "track": "14/30",
            "disc": "1/2",
            "date": "2001-10-22"
        ]
        
        let avFallback = ConversionMetadata(
            title: "Avril 14th",
            artist: "Aphex Twin",
            albumArtist: "Aphex Twin",
            album: "Drukqs",
            compilation: false,
            trackNumber: 14,
            trackTotal: nil,
            discNumber: 1,
            discTotal: nil,
            year: 2001,
            genre: "IDM"
        )
        
        let normalized = MetadataNormalization.normalize(
            formatTags: rawTags,
            fallback: avFallback,
            artwork: nil
        )
        
        // Evaluation checks
        XCTAssertEqual(normalized.artist, "Aphex Twin")
        XCTAssertEqual(normalized.albumArtist, "Aphex Twin")
        XCTAssertEqual(normalized.album, "Drukqs")
        XCTAssertEqual(normalized.title, "Avril 14th")
        XCTAssertEqual(normalized.trackNumber, 14)
        XCTAssertEqual(normalized.trackTotal, 30)
        XCTAssertEqual(normalized.discNumber, 1)
        XCTAssertEqual(normalized.discTotal, 2)
        XCTAssertEqual(normalized.year, 2001)
    }
    
    // MARK: - Scenario 3: Artwork Resolution & Extraction
    func testScenario3_ArtworkResolutionAndExtraction() async throws {
        try await withTemporaryDirectory(prefix: "Scenario3") { tempDir in
            let artworkService = ArtworkService()
            
            let trackURL = tempDir.appendingPathComponent("track.mp3")
            try "dummy mp3".write(to: trackURL, atomically: true, encoding: .utf8)
            
            // Create a fake cover.jpg in the same directory
            let coverURL = tempDir.appendingPathComponent("cover.jpg")
            let mockImageData = try makeImageData()
            try mockImageData.write(to: coverURL)
            
            // Resolve artwork
            let resolved = await artworkService.resolveArtwork(trackURL: trackURL)
            
            // Evaluation checks
            XCTAssertNotNil(resolved)
            XCTAssertEqual(resolved?.source, .folderImage)
            XCTAssertFalse(resolved!.hash.isEmpty)
            
            // Try resolving thumbnail
            let thumb = artworkService.generateThumbnail(artworkHash: resolved!.hash, size: CGSize(width: 100, height: 100))
            XCTAssertNotNil(thumb)
        }
    }
    
    // MARK: - Scenario 4: Crate Management (CRUD & Prep Crate)
    func testScenario4_CrateManagementLifecycle() throws {
        try withTemporaryDirectory(prefix: "Scenario4") { tempDir in
            let fileManager = FileManager.default
            let cratesDir = tempDir.appendingPathComponent("Crates")
            try fileManager.createDirectory(at: cratesDir, withIntermediateDirectories: true)
            
            // 1. Staging Prep Crate simulation
            let trackURL = tempDir.appendingPathComponent("track.mp3")
            try "dummy mp3".write(to: trackURL, atomically: true, encoding: .utf8)
            
            let track = AudioTrack(fileURL: trackURL, title: "Roygbiv", artist: "Boards of Canada", album: "Music Has the Right to Children")
            let loadedTrack = LoadedTrack(track: track, metadata: ConversionMetadata(title: "Roygbiv", artist: "Boards of Canada", album: "Music Has the Right to Children"))
            
            // Staging area simulated via local arrays
            let prepCrate: [LoadedTrack] = [loadedTrack]
            XCTAssertEqual(prepCrate.count, 1)
            
            // 2. Save to custom crate .cdlib
            let crateName = "Chill Crate"
            let fileURL = cratesDir.appendingPathComponent("\(crateName).cdlib")
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(prepCrate)
            try data.write(to: fileURL)
            
            XCTAssertTrue(fileManager.fileExists(atPath: fileURL.path))
            
            // 3. Load from crate
            let decoder = JSONDecoder()
            let savedData = try Data(contentsOf: fileURL)
            var loadedCrate = try decoder.decode([LoadedTrack].self, from: savedData)
            
            XCTAssertEqual(loadedCrate.count, 1)
            XCTAssertEqual(loadedCrate[0].track.title, "Roygbiv")
            
            // 4. Update track & update crate paths (reorganization simulation)
            let newTrackURL = tempDir.appendingPathComponent("NewBoards/Roygbiv.mp3")
            try fileManager.createDirectory(at: newTrackURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: trackURL, to: newTrackURL)
            
            let updatedTrack = AudioTrack(fileURL: newTrackURL, title: "Roygbiv", artist: "Boards of Canada", album: "Music Has the Right to Children")
            let updatedLoadedTrack = LoadedTrack(track: updatedTrack, metadata: loadedCrate[0].metadata)
            
            // Update in crate
            var modified = false
            for i in 0..<loadedCrate.count {
                if loadedCrate[i].track.fileURL.path == trackURL.path {
                    loadedCrate[i] = updatedLoadedTrack
                    modified = true
                }
            }
            XCTAssertTrue(modified)
            
            // Save updated crate
            let updatedData = try encoder.encode(loadedCrate)
            try updatedData.write(to: fileURL)
            
            // 5. Delete track from crate
            loadedCrate.removeAll { $0.track.fileURL.path == newTrackURL.path }
            XCTAssertTrue(loadedCrate.isEmpty)
        }
    }
    
    // MARK: - Scenario 5: Output Path Planning
    func testScenario5_OutputPathPlanning() throws {
        let fileManager = FileManager.default
        let planner = OutputPathPlanner(fileManager: fileManager)
        
        let destRoot = URL(fileURLWithPath: "/music/organized")
        let sourceRoot = URL(fileURLWithPath: "/music/incoming")
        let trackURL = sourceRoot.appendingPathComponent("Aphex Twin/Pulsewidth.mp3")
        
        let track = AudioTrack(fileURL: trackURL, title: "Pulsewidth", artist: "Aphex Twin", album: "Selected Ambient Works 85-92", year: 1992, trackNumber: 3)
        let loaded = LoadedTrack(track: track, metadata: ConversionMetadata(title: "Pulsewidth", artist: "Aphex Twin", albumArtist: "Aphex Twin", album: "Selected Ambient Works 85-92", trackNumber: 3, year: 1992))
        
        let preset = ConversionPreset(
            id: "preset_mp3",
            name: "MP3",
            outputFormat: .mp3,
            bitrateKbps: 320,
            sampleRateHz: nil,
            channels: nil
        )
        let dummyTemplateConfig = FolderTemplateConfig(preset: .artistYearAlbum, tokenOrder: [.albumArtist, .year, .album])
        
        // Mode 1: Flat
        let flatPath = planner.planDestination(
            for: loaded,
            preset: preset,
            destinationRoot: destRoot,
            sourceRoot: sourceRoot,
            folderMode: .flat,
            templateConfig: dummyTemplateConfig
        )
        XCTAssertNil(flatPath.relativeSubpath)
        XCTAssertEqual(flatPath.destinationURL.path, "/music/organized/Pulsewidth.mp3")
        
        // Mode 2: Source Relative
        let relativePath = planner.planDestination(
            for: loaded,
            preset: preset,
            destinationRoot: destRoot,
            sourceRoot: sourceRoot,
            folderMode: .sourceRelative,
            templateConfig: dummyTemplateConfig
        )
        XCTAssertEqual(relativePath.relativeSubpath, "Aphex Twin")
        XCTAssertEqual(relativePath.destinationURL.path, "/music/organized/Aphex Twin/Pulsewidth.mp3")
        
        // Mode 3: Metadata Template
        let templateConfig = FolderTemplateConfig(preset: .artistYearAlbum, tokenOrder: [.albumArtist, .year, .album])
        let templatePath = planner.planDestination(
            for: loaded,
            preset: preset,
            destinationRoot: destRoot,
            sourceRoot: sourceRoot,
            folderMode: .metadataTemplate,
            templateConfig: templateConfig
        )
        // Directory hierarchy structured as Artist/Year/Album, with filename as Pulsewidth.mp3
        XCTAssertEqual(templatePath.relativeSubpath, "Aphex Twin/1992/Selected Ambient Works 85-92")
        XCTAssertEqual(templatePath.destinationURL.path, "/music/organized/Aphex Twin/1992/Selected Ambient Works 85-92/Pulsewidth.mp3")
        
        // Collision detection simulation
        var reserved = Set<String>()
        reserved.insert("/music/organized/Aphex Twin/1992/Selected Ambient Works 85-92/Pulsewidth.mp3")
        
        let collisionPath = planner.planDestination(
            for: loaded,
            preset: preset,
            destinationRoot: destRoot,
            sourceRoot: sourceRoot,
            folderMode: .metadataTemplate,
            templateConfig: templateConfig,
            reservedDestinationPaths: reserved
        )
        XCTAssertEqual(collisionPath.relativeSubpath, "Aphex Twin/1992/Selected Ambient Works 85-92")
        XCTAssertEqual(collisionPath.destinationURL.path, "/music/organized/Aphex Twin/1992/Selected Ambient Works 85-92/Pulsewidth (2).mp3")
    }
    
    // MARK: - Scenario 6: Batch Conversion
    func testScenario6_BatchConversionWithFfmpegMock() throws {
        try withTemporaryDirectory(prefix: "Scenario6") { tempDir in
            let fileManager = FileManager.default
            
            // Create fake ffmpeg stub
            let fakeFfmpegURL = tempDir.appendingPathComponent("ffmpeg")
            let stub = "#!/bin/sh\necho ffmpeg stub\n"
            try Data(stub.utf8).write(to: fakeFfmpegURL)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeFfmpegURL.path)
            
            let mockRunner = MockCommandRunner()
            let service = try ConversionService(
                ffmpegExecutableURL: fakeFfmpegURL,
                presets: ConversionPreset.defaultPresets,
                artworkPreparer: PassThroughArtworkPreparer(),
                commandRunner: mockRunner,
                fileManager: fileManager
            )
            
            let sourceURL = tempDir.appendingPathComponent("input.flac")
            try "mock flac content".write(to: sourceURL, atomically: true, encoding: .utf8)
            let destURL = tempDir.appendingPathComponent("output.mp3")
            
            let job = ConversionJob(sourceURL: sourceURL, destinationURL: destURL)
            let queued = try service.enqueue([job], presetID: "ipod_mp3_320")
            
            XCTAssertEqual(queued.count, 1)
            
            // Verify arguments generated
            let command = try service.preparedCommand(for: queued[0])
            XCTAssertTrue(command.arguments.contains("-c:a"))
            XCTAssertTrue(command.arguments.contains("libmp3lame"))
            XCTAssertTrue(command.arguments.contains("320k"))
            
            // Simulate run using the commandRunner
            let output = try mockRunner.run(executableURL: command.executableURL, arguments: command.arguments)
            XCTAssertEqual(output.terminationStatus, 0)
            XCTAssertEqual(mockRunner.runCalls.count, 1)
            XCTAssertEqual(mockRunner.runCalls[0].executableURL.path, fakeFfmpegURL.path)
        }
    }
    
    // MARK: - Scenario 7: Library Consolidate and Move
    func testScenario7_LibraryConsolidateAndMove() async throws {
        try await withTemporaryDirectory(prefix: "Scenario7") { tempDir in
            let fileManager = FileManager.default
            let sourceDir = tempDir.appendingPathComponent("SourceLib")
            let destDir = tempDir.appendingPathComponent("ManagedLib")
            
            try fileManager.createDirectory(at: sourceDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
            
            let track1URL = sourceDir.appendingPathComponent("ArtistName/AlbumName/01_track.mp3")
            try fileManager.createDirectory(at: track1URL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "mp3 bytes".write(to: track1URL, atomically: true, encoding: .utf8)
            
            let track = AudioTrack(fileURL: track1URL, title: "Track One", artist: "ArtistName", album: "AlbumName", year: 2021, trackNumber: 1)
            let loadedTrack = LoadedTrack(track: track, metadata: ConversionMetadata(title: "Track One", artist: "ArtistName", albumArtist: "ArtistName", album: "AlbumName", trackNumber: 1, year: 2021))
            
            let organizer = LibraryOrganizerService(fileManager: fileManager)
            
            // Run organize (copyOnly = false -> Move)
            try await organizer.organize(
                tracks: [loadedTrack],
                destinationFolder: destDir,
                copyOnly: false
            )
            
            // Expected location: destDir/ArtistName/[2021] - AlbumName/01 - Track One.mp3
            let expectedURL = destDir
                .appendingPathComponent("ArtistName")
                .appendingPathComponent("[2021] - AlbumName")
                .appendingPathComponent("01 - Track One.mp3")
            
            XCTAssertTrue(fileManager.fileExists(atPath: expectedURL.path))
            XCTAssertFalse(fileManager.fileExists(atPath: track1URL.path))
            
            // Verify empty directories cleaning up
            XCTAssertFalse(fileManager.fileExists(atPath: track1URL.deletingLastPathComponent().path))
        }
    }
    
    // MARK: - Scenario 8: External Device Transfer Syncing
    func testScenario8_ExternalDeviceTransferSyncing() throws {
        let fileManager = FileManager.default
        let planner = ExternalDeviceTransferPlanner(fileManager: fileManager)
        
        let mountedRoot = URL(fileURLWithPath: "/Volumes/SDCard")
        let sourceRoot = URL(fileURLWithPath: "/music/incoming")
        let trackURL = sourceRoot.appendingPathComponent("Autechre/Bike.flac")
        
        let track = AudioTrack(fileURL: trackURL, title: "Bike", artist: "Autechre", album: "Amber", year: 1994, trackNumber: 3)
        let loaded = LoadedTrack(track: track, metadata: ConversionMetadata(title: "Bike", artist: "Autechre", albumArtist: "Autechre", album: "Amber", trackNumber: 3, year: 1994))
        
        // Define Device Profile (converts FLAC -> MP3)
        let profile = ExternalDeviceProfile(
            name: "My Car SD Card",
            kind: .sdCard,
            musicDirectorySubpath: "CarMusic",
            transferSettings: ExternalDeviceTransferSettings(
                mode: .convertDuringTransfer,
                outputFormat: .mp3,
                bitrateKbps: 256,
                sampleRateHz: 44100
            )
        )
        
        let transfers = planner.planTransfers(
            tracks: [loaded],
            profile: profile,
            mountedAt: mountedRoot
        )
        
        // Evaluation checks
        XCTAssertEqual(transfers.count, 1)
        let transfer = transfers[0]
        XCTAssertEqual(transfer.action, .convert)
        XCTAssertNotNil(transfer.conversionPreset)
        XCTAssertEqual(transfer.conversionPreset?.outputFormat, .mp3)
        XCTAssertEqual(transfer.conversionPreset?.bitrateKbps, 256)
        
        // Verify path mapping: /Volumes/SDCard/CarMusic/Autechre/1994/Amber/Bike.mp3
        XCTAssertEqual(transfer.destinationURL.path, "/Volumes/SDCard/CarMusic/Autechre/1994/Amber/Bike.mp3")
    }
    
    // MARK: - Scenario 9: Subsonic client integration
    func testScenario9_SubsonicStreamIntegration() async throws {
        // Set up custom URLSession utilizing MockURLProtocol
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = SubsonicClient(session: session)
        
        let config = SubsonicConfig(
            url: "http://localhost:4533",
            username: "testuser",
            password: "testpassword"
        )
        
        // Mock Ping Response JSON
        let pingJSON = """
        {
            "subsonic-response": {
                "status": "ok",
                "version": "1.16.1"
            }
        }
        """
        
        MockURLProtocol.requestHandler = { request in
            guard let url = request.url else {
                throw NSError(domain: "test", code: 0)
            }
            XCTAssertTrue(url.path.contains("ping.view"))
            XCTAssertEqual(url.queryParameters["u"], "testuser")
            XCTAssertNotNil(url.queryParameters["t"])
            XCTAssertNotNil(url.queryParameters["s"])
            XCTAssertEqual(url.queryParameters["f"], "json")
            
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (response, pingJSON.data(using: .utf8))
        }
        
        let success = try await client.ping(config: config)
        XCTAssertTrue(success)
    }
    
    // MARK: - Scenario 10: Playlist Management
    func testScenario10_PlaylistManagement() throws {
        try withTemporaryDirectory(prefix: "Scenario10") { tempDir in
            let fileManager = FileManager.default
            let service = PlaylistService(fileManager: fileManager)
            
            let track1URL = URL(fileURLWithPath: "/music/track1.mp3")
            let track2URL = URL(fileURLWithPath: "/music/track2.m4a")
            let playlist = Playlist(name: "Workout Mix", trackURLs: [track1URL, track2URL])
            
            // Export to a custom temp file url
            let m3uURL = tempDir.appendingPathComponent("Workout Mix.m3u")
            try service.exportPlaylist(playlist, to: m3uURL)
            
            XCTAssertTrue(fileManager.fileExists(atPath: m3uURL.path))
            
            // Read content of output file
            let m3uContent = try String(contentsOf: m3uURL, encoding: .utf8)
            XCTAssertTrue(m3uContent.hasPrefix("#EXTM3U"))
            XCTAssertTrue(m3uContent.contains("/music/track1.mp3"))
            XCTAssertTrue(m3uContent.contains("/music/track2.m4a"))
            
            // Import / Load from temp file url
            let loaded = try service.loadPlaylist(from: m3uURL)
            XCTAssertEqual(loaded.name, "Workout Mix")
            XCTAssertEqual(loaded.trackURLs.count, 2)
            XCTAssertEqual(loaded.trackURLs[0].path, "/music/track1.mp3")
            XCTAssertEqual(loaded.trackURLs[1].path, "/music/track2.m4a")
        }
    }
}

// Helper to easily extract query parameters from URL in tests
extension URL {
    var queryParameters: [String: String] {
        guard let components = URLComponents(url: self, resolvingAgainstBaseURL: true),
              let queryItems = components.queryItems else {
            return [:]
        }
        return queryItems.reduce(into: [:]) { result, item in
            result[item.name] = item.value
        }
    }
}
#endif
