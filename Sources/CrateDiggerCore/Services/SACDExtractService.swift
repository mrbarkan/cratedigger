import Foundation

/// SACD ISOs can't be mounted by macOS; the reliable tell is the Master TOC
/// magic "SACDMTOC" at sector 510 (verified against a real disc image).
public enum SACDISOInspector {
    private static let magic = Data("SACDMTOC".utf8)
    private static let masterTOCOffset: UInt64 = 510 * 2048

    public static func isSACDISO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: masterTOCOffset)) != nil,
              let bytes = try? handle.read(upToCount: magic.count) else { return false }
        return bytes == magic
    }
}

public struct SACDTrackInfo: Equatable, Sendable {
    public let number: Int
    public let title: String
    public let performer: String
    public let durationSeconds: Double
}

public struct SACDDiscInfo: Equatable, Sendable {
    public let albumTitle: String
    public let albumArtist: String
    public let year: Int?
    public let stereoTracks: [SACDTrackInfo]
}

/// Parses `sacd_extract -P` text output. Line-oriented on purpose — the tool's
/// format is stable, tab-indented `Key: Value` lines with per-area blocks; only
/// the 2-channel (stereo) area's track list matters. Track numbers are the
/// 1-based list positions, matching `-t` selection and the extractor's
/// "NN - Title.dsf" file naming.
public enum SACDMetadataParser {
    public static func parse(_ output: String) -> SACDDiscInfo? {
        var albumTitle = "", albumArtist = ""
        var year: Int?
        var inAlbumBlock = false
        var inStereoArea = false
        var tracks: [SACDTrackInfo] = []
        // Track fields arrive as Title[i]: / Performer[i]: / Duration: runs.
        var pendingTitle: String?
        var pendingPerformer = ""

        func value(of line: Substring, after key: String) -> String? {
            guard line.hasPrefix(key) else { return nil }
            return line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
        }

        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.drop(while: { $0 == "\t" || $0 == " " })
            if line.hasPrefix("Disc Information:") { inAlbumBlock = false }
            if line.hasPrefix("Album Information:") { inAlbumBlock = true }
            if line.hasPrefix("Area Information [") {
                inStereoArea = false   // until this area proves 2 Channel
                pendingTitle = nil
                pendingPerformer = ""
            }
            if let config = value(of: line, after: "Speaker config:") {
                inStereoArea = config.hasPrefix("2 Channel")
            }
            if let date = value(of: line, after: "Creation date:"), year == nil {
                year = Int(date.prefix(4))
            }
            if let title = value(of: line, after: "Title:") {
                // Disc block sets it first; the Album block's Title overrides.
                if inAlbumBlock || albumTitle.isEmpty { albumTitle = title }
            }
            if let artist = value(of: line, after: "Artist:") {
                if inAlbumBlock || albumArtist.isEmpty { albumArtist = artist }
            }
            guard inStereoArea else { continue }
            if line.hasPrefix("Title["), let range = line.range(of: "]: ") {
                pendingTitle = String(line[range.upperBound...])
                pendingPerformer = ""
            }
            if line.hasPrefix("Performer["), let range = line.range(of: "]: ") {
                pendingPerformer = String(line[range.upperBound...])
            }
            if let duration = value(of: line, after: "Duration:"), let title = pendingTitle {
                // "MM:SS:FF [mins:secs:frames]" — 75 frames/sec, like CD.
                let parts = duration.split(separator: " ").first?.split(separator: ":") ?? []
                if parts.count == 3, let m = Double(parts[0]), let s = Double(parts[1]),
                   let f = Double(parts[2]) {
                    tracks.append(SACDTrackInfo(number: tracks.count + 1, title: title,
                                                performer: pendingPerformer,
                                                durationSeconds: m * 60 + s + f / 75.0))
                    pendingTitle = nil
                    pendingPerformer = ""
                }
            }
        }
        guard !tracks.isEmpty else { return nil }
        return SACDDiscInfo(albumTitle: albumTitle, albumArtist: albumArtist,
                            year: year, stereoTracks: tracks)
    }
}

public enum SACDExtractError: Error, LocalizedError {
    case toolFailed(String)
    case noMetadata
    case noOutputProduced

