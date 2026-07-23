import Foundation

/// Sendable because a scan probes files concurrently — one probe per core — and
/// has always shared a single prober across those tasks. A conformer must be a
/// stateless executor: no mutable state observed across `probe` calls.
public protocol MetadataProbing: Sendable {
    func probe(url: URL) throws -> ProbedMetadata
}

public enum MetadataProbeError: Error {
    case executableMissing(URL)
    case commandFailed(String)
    case decodingFailed(String)
}

extension MetadataProbeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .executableMissing(let url):
            return "ffprobe was not found at \(url.path)."
        case .commandFailed(let message):
            return "ffprobe failed: \(message)"
        case .decodingFailed(let message):
            return "ffprobe output could not be decoded: \(message)"
        }
    }
}

public struct ProbedStreamMetadata: Codable, Hashable, Sendable {
    public let index: Int
    public let codecType: String?
    public let codecName: String?
    public let sampleRateHz: Int?
    public let bitRateBps: Int?
    public let tags: [String: String]
    public let dispositions: [String: Int]

    public init(
        index: Int,
        codecType: String?,
        codecName: String? = nil,
        sampleRateHz: Int? = nil,
        bitRateBps: Int? = nil,
        tags: [String: String],
        dispositions: [String: Int]
    ) {
        self.index = index
        self.codecType = codecType
        self.codecName = codecName
        self.sampleRateHz = sampleRateHz
        self.bitRateBps = bitRateBps
        self.tags = tags
        self.dispositions = dispositions
    }
}

public struct ProbedMetadata: Codable, Hashable, Sendable {
    public let formatName: String?
    public let formatBitRateBps: Int?
    public let formatTags: [String: String]
    public let streams: [ProbedStreamMetadata]

    public init(
        formatName: String? = nil,
        formatBitRateBps: Int? = nil,
        formatTags: [String: String],
        streams: [ProbedStreamMetadata]
    ) {
        self.formatName = formatName
        self.formatBitRateBps = formatBitRateBps
        self.formatTags = formatTags
        self.streams = streams
    }

    public var primaryAudioStream: ProbedStreamMetadata? {
        streams.first { $0.codecType == "audio" }
    }
}

/// `@unchecked` only because `commandRunner` is an existential the compiler
/// can't verify; every stored property is a `let`, and running a subprocess
/// keeps no state between calls.
public final class MetadataProbeService: MetadataProbing, @unchecked Sendable {
    private let ffprobeExecutableURL: URL
    private let commandRunner: CommandRunning
    public let resolvedTool: ResolvedExternalTool

    public init(
        ffprobeExecutableURL: URL? = nil,
        // 30s guard: a probe is normally milliseconds, but one wedged ffprobe
        // (exotic file, stalling volume) must not hang an entire library scan.
        // On timeout the probe fails and the scan falls back to AVFoundation
        // metadata for that file.
        commandRunner: CommandRunning = ProcessCommandRunner(timeoutSeconds: 30),
        fileManager: FileManager = .default
    ) throws {
        self.commandRunner = commandRunner
        let locator = ExternalToolLocator(fileManager: fileManager)
        let resolvedTool: ResolvedExternalTool
        do {
            resolvedTool = try locator.resolveRequired(.ffprobe, explicitOverride: ffprobeExecutableURL)
        } catch {
            throw MetadataProbeError.executableMissing(ffprobeExecutableURL ?? URL(fileURLWithPath: "ffprobe"))
        }
        self.resolvedTool = resolvedTool
        self.ffprobeExecutableURL = resolvedTool.url
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
                formatName: decoded.format?.formatName,
                formatBitRateBps: decoded.format?.bitRate.flatMap(Self.parseInt),
                formatTags: decoded.format?.tags ?? [:],
                streams: decoded.streams.map {
                    ProbedStreamMetadata(
                        index: $0.index ?? 0,
                        codecType: $0.codecType,
                        codecName: $0.codecName,
                        sampleRateHz: $0.sampleRate.flatMap(Self.parseInt),
                        bitRateBps: $0.bitRate.flatMap(Self.parseInt),
                        tags: $0.tags ?? [:],
                        dispositions: $0.disposition ?? [:]
                    )
                }
            )
        } catch {
            throw MetadataProbeError.decodingFailed(error.localizedDescription)
        }
    }

    private static func parseInt(_ value: String) -> Int? {
        let digits = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !digits.isEmpty else {
            return nil
        }
        return Int(digits)
    }
}

private struct FFprobePayload: Decodable {
    let streams: [FFprobeStream]
    let format: FFprobeFormat?
}

private struct FFprobeFormat: Decodable {
    let formatName: String?
    let bitRate: String?
    let tags: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case formatName = "format_name"
        case bitRate = "bit_rate"
        case tags
    }
}

private struct FFprobeStream: Decodable {
    let index: Int?
    let codecType: String?
    let codecName: String?
    let sampleRate: String?
    let bitRate: String?
    let tags: [String: String]?
    let disposition: [String: Int]?

    private enum CodingKeys: String, CodingKey {
        case index
        case codecType = "codec_type"
        case codecName = "codec_name"
        case sampleRate = "sample_rate"
        case bitRate = "bit_rate"
        case tags
        case disposition
    }
}
