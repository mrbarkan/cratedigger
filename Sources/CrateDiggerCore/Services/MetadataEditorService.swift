import Foundation

public final class MetadataEditorService {
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

    public func writeMetadata(to fileURL: URL, metadata: ConversionMetadata) throws {
        let tempURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("cratedigger-edit-\(UUID().uuidString)")
            .appendingPathExtension(fileURL.pathExtension)

        var arguments = [
            "-hide_banner",
            "-nostdin",
            "-y",
            "-i", fileURL.path
        ]

        // If format is MP4/M4A, ffmpeg sometimes needs special tags, but standard metadata keys work well.
        arguments.append(contentsOf: ["-c", "copy", "-map_metadata", "0"])

        func add(_ key: String, _ value: String?) {
            // In ffmpeg, passing an empty string or null for metadata key deletes it.
            let val = value ?? ""
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
            let message = output.standardError.isEmpty ? output.standardOutput : output.standardError
            throw NSError(domain: "MetadataEditorService", code: Int(output.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "ffmpeg failed: \(message)"])
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
            let message = output.standardError.isEmpty ? output.standardOutput : output.standardError
            throw NSError(domain: "MetadataEditorService", code: Int(output.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "ffmpeg failed to embed artwork: \(message)"])
        }

        var resultingURL: NSURL?
        try fileManager.replaceItem(at: fileURL, withItemAt: tempURL, backupItemName: nil, options: [], resultingItemURL: &resultingURL)
    }
}
