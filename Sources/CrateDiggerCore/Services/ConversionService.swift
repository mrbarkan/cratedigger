import Foundation

public struct CommandOutput: Sendable {
    public let terminationStatus: Int32
    public let standardOutput: String
    public let standardError: String

    public init(terminationStatus: Int32, standardOutput: String, standardError: String) {
        self.terminationStatus = terminationStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public protocol CommandRunning {
    func run(executableURL: URL, arguments: [String]) throws -> CommandOutput
}

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(executableURL: URL, arguments: [String]) throws -> CommandOutput {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return CommandOutput(
            terminationStatus: process.terminationStatus,
            standardOutput: String(data: stdoutData, encoding: .utf8) ?? "",
            standardError: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}

public enum ConversionServiceError: Error {
    case presetNotFound(String)
    case ffmpegExecutableMissing(URL)
    case buildFailure(String)
    case executionFailure(String)
}

public struct PreparedConversionCommand: Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let warning: String?
    public let temporaryFiles: [URL]

    public init(executableURL: URL, arguments: [String], warning: String?, temporaryFiles: [URL]) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.warning = warning
        self.temporaryFiles = temporaryFiles
    }
}

private struct CommandInputSection: Sendable {
    let arguments: [String]
    let outputMappingArguments: [String]
    let hasVideoMapping: Bool
    let warning: String?
    let temporaryFiles: [URL]
}

public final class ConversionService {
    public private(set) var queue: [QueuedConversion] = []

    private let presetsByID: [String: ConversionPreset]
    private let ffmpegExecutableURL: URL
    private let artworkPreparer: ArtworkPreparing
    private let commandRunner: CommandRunning
    private let fileManager: FileManager

    public let maxParallelWorkers: Int

    private static let canonicalMetadataKeySet: Set<String> = [
        "title",
        "artist",
        "albumartist",
        "album",
        "compilation",
        "tracknumber",
        "track",
        "trck",
        "tracktotal",
        "totaltracks",
        "discnumber",
        "disc",
        "disk",
        "tpos",
        "disctotal",
        "totaldiscs",
        "date",
        "year",
        "originalyear",
        "genre",
        "comment",
        "description"
    ]

    public init(
        ffmpegExecutableURL: URL? = nil,
        presets: [ConversionPreset] = ConversionPreset.defaultPresets,
        artworkPreparer: ArtworkPreparing = ArtworkService(),
        metadataProbe: MetadataProbing? = nil,
        commandRunner: CommandRunning = ProcessCommandRunner(),
        fileManager: FileManager = .default
    ) throws {
        _ = metadataProbe
        self.fileManager = fileManager
        self.artworkPreparer = artworkPreparer
        self.commandRunner = commandRunner
        self.maxParallelWorkers = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)

        let executable = ffmpegExecutableURL ?? Self.defaultFFmpegExecutableURL(fileManager: fileManager)
        guard fileManager.fileExists(atPath: executable.path) else {
            throw ConversionServiceError.ffmpegExecutableMissing(executable)
        }
        self.ffmpegExecutableURL = executable

        self.presetsByID = Dictionary(uniqueKeysWithValues: presets.map { ($0.id, $0) })
    }

    public func enqueue(_ jobs: [ConversionJob], presetID: String, deviceProfile: DeviceProfile? = nil) throws -> [QueuedConversion] {
        guard let preset = presetsByID[presetID] else {
            throw ConversionServiceError.presetNotFound(presetID)
        }

        return enqueue(jobs, preset: preset, deviceProfile: deviceProfile)
    }

    public func enqueue(_ jobs: [ConversionJob], preset: ConversionPreset, deviceProfile: DeviceProfile? = nil) -> [QueuedConversion] {
        let resolvedPreset = Self.withDeviceProfileOverride(preset, overrideDeviceProfile: deviceProfile)

        let queuedItems = jobs.map { job in
            QueuedConversion(job: job, preset: resolvedPreset)
        }

        queue.append(contentsOf: queuedItems)
        return queuedItems
    }

    public func clearQueue() {
        queue.removeAll()
    }

    public func runQueuedJobs(maxConcurrentWorkers: Int? = nil) -> [ConversionExecutionResult] {
        runQueuedJobs(maxConcurrentWorkers: maxConcurrentWorkers, onJobFinished: nil)
    }

