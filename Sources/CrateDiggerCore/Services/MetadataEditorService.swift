import Foundation

// Immutable after init — three `let`s, no mutable state; the only work it does is
// shell out to ffmpeg per call. Safe to share across threads / capture in the
// @Sendable tag-write closure, but the compiler can't prove it because
// CommandRunning and FileManager aren't Sendable-marked — hence @unchecked.
public final class MetadataEditorService: @unchecked Sendable {
    private let ffmpegExecutableURL: URL
    private let commandRunner: CommandRunning
    private let fileManager: FileManager

    public init(
        ffmpegExecutableURL: URL? = nil,
        commandRunner: CommandRunning = ProcessCommandRunner(),
        fileManager: FileManager = .default
    ) throws {
        self.commandRunner = commandRunner
        self.fileManager = fileManager

        let locator = ExternalToolLocator(fileManager: fileManager)
        if let explicit = ffmpegExecutableURL {
            self.ffmpegExecutableURL = explicit
        } else {
            let resolved = try locator.resolveRequired(.ffmpeg)
            self.ffmpegExecutableURL = resolved.url
        }
    }

    /// Writes `metadata` into the file in place.
    ///
    /// Returns `true` if the file's embedded cover had to be dropped to save the
    /// tags at all — callers should say so rather than change the file quietly.
    @discardableResult
    public func writeMetadata(to fileURL: URL, metadata: ConversionMetadata) throws -> Bool {
        do {
            try writeMetadata(to: fileURL, metadata: metadata, keepEmbeddedArtwork: true)
            return false
        } catch {
            // A file whose embedded cover is malformed — JPEG bytes stored under
            // the PNG codec is the common one — can't be remuxed with its picture
            // stream, and the whole tag write fails. The cover is already broken,
            // so rewriting the tags without it beats refusing to save at all.
            AppLog.library.warning("Tag write failed with embedded artwork; retrying without it: \(fileURL.lastPathComponent, privacy: .public)")
            try writeMetadata(to: fileURL, metadata: metadata, keepEmbeddedArtwork: false)
            return true
        }
    }

    private func writeMetadata(to fileURL: URL, metadata: ConversionMetadata, keepEmbeddedArtwork: Bool) throws {
        let tempURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("cratedigger-edit-\(UUID().uuidString)")
            .appendingPathExtension(fileURL.pathExtension)

        var arguments = [
            "-hide_banner",
            "-nostdin",
            "-y",
            "-i", fileURL.path
        ]

        // Map explicitly. Left to itself ffmpeg picks the "best" video stream
        // first, which puts an MP3's attached cover ahead of the audio and the
        // muxer rejects the result ("dimensions not set"). `0:v?` is optional, so
        // files with no cover still work. Dispositions come across with -c copy.
        arguments.append(contentsOf: ["-map", "0:a"])
        if keepEmbeddedArtwork { arguments.append(contentsOf: ["-map", "0:v?"]) }
        arguments.append(contentsOf: ["-c", "copy", "-map_metadata", "0"])

        func add(_ key: String, _ value: String?) {
            // In ffmpeg, passing an empty string or null for metadata key deletes it.
            // Sanitized because a NUL here takes the whole app down (see
            // MetadataNormalization.sanitizedTagValue).
            let val = MetadataNormalization.sanitizedTagValue(value ?? "")
            arguments.append(contentsOf: ["-metadata", "\(key)=\(val)"])
        }

        if let title = metadata.title { add("title", title) }
        if let artist = metadata.artist { add("artist", artist) }
        if let albumArtist = metadata.albumArtist {
            add("album_artist", albumArtist)
            add("albumartist", albumArtist)
        }
        if let album = metadata.album { add("album", album) }
        if let genre = metadata.genre { add("genre", genre) }
        if let comment = metadata.comment { add("comment", comment) }
        
        if let year = metadata.year {
            add("date", String(year))
            add("year", String(year))
        }

        if let trackNumber = metadata.trackNumber {
            if let trackTotal = metadata.trackTotal, trackTotal > 0 {
                add("track", "\(trackNumber)/\(trackTotal)")
            } else {
                add("track", String(trackNumber))
            }
        }

        if let discNumber = metadata.discNumber {
            if let discTotal = metadata.discTotal, discTotal > 0 {
                add("disc", "\(discNumber)/\(discTotal)")
            } else {
                add("disc", String(discNumber))
            }
        }

        if let compilation = metadata.compilation {
            add("compilation", compilation ? "1" : "0")
        }

        for pair in metadata.customTagPairs {
            add(pair.key, pair.value)
        }

        arguments.append(tempURL.path)

        let output = try commandRunner.run(executableURL: ffmpegExecutableURL, arguments: arguments)
        guard output.terminationStatus == 0 else {
            // Clean up temp file if created
            try? fileManager.removeItem(at: tempURL)
            throw NSError(domain: "MetadataEditorService", code: Int(output.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: Self.failureReason(output)])
        }

        // Replace original file with temporary file
        var resultingURL: NSURL?
        try fileManager.replaceItem(at: fileURL, withItemAt: tempURL, backupItemName: nil, options: [], resultingItemURL: &resultingURL)
    }

    public func embedArtwork(to fileURL: URL, imageURL: URL) throws {
        let tempURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("cratedigger-art-edit-\(UUID().uuidString)")
            .appendingPathExtension(fileURL.pathExtension)

        var arguments = [
            "-hide_banner",
            "-nostdin",
            "-y",
            "-i", fileURL.path,
            "-i", imageURL.path,
            "-map", "0:a",
            "-map", "1:0",
            "-c", "copy",
            "-map_metadata", "0",
            "-disposition:v", "attached_pic"
        ]

        if fileURL.pathExtension.lowercased() == "mp3" {
            arguments.append(contentsOf: ["-id3v2_version", "3"])
        }

        arguments.append(tempURL.path)

        let output = try commandRunner.run(executableURL: ffmpegExecutableURL, arguments: arguments)
        guard output.terminationStatus == 0 else {
            try? fileManager.removeItem(at: tempURL)
            throw NSError(domain: "MetadataEditorService", code: Int(output.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't embed the artwork — " + Self.failureReason(output)])
        }

        var resultingURL: NSURL?
        try fileManager.replaceItem(at: fileURL, withItemAt: tempURL, backupItemName: nil, options: [], resultingItemURL: &resultingURL)
    }

    /// One readable sentence out of an ffmpeg failure.
    ///
    /// ffmpeg dumps its full per-stream analysis before it fails — hundreds of
    /// lines. Handing that straight to `NSLocalizedDescriptionKey` put the entire
    /// log into an alert, one copy per failed file, and the sheet ran off the
    /// bottom of the screen. Keep the line that actually says what went wrong.
    static func failureReason(_ output: CommandOutput) -> String {
        let log = output.standardError.isEmpty ? output.standardOutput : output.standardError
        let lines = log
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // "Conversion failed!" is ffmpeg's epitaph, never its diagnosis.
        let markers = ["Error", "error", "Invalid", "Could not", "Unable", "Permission denied",
                       "No such file", "Failed", "failed"]
        let reason = lines.last { line in
            line != "Conversion failed!" && markers.contains(where: { line.contains($0) })
        } ?? lines.last

        guard let reason, !reason.isEmpty else { return "ffmpeg failed with no output." }
        return reason.count > 200 ? String(reason.prefix(200)) + "…" : reason
    }
}
