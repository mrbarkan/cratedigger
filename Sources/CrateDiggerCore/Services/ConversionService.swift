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

public final class ConversionService {
    public private(set) var queue: [QueuedConversion] = []

    private let presetsByID: [String: ConversionPreset]
    private let ffmpegExecutableURL: URL
    private let artworkPreparer: ArtworkPreparing
    private let commandRunner: CommandRunning
    private let fileManager: FileManager

    public let maxParallelWorkers: Int

    public init(
        ffmpegExecutableURL: URL? = nil,
        presets: [ConversionPreset] = ConversionPreset.defaultPresets,
        artworkPreparer: ArtworkPreparing = ArtworkService(),
        commandRunner: CommandRunning = ProcessCommandRunner(),
        fileManager: FileManager = .default
    ) throws {
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
        guard let preset = Self.resolvedPreset(id: presetID, from: presetsByID, overrideDeviceProfile: deviceProfile) else {
            throw ConversionServiceError.presetNotFound(presetID)
        }

        let queuedItems = jobs.map { job in
            QueuedConversion(job: job, preset: preset)
        }

        queue.append(contentsOf: queuedItems)
        return queuedItems
    }

    public func clearQueue() {
        queue.removeAll()
    }

    public func runQueuedJobs(maxConcurrentWorkers: Int? = nil) -> [ConversionExecutionResult] {
        let workers = max(1, min(maxConcurrentWorkers ?? maxParallelWorkers, maxParallelWorkers))
        guard !queue.isEmpty else {
            return []
        }

        let items = queue
        if workers == 1 || items.count == 1 {
            return items.map { runSingleConversion($0) }
        }

        let operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = workers

        let lock = NSLock()
        var results: [ConversionExecutionResult] = []

        for queued in items {
            operationQueue.addOperation {
                let result = self.runSingleConversion(queued)
                lock.lock()
                results.append(result)
                lock.unlock()
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
        var arguments: [String] = [
            "-hide_banner",
            "-nostdin",
            "-y",
            "-i", queued.job.sourceURL.path
        ]

        var warning: String?
        var temporaryFiles: [URL] = []

        arguments.append(contentsOf: ["-map_metadata", "0"])

        var mapsAudioOnly = true
        if let artwork = queued.job.metadata?.artwork {
            switch queued.preset.artworkMode {
            case .none:
                arguments.append(contentsOf: ["-map", "0:a:0"])
            case .preserve:
                arguments.append(contentsOf: ["-map", "0:a:0", "-map", "0:v?"])
                mapsAudioOnly = false
            case .compatReembed:
                do {
                    let compatibleArtwork = try artworkPreparer.prepareCompatibleArtwork(asset: artwork, profile: queued.preset.deviceProfile)
                    let artworkTempURL = try writeTemporaryArtwork(compatibleArtwork.data)
                    temporaryFiles.append(artworkTempURL)

                    arguments.append(contentsOf: ["-i", artworkTempURL.path])
                    arguments.append(contentsOf: ["-map", "0:a:0", "-map", "1:v:0", "-c:v", "mjpeg", "-disposition:v", "attached_pic"])
                    mapsAudioOnly = false
                } catch {
                    warning = "Artwork conversion failed. Continuing without embedded artwork: \(error.localizedDescription)"
                    arguments.append(contentsOf: ["-map", "0:a:0"])
                }
            }
        } else {
            switch queued.preset.artworkMode {
            case .preserve:
                arguments.append(contentsOf: ["-map", "0:a:0", "-map", "0:v?"])
                mapsAudioOnly = false
            case .compatReembed, .none:
                arguments.append(contentsOf: ["-map", "0:a:0"])
            }
        }

        applyCodecArguments(to: &arguments, preset: queued.preset)
        applyTagArguments(to: &arguments, preset: queued.preset)
        applyMetadataArguments(to: &arguments, metadata: queued.job.metadata)

        if mapsAudioOnly {
            arguments.append(contentsOf: ["-vn"])
        }

        arguments.append(queued.job.destinationURL.path)

        return PreparedConversionCommand(
            executableURL: ffmpegExecutableURL,
            arguments: arguments,
            warning: warning,
            temporaryFiles: temporaryFiles
        )
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
            break
        case .id3v23:
            arguments.append(contentsOf: ["-id3v2_version", "3", "-write_id3v1", "1"])
        case .mp4Atoms:
            arguments.append(contentsOf: ["-movflags", "use_metadata_tags"])
        }
    }

    private func applyMetadataArguments(to arguments: inout [String], metadata: ConversionMetadata?) {
        guard let metadata else {
            return
        }

        func add(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else {
                return
            }
            arguments.append(contentsOf: ["-metadata", "\(key)=\(value)"])
        }

        add("title", metadata.title)
        add("artist", metadata.artist)
        add("album", metadata.album)

        if let trackNumber = metadata.trackNumber {
            add("track", "\(trackNumber)")
        }

        if let discNumber = metadata.discNumber {
            add("disc", "\(discNumber)")
        }

        if let year = metadata.year {
            add("date", "\(year)")
        }

        add("genre", metadata.genre)
        add("comment", metadata.comment)
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
        let tempURL = fileManager.temporaryDirectory
            .appendingPathComponent("cratedigger-artwork-\(UUID().uuidString)")
            .appendingPathExtension("jpg")

        try data.write(to: tempURL, options: .atomic)
        return tempURL
    }

    private static func resolvedPreset(
        id: String,
        from presetMap: [String: ConversionPreset],
        overrideDeviceProfile: DeviceProfile?
    ) -> ConversionPreset? {
        guard var preset = presetMap[id] else {
            return nil
        }

        if let overrideDeviceProfile {
            preset = ConversionPreset(
                id: preset.id,
                name: preset.name,
                outputFormat: preset.outputFormat,
                bitrateKbps: preset.bitrateKbps,
                sampleRateHz: preset.sampleRateHz,
                channels: preset.channels,
                constantBitrate: preset.constantBitrate,
                deviceProfile: overrideDeviceProfile,
                tagMode: preset.tagMode,
                artworkMode: preset.artworkMode
            )
        }

        return preset
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