    public func runQueuedJobs(
        maxConcurrentWorkers: Int? = nil,
        onJobFinished: ((ConversionExecutionResult, Int, Int) -> Void)?
    ) -> [ConversionExecutionResult] {
        let workers = max(1, min(maxConcurrentWorkers ?? maxParallelWorkers, maxParallelWorkers))
        guard !queue.isEmpty else {
            return []
        }

        let items = queue
        let totalCount = items.count
        if workers == 1 || items.count == 1 {
            var results: [ConversionExecutionResult] = []
            results.reserveCapacity(items.count)

            for (index, queued) in items.enumerated() {
                let result = runSingleConversion(queued)
                results.append(result)
                onJobFinished?(result, index + 1, totalCount)
            }

            let statuses = Dictionary(uniqueKeysWithValues: results.map { ($0.queuedID, $0.status) })
            queue = queue.map { item in
                var updated = item
                if let status = statuses[item.id] {
                    updated.status = status
                }
                return updated
            }

            return results
        }

        let operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = workers

        let lock = NSLock()
        var results: [ConversionExecutionResult] = []
        var processedCount = 0

        for queued in items {
            operationQueue.addOperation {
                let result = self.runSingleConversion(queued)

                var callbackCount = 0
                lock.lock()
                results.append(result)
                processedCount += 1
                callbackCount = processedCount
                lock.unlock()

                onJobFinished?(result, callbackCount, totalCount)
            }
        }

        operationQueue.waitUntilAllOperationsAreFinished()

        let statuses = Dictionary(uniqueKeysWithValues: results.map { ($0.queuedID, $0.status) })
        queue = queue.map { item in
            var updated = item
            if let status = statuses[item.id] {
                updated.status = status
            }
            return updated
        }

        return results
    }

    public func preparedCommand(for queued: QueuedConversion) throws -> PreparedConversionCommand {
        let globalArguments: [String] = [
            "-hide_banner",
            "-nostdin",
            "-y"
        ]

        let inputSection = try buildInputSection(for: queued)
        let outputArguments = buildOutputSection(for: queued, inputSection: inputSection)

        var arguments = globalArguments
        arguments.append(contentsOf: inputSection.arguments)
        arguments.append(contentsOf: outputArguments)
        arguments.append(queued.job.destinationURL.path)

        return PreparedConversionCommand(
            executableURL: ffmpegExecutableURL,
            arguments: arguments,
            warning: inputSection.warning,
            temporaryFiles: inputSection.temporaryFiles
        )
    }

    private func buildInputSection(for queued: QueuedConversion) throws -> CommandInputSection {
        var inputArguments: [String] = ["-i", queued.job.sourceURL.path]
        var outputMappingArguments: [String] = []
        var warning: String?
        var temporaryFiles: [URL] = []
        var hasVideoMapping = false

        if let artwork = queued.job.metadata?.artwork {
            switch queued.preset.artworkMode {
            case .none:
                outputMappingArguments.append(contentsOf: ["-map", "0:a:0"])
            case .preserve:
                outputMappingArguments.append(contentsOf: [
                    "-map", "0:a:0",
                    "-map", "0:v?",
                    "-c:v", "copy",
                    "-disposition:v:0", "attached_pic",
                    "-metadata:s:v:0", "title=Album cover",
                    "-metadata:s:v:0", "comment=Cover (front)"
                ])
                hasVideoMapping = true
            case .compatReembed:
                do {
                    let compatibleArtwork = try artworkPreparer.prepareCompatibleArtwork(
                        asset: artwork,
                        profile: queued.preset.deviceProfile,
                        maxDimension: queued.preset.artworkMaxDimension
                    )
                    let artworkTempURL = try writeTemporaryArtwork(compatibleArtwork.data)
                    temporaryFiles.append(artworkTempURL)

                    inputArguments.append(contentsOf: ["-i", artworkTempURL.path])
                    outputMappingArguments.append(contentsOf: [
                        "-map", "0:a:0",
                        "-map", "1:v:0",
                        "-c:v", "mjpeg",
                        "-disposition:v:0", "attached_pic",
                        "-metadata:s:v:0", "title=Album cover",
                        "-metadata:s:v:0", "comment=Cover (front)"
                    ])
                    hasVideoMapping = true
                } catch {
                    warning = "Artwork conversion failed. Falling back to source artwork stream when available: \(error.localizedDescription)"
                    outputMappingArguments.append(contentsOf: [
                        "-map", "0:a:0",
                        "-map", "0:v?",
                        "-c:v", "copy",
                        "-disposition:v:0", "attached_pic",
                        "-metadata:s:v:0", "title=Album cover",
                        "-metadata:s:v:0", "comment=Cover (front)"
                    ])
                    hasVideoMapping = true
                }
            }
        } else {
            switch queued.preset.artworkMode {
            case .preserve:
                outputMappingArguments.append(contentsOf: [
                    "-map", "0:a:0",
                    "-map", "0:v?",
                    "-c:v", "copy",
                    "-disposition:v:0", "attached_pic",
                    "-metadata:s:v:0", "title=Album cover",
                    "-metadata:s:v:0", "comment=Cover (front)"
                ])
                hasVideoMapping = true
            case .compatReembed:
                outputMappingArguments.append(contentsOf: [
                    "-map", "0:a:0",
                    "-map", "0:v?",
                    "-c:v", "copy",
                    "-disposition:v:0", "attached_pic",
                    "-metadata:s:v:0", "title=Album cover",
                    "-metadata:s:v:0", "comment=Cover (front)"
                ])
                hasVideoMapping = true
            case .none:
                outputMappingArguments.append(contentsOf: ["-map", "0:a:0"])
            }
        }

        return CommandInputSection(
            arguments: inputArguments,
            outputMappingArguments: outputMappingArguments,
            hasVideoMapping: hasVideoMapping,
            warning: warning,
            temporaryFiles: temporaryFiles
        )
    }