    public var errorDescription: String? {
        switch self {
        case .toolFailed(let stderr): return "sacd_extract failed: \(stderr)"
        case .noMetadata: return "Could not read the SACD's table of contents."
        case .noOutputProduced: return "sacd_extract completed but produced no DSF files."
        }
    }
}

/// Drives a user-installed sacd_extract binary: reads disc metadata (-P) and
/// extracts stereo tracks to tagged DSF files, one subprocess run per track so
/// progress and cancellation land between tracks (the ConversionService model).
public final class SACDExtractService {
    private let toolURL: URL
    private let commandRunner: CommandRunning
    /// sacd_extract blocks its thread (spawn + wait). Keep it OFF the Swift
    /// cooperative pool — same rule as FFmpegDSDDecoder.decodeQueue.
    private static let workQueue = DispatchQueue(label: "com.cratedigger.sacd-extract",
                                                 qos: .userInitiated)
    private var isCancelled = false

    public init(toolURL: URL, commandRunner: CommandRunning = ProcessCommandRunner()) {
        self.toolURL = toolURL
        self.commandRunner = commandRunner
    }

    public static func printArguments(iso: URL) -> [String] {
        ["-P", "-i", iso.path]
    }

    /// -s DSF output, -2 stereo area, -c DST→DSD decompress, one track per run.
    public static func extractArguments(iso: URL, trackNumber: Int, outputDir: URL) -> [String] {
        ["-s", "-2", "-c", "-t", String(trackNumber), "-i", iso.path, "-y", outputDir.path]
    }

    public func cancel() {
        Self.workQueue.async { self.isCancelled = true }
    }

    public func readDiscInfo(iso: URL, completion: @escaping (Result<SACDDiscInfo, Error>) -> Void) {
        let runner = commandRunner
        let tool = toolURL
        Self.workQueue.async {
            do {
                let output = try runner.run(executableURL: tool,
                                            arguments: Self.printArguments(iso: iso))
                guard output.terminationStatus == 0 else {
                    return completion(.failure(SACDExtractError.toolFailed(output.standardError)))
                }
                guard let disc = SACDMetadataParser.parse(output.standardOutput) else {
                    return completion(.failure(SACDExtractError.noMetadata))
                }
                completion(.success(disc))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Extracts each requested stereo track into `destination` (flat — the
    /// tool's "<Album>/Stereo/" nesting is not the caller's concern).
    /// `onTrackDone(completed, total)` fires after each track; both callbacks
    /// run on the work queue.
    public func extractStereoTracks(iso: URL,
                                    trackNumbers: [Int],
                                    to destination: URL,
                                    onTrackDone: @escaping (Int, Int) -> Void,
                                    completion: @escaping (Result<[URL], Error>) -> Void) {
        let runner = commandRunner
        let tool = toolURL
        Self.workQueue.async { [weak self] in
            let fm = FileManager.default
            self?.isCancelled = false
            // Extract into a private staging dir, then flatten into destination.
            let staging = fm.temporaryDirectory
                .appendingPathComponent("cratedigger-sacd-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: staging) }
            var produced: [URL] = []
            do {
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                for (index, track) in trackNumbers.enumerated() {
                    if self?.isCancelled == true { break }
                    let output = try runner.run(
                        executableURL: tool,
                        arguments: Self.extractArguments(iso: iso, trackNumber: track,
                                                         outputDir: staging))
                    guard output.terminationStatus == 0 else {
                        throw SACDExtractError.toolFailed(output.standardError)
                    }
                    produced.append(contentsOf: try Self.relocateNewDSFs(from: staging,
                                                                         to: destination,
                                                                         fileManager: fm))
                    onTrackDone(index + 1, trackNumbers.count)
                }
                guard !produced.isEmpty else { throw SACDExtractError.noOutputProduced }
                completion(.success(produced))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Move every .dsf anywhere under `staging` into `destination` (flat).
    private static func relocateNewDSFs(from staging: URL, to destination: URL,
                                        fileManager fm: FileManager) throws -> [URL] {
        var moved: [URL] = []
        let files = fm.enumerator(at: staging, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "dsf" } ?? []
        for file in files {
            let dest = destination.appendingPathComponent(file.lastPathComponent)
            // Never overwrite an existing rip; re-running an import skips dupes.
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: file)
            } else {
                try fm.moveItem(at: file, to: dest)
                moved.append(dest)
            }
        }
        return moved
    }
}
