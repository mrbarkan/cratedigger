import Foundation

public protocol MetadataProbing {
    func probe(url: URL) throws -> ProbedMetadata
}

public enum MetadataProbeError: Error {
    case executableMissing(URL)
    case commandFailed(String)
    case decodingFailed(String)
}

public struct ProbedStreamMetadata: Codable, Hashable, Sendable {
    public let index: Int
    public let codecType: String?
    public let tags: [String: String]
    public let dispositions: [String: Int]

    public init(index: Int, codecType: String?, tags: [String: String], dispositions: [String: Int]) {
        self.index = index
        self.codecType = codecType
        self.tags = tags
        self.dispositions = dispositions
    }
}

public struct ProbedMetadata: Codable, Hashable, Sendable {
    public let formatTags: [String: String]
    public let streams: [ProbedStreamMetadata]

    public init(formatTags: [String: String], streams: [ProbedStreamMetadata]) {
        self.formatTags = formatTags
        self.streams = streams
    }

    public var hasAttachedArtworkStream: Bool {
        streams.contains { stream in
            let attachedPicValue = stream.dispositions["attached_pic"] ?? 0
            if attachedPicValue == 1 {
                return true
            }

            if stream.codecType == "video",
               let comment = stream.tags["comment"]?.lowercased(),
               comment.contains("cover") {
                return true
            }

            return false
        }
    }

    public var allStreamTags: [[String: String]] {
        streams.map(\.tags)
    }

    public var allStreamDispositions: [[String: Int]] {
        streams.map(\.dispositions)
    }
}

public final class MetadataProbeService: MetadataProbing {
    private let ffprobeExecutableURL: URL
    private let commandRunner: CommandRunning
    private let fileManager: FileManager

    public init(
        ffprobeExecutableURL: URL? = nil,
        commandRunner: CommandRunning = ProcessCommandRunner(),
        fileManager: FileManager = .default
    ) throws {
        self.commandRunner = commandRunner
        self.fileManager = fileManager

        let executable = ffprobeExecutableURL ?? Self.defaultFFprobeExecutableURL(fileManager: fileManager)
        guard fileManager.fileExists(atPath: executable.path) else {
            throw MetadataProbeError.executableMissing(executable)
        }
        self.ffprobeExecutableURL = executable
    }

    public func probe(url: URL) throws -> ProbedMetadata {
        let output = try commandRunner.run(
            executableURL: ffprobeExecutableURL,
            arguments: ["-v", "error", "-show_format", "-show_streams", "-of", "json", url.path]
        )

        guard output.terminationStatus == 0 else {
            let message = output.standardError.isEmpty ? output.standardOutput : output.standardError
            throw MetadataProbeError.commandFailed(message)
        }

        let payload = output.standardOutput.isEmpty ? output.standardError : output.standardOutput
        guard let data = payload.data(using: .utf8) else {
            throw MetadataProbeError.decodingFailed("ffprobe output was not valid UTF-8.")
        }

        do {
            let decoded = try JSONDecoder().decode(FFprobePayload.self, from: data)
            return ProbedMetadata(
                formatTags: decoded.format?.tags ?? [:],
                streams: decoded.streams.map {
                    ProbedStreamMetadata(
                        index: $0.index ?? 0,
                        codecType: $0.codecType,
                        tags: $0.tags ?? [:],
                        dispositions: $0.disposition ?? [:]
                    )
                }
            )
        } catch {
            throw MetadataProbeError.decodingFailed(error.localizedDescription)
        }
    }

    private static func defaultFFprobeExecutableURL(fileManager: FileManager) -> URL {
        let candidatePaths = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/ffprobe").path,
            "/opt/homebrew/bin/ffprobe",
            "/usr/local/bin/ffprobe",
            "/usr/bin/ffprobe"
        ]

        for path in candidatePaths where fileManager.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        return URL(fileURLWithPath: candidatePaths[0])
    }
}

private struct FFprobePayload: Decodable {
    let streams: [FFprobeStream]
    let format: FFprobeFormat?
}

private struct FFprobeFormat: Decodable {
    let tags: [String: String]?
}

private struct FFprobeStream: Decodable {
    let index: Int?
    let codecType: String?
    let tags: [String: String]?
    let disposition: [String: Int]?

    private enum CodingKeys: String, CodingKey {
        case index
        case codecType = "codec_type"
        case tags
        case disposition
    }
}