    private func buildOutputSection(for queued: QueuedConversion, inputSection: CommandInputSection) -> [String] {
        // Keep metadata copy lossless-first: copy global, stream, and chapter metadata from source input 0.
        var outputArguments: [String] = [
            "-map_metadata", "0",
            "-map_metadata:s:a:0", "0:s:a:0",
            "-map_chapters", "0"
        ]
        outputArguments.append(contentsOf: inputSection.outputMappingArguments)

        applyCodecArguments(to: &outputArguments, preset: queued.preset)
        applyTagArguments(to: &outputArguments, preset: queued.preset)
        applyMetadataArguments(to: &outputArguments, metadata: queued.job.metadata)

        if !inputSection.hasVideoMapping {
            outputArguments.append(contentsOf: ["-vn"])
        }

        return outputArguments
    }

    private func runSingleConversion(_ queued: QueuedConversion) -> ConversionExecutionResult {
        do {
            let command = try preparedCommand(for: queued)
            try ensureOutputDirectoryExists(for: queued.job.destinationURL)

            let output = try commandRunner.run(executableURL: command.executableURL, arguments: command.arguments)
            cleanupTemporaryFiles(command.temporaryFiles)

            if output.terminationStatus == 0 {
                return ConversionExecutionResult(
                    queuedID: queued.id,
                    status: .completed,
                    warning: command.warning,
                    log: output.standardError.isEmpty ? output.standardOutput : output.standardError
                )
            }

            let message = output.standardError.isEmpty ? output.standardOutput : output.standardError
            return ConversionExecutionResult(
                queuedID: queued.id,
                status: .failed,
                warning: command.warning,
                log: message
            )
        } catch {
            return ConversionExecutionResult(
                queuedID: queued.id,
                status: .failed,
                warning: nil,
                log: error.localizedDescription
            )
        }
    }

    private func applyCodecArguments(to arguments: inout [String], preset: ConversionPreset) {
        switch preset.outputFormat {
        case .mp3:
            arguments.append(contentsOf: ["-c:a", "libmp3lame"])
        case .aac:
            arguments.append(contentsOf: ["-c:a", "aac", "-profile:a", "aac_low"])
        case .alac:
            arguments.append(contentsOf: ["-c:a", "alac"])
        case .flac:
            arguments.append(contentsOf: ["-c:a", "flac"])
        case .wav:
            arguments.append(contentsOf: ["-c:a", "pcm_s16le"])
        case .aiff:
            arguments.append(contentsOf: ["-c:a", "pcm_s16be"])
        case .ogg:
            arguments.append(contentsOf: ["-c:a", "libvorbis"])
        case .opus:
            arguments.append(contentsOf: ["-c:a", "libopus"])
        }

        if let bitrate = preset.bitrateKbps {
            arguments.append(contentsOf: ["-b:a", "\(bitrate)k"])
        }

        if preset.constantBitrate {
            arguments.append(contentsOf: ["-write_xing", "0"])
        }

        if let sampleRateHz = preset.sampleRateHz {
            arguments.append(contentsOf: ["-ar", "\(sampleRateHz)"])
        }

        if let channels = preset.channels {
            arguments.append(contentsOf: ["-ac", "\(channels)"])
        }
    }

