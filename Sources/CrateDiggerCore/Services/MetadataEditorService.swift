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
        let tempURL = Self.temporaryURL(beside: fileURL, purpose: "edit")

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

        arguments += Self.outputFormatArguments(for: fileURL)
        arguments.append(tempURL.path)

        let output = try commandRunner.run(executableURL: ffmpegExecutableURL, arguments: arguments)
        guard output.terminationStatus == 0 else {
            // Clean up temp file if created
            try? fileManager.removeItem(at: tempURL)
            throw NSError(domain: "MetadataEditorService", code: Int(output.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: Self.failureReason(output)])
        }

        // Replace original file with temporary file
        try replace(fileURL, with: tempURL)
    }

    public func embedArtwork(to fileURL: URL, imageURL: URL) throws {
        let tempURL = Self.temporaryURL(beside: fileURL, purpose: "art-edit")

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

        arguments += Self.outputFormatArguments(for: fileURL)
        arguments.append(tempURL.path)

        let output = try commandRunner.run(executableURL: ffmpegExecutableURL, arguments: arguments)
        guard output.terminationStatus == 0 else {
            try? fileManager.removeItem(at: tempURL)
            throw NSError(domain: "MetadataEditorService", code: Int(output.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't embed the artwork — " + Self.failureReason(output)])
        }

        try replace(fileURL, with: tempURL)
    }

    /// Strip every attached picture from a file, keeping the audio stream and
    /// the rest of the tags untouched.
    ///
    /// The inverse of `embedArtwork`, and the reason the ART view can offer to
    /// delete embedded art: `-vn` drops the attached_pic stream, `-c copy`
    /// means the audio is not re-encoded, so this costs a file rewrite and no
    /// quality. The picture itself is gone for good afterwards.
    public func stripArtwork(from fileURL: URL) throws {
        let tempURL = Self.temporaryURL(beside: fileURL, purpose: "art-strip")

        let output = try commandRunner.run(
            executableURL: ffmpegExecutableURL,
            arguments: Self.stripArtworkArguments(input: fileURL, output: tempURL)
        )
        guard output.terminationStatus == 0 else {
            try? fileManager.removeItem(at: tempURL)
            throw NSError(domain: "MetadataEditorService", code: Int(output.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't remove the artwork — " + Self.failureReason(output)])
        }

        try replace(fileURL, with: tempURL)
    }

    // MARK: - Temporary files

    /// Where ffmpeg writes the rewritten file before it replaces the original:
    /// beside it (so the replace is a rename on the same volume), hidden, and
    /// ending `.cdtmp`, never in an audio extension.
    ///
    /// The old name, `cratedigger-art-edit-<UUID>.m4a`, was named like music.
    /// A rewrite cut off by a quit left an empty one beside the album, and
    /// both CrateDigger's scan and PodBox's took it for a track (PodBox even
    /// reads dot-files with an audio extension, which is the whole `._`
    /// story). A dot-name ending `.cdtmp` is neither scanner's: the library
    /// scan skips hidden files, and nothing reads `.cdtmp` as audio. ffmpeg
    /// cannot guess a muxer from `.cdtmp`, so `outputFormatArguments` names
    /// it; a format it has no name for keeps the real extension, still hidden.
    static func temporaryURL(beside fileURL: URL, purpose: String) -> URL {
        let stem = ".cratedigger-\(purpose)-\(UUID().uuidString)"
        let ext = outputMuxer(for: fileURL) == nil ? fileURL.pathExtension : temporaryExtension
        return fileURL.deletingLastPathComponent().appendingPathComponent(stem).appendingPathExtension(ext)
    }

    static let temporaryExtension = "cdtmp"

    /// The muxer ffmpeg would have picked from the file's own extension,
    /// named, since the temporary file's `.cdtmp` says nothing. nil for a
    /// format with no muxer here (the temporary file then keeps the real
    /// extension and ffmpeg guesses, as it always did).
    static func outputMuxer(for fileURL: URL) -> String? {
        switch fileURL.pathExtension.lowercased() {
        case "m4a", "m4b", "m4v": return "ipod"
        case "mp4": return "mp4"
        case "mov": return "mov"
        case "mp3": return "mp3"
        case "flac": return "flac"
        case "ogg", "oga": return "ogg"
        case "opus": return "opus"
        case "wav": return "wav"
        case "aif", "aiff", "aifc": return "aiff"
        case "wma", "asf": return "asf"
        case "wv": return "wv"
        case "mka": return "matroska"
        default: return nil
        }
    }

    static func outputFormatArguments(for fileURL: URL) -> [String] {
        outputMuxer(for: fileURL).map { ["-f", $0] } ?? []
    }

    /// The original replaced by the rewritten file; the temporary file is
    /// removed when the replace fails, so a failure leaves nothing behind.
    private func replace(_ fileURL: URL, with tempURL: URL) throws {
        var resultingURL: NSURL?
        do {
            try fileManager.replaceItem(at: fileURL, withItemAt: tempURL, backupItemName: nil, options: [],
                                        resultingItemURL: &resultingURL)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
    }

    /// Pure argument vector, so the flags that decide whether the audio
    /// survives are testable without running ffmpeg.
    static func stripArtworkArguments(input: URL, output: URL) -> [String] {
        var arguments = [
            "-hide_banner",
            "-nostdin",
            "-y",
            "-i", input.path,
            "-map", "0:a",      // audio only: the attached picture is a video stream
            "-c", "copy",       // never re-encode; this is a tag edit, not a conversion
            "-map_metadata", "0",
            "-vn"
        ]
        if input.pathExtension.lowercased() == "mp3" {
            arguments.append(contentsOf: ["-id3v2_version", "3"])
        }
        arguments += outputFormatArguments(for: input)
        arguments.append(output.path)
        return arguments
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
