import Foundation

public enum DSDDecodeError: Error {
    case ffmpegFailed(String)
}

/// Resolves a format AVFoundation can't decode (DSD/DSF) to a temporary file it
/// can play. The source is never modified.
public protocol DSDPlaybackDecoding: AnyObject {
    func canDecode(_ url: URL) -> Bool
    /// Decodes `url` to a temp PCM file. `completion` runs on an arbitrary queue.
    func decode(_ url: URL, completion: @escaping (Result<URL, Error>) -> Void)
}

public final class FFmpegDSDDecoder: DSDPlaybackDecoding {
    public static let decodableExtensions: Set<String> = ["dsf", "dff"]

    private let ffmpegURL: URL
    private let commandRunner: CommandRunning
    private let targetSampleRateHz: Int

    // ffmpeg's DSD decode blocks its thread (spawn + waitUntilExit). Keep it OFF
    // the Swift cooperative pool — parking pool threads deadlocks the app
    // (see LibraryScanService.probeQueue, same lesson).
    private static let decodeQueue = DispatchQueue(
        label: "com.cratedigger.dsd-decode", qos: .userInitiated, attributes: .concurrent)

    public init(ffmpegURL: URL,
                commandRunner: CommandRunning = ProcessCommandRunner(),
                targetSampleRateHz: Int = 88_200) {
        self.ffmpegURL = ffmpegURL
        self.commandRunner = commandRunner
        self.targetSampleRateHz = targetSampleRateHz
    }

    public convenience init?(commandRunner: CommandRunning = ProcessCommandRunner()) {
        guard let resolved = ExternalToolLocator().resolveOptional(.ffmpeg) else { return nil }
        self.init(ffmpegURL: resolved.url, commandRunner: commandRunner)
    }

    public func canDecode(_ url: URL) -> Bool {
        Self.decodableExtensions.contains(url.pathExtension.lowercased())
    }

    public static func decodeArguments(input: URL, output: URL, sampleRateHz: Int) -> [String] {
        ["-y", "-i", input.path, "-map", "0:a:0",
         "-c:a", "pcm_s24le", "-ar", String(sampleRateHz), "-f", "caf", output.path]
    }

    public func decode(_ url: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("cratedigger-dsd-\(UUID().uuidString).caf")
        let args = Self.decodeArguments(input: url, output: output, sampleRateHz: targetSampleRateHz)
        let runner = commandRunner
        let ffmpeg = ffmpegURL
        Self.decodeQueue.async {
            do {
                let result = try runner.run(executableURL: ffmpeg, arguments: args)
                if result.terminationStatus == 0 {
                    completion(.success(output))
                } else {
                    completion(.failure(DSDDecodeError.ffmpegFailed(result.standardError)))
                }
            } catch {
                completion(.failure(error))
            }
        }
    }
}