    private func applyTagArguments(to arguments: inout [String], preset: ConversionPreset) {
        switch preset.tagMode {
        case .auto:
            // Compatibility-first: leave MP4/M4A muxer defaults so metadata is written using player-friendly atoms.
            break
        case .id3v23:
            arguments.append(contentsOf: ["-id3v2_version", "3", "-write_id3v1", "1"])
        case .mp4Atoms:
            // Compatibility-first: do not force mdta tag writing.
            break
        }
    }

    private func applyMetadataArguments(to arguments: inout [String], metadata: ConversionMetadata?) {
        guard let metadata else {
            return
        }

        var writtenNormalizedKeys: Set<String> = []

        func add(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else {
                return
            }
            arguments.append(contentsOf: ["-metadata", "\(key)=\(value)"])
            writtenNormalizedKeys.insert(normalizedMetadataKey(key))
        }

        if let trackNumber = metadata.trackNumber {
            let trackValue: String
            if let trackTotal = metadata.trackTotal, trackTotal > 0 {
                trackValue = "\(trackNumber)/\(trackTotal)"
            } else {
                trackValue = "\(trackNumber)"
            }
            add("track", trackValue)
        }

        if let discNumber = metadata.discNumber {
            let discValue: String
            if let discTotal = metadata.discTotal, discTotal > 0 {
                discValue = "\(discNumber)/\(discTotal)"
            } else {
                discValue = "\(discNumber)"
            }
            add("disc", discValue)
        }

        add("album_artist", metadata.albumArtist)
        add("albumartist", metadata.albumArtist)

        if metadata.compilation == true {
            add("compilation", "1")
        }

        for pair in metadata.customTagPairs {
            let trimmedKey = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedValue = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedKey.isEmpty, !trimmedValue.isEmpty else {
                continue
            }

            let normalizedKey = normalizedMetadataKey(trimmedKey)
            if Self.canonicalMetadataKeySet.contains(normalizedKey) || writtenNormalizedKeys.contains(normalizedKey) {
                continue
            }

            add(trimmedKey, trimmedValue)
        }
    }

    private func normalizedMetadataKey(_ key: String) -> String {
        Self.normalizedMetadataKey(key)
    }

    private static func normalizedMetadataKey(_ key: String) -> String {
        key
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }

    private func ensureOutputDirectoryExists(for outputURL: URL) throws {
        let directory = outputURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func cleanupTemporaryFiles(_ urls: [URL]) {
        for url in urls {
            try? fileManager.removeItem(at: url)
        }
    }

    private func writeTemporaryArtwork(_ data: Data) throws -> URL {
        let preferredExtension = Self.imageFileExtension(for: data)
        let tempURL = fileManager.temporaryDirectory
            .appendingPathComponent("cratedigger-artwork-\(UUID().uuidString)")
            .appendingPathExtension(preferredExtension)

        try data.write(to: tempURL, options: .atomic)
        return tempURL
    }

    private static func imageFileExtension(for data: Data) -> String {
        if data.count >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF {
            return "jpg"
        }
        if data.count >= 8 &&
            data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47 &&
            data[4] == 0x0D && data[5] == 0x0A && data[6] == 0x1A && data[7] == 0x0A {
            return "png"
        }
        if data.count >= 6 {
            let header = String(data: data.prefix(6), encoding: .ascii)?.lowercased() ?? ""
            if header.hasPrefix("gif87a") || header.hasPrefix("gif89a") {
                return "gif"
            }
        }
        return "jpg"
    }

    private static func withDeviceProfileOverride(
        _ preset: ConversionPreset,
        overrideDeviceProfile: DeviceProfile?
    ) -> ConversionPreset {
        var resolvedPreset = preset
        if let overrideDeviceProfile {
            resolvedPreset = ConversionPreset(
                id: preset.id,
                name: preset.name,
                outputFormat: preset.outputFormat,
                bitrateKbps: preset.bitrateKbps,
                sampleRateHz: preset.sampleRateHz,
                channels: preset.channels,
                constantBitrate: preset.constantBitrate,
                deviceProfile: overrideDeviceProfile,
                tagMode: preset.tagMode,
                artworkMode: preset.artworkMode,
                artworkMaxDimension: preset.artworkMaxDimension
            )
        }

        return resolvedPreset
    }

    private static func defaultFFmpegExecutableURL(fileManager: FileManager) -> URL {
        let candidatePaths = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/ffmpeg").path,
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]

        for path in candidatePaths where fileManager.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        return URL(fileURLWithPath: candidatePaths[0])
    }
}
