import Foundation

/// One file's Chromaprint fingerprint, as `fpcalc` reports it.
public struct AudioFingerprint: Equatable, Sendable {
    public let fileURL: URL
    /// Whole-file runtime, rounded to the second. AcoustID matches on duration
    /// as well as the fingerprint, and only accepts whole seconds.
    public let durationSeconds: Int
    /// The compressed Chromaprint string, ready to post as-is.
    public let fingerprint: String

    public init(fileURL: URL, durationSeconds: Int, fingerprint: String) {
        self.fileURL = fileURL
        self.durationSeconds = durationSeconds
        self.fingerprint = fingerprint
    }
}

public enum AudioFingerprintError: Error, Equatable {
    case commandFailed(Int32, String)
    case unreadableOutput
    /// fpcalc read the file but found no audio to fingerprint (a zero-length
    /// or corrupt file), which AcoustID would reject anyway.
    case emptyFingerprint
}

/// Fingerprints audio files with `fpcalc` (Chromaprint) — the input half of
/// DEEP SCAN.
///
/// Identifying a track by its sound is the only thing that works when its tags
/// are blank or wrong, which is exactly the case text search cannot serve.
///
/// The argument vector and the output parse are pure and unit-tested against a
/// fake `CommandRunning`; only `fingerprint(_:)` spawns a process. It blocks
/// while fpcalc decodes, so callers must go through `BlockingWork` rather than
/// calling it from the cooperative pool.
///
/// `@unchecked Sendable` for the same reason as `StreamResolver`: the only
/// non-Sendable member is the injected runner, which in production is the
/// stateless `ProcessCommandRunner`.
public struct AudioFingerprintService: @unchecked Sendable {

    /// How much audio fpcalc reads. 120 seconds is the AcoustID reference
    /// client's default and what the server's index was built against —
    /// shortening it saves little decode time and costs matches.
    public static let sampleSeconds = 120

    private let fpcalcURL: URL
    private let runner: CommandRunning

    public init(fpcalcURL: URL, runner: CommandRunning = ProcessCommandRunner(timeoutSeconds: 30)) {
        self.fpcalcURL = fpcalcURL
        self.runner = runner
    }

    /// The fpcalc argument vector for one file.
    ///
    /// No `--` terminator: fpcalc hand-rolls its option parsing and rejects one
    /// as an unknown flag. It isn't needed either, since a file URL's `path` is
    /// always absolute and so can never begin with a dash.
    public static func arguments(for fileURL: URL) -> [String] {
        ["-json", "-length", String(sampleSeconds), fileURL.path]
    }

    public func fingerprint(_ fileURL: URL) throws -> AudioFingerprint {
        let output = try runner.run(executableURL: fpcalcURL, arguments: Self.arguments(for: fileURL))
        guard output.terminationStatus == 0 else {
            throw AudioFingerprintError.commandFailed(output.terminationStatus, output.standardError)
        }
        let parsed = try Self.parse(output.standardOutput)
        return AudioFingerprint(
            fileURL: fileURL,
            durationSeconds: parsed.durationSeconds,
            fingerprint: parsed.fingerprint
        )
    }

    /// fpcalc's `-json` output: `{"duration": 292.28, "fingerprint": "AQAD..."}`.
    static func parse(_ standardOutput: String) throws -> (durationSeconds: Int, fingerprint: String) {
        guard let data = standardOutput.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { throw AudioFingerprintError.unreadableOutput }

        let trimmed = payload.fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, payload.duration > 0 else {
            throw AudioFingerprintError.emptyFingerprint
        }
        return (Int(payload.duration.rounded()), trimmed)
    }

    private struct Payload: Decodable {
        let duration: Double
        let fingerprint: String
    }
}
