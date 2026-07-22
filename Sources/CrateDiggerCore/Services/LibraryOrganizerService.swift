import Foundation

public final class LibraryOrganizerService {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    private func commonAncestorDirectory(for urls: [URL]) -> URL? {
        guard let first = urls.first else { return nil }
        var commonComponents = first.deletingLastPathComponent().standardizedFileURL.pathComponents
        for url in urls.dropFirst() {
            let parts = url.deletingLastPathComponent().standardizedFileURL.pathComponents
            var n = 0
            while n < commonComponents.count, n < parts.count, commonComponents[n] == parts[n] {
                n += 1
            }
            commonComponents = Array(commonComponents.prefix(n))
            if commonComponents.isEmpty { return nil }
        }
        if commonComponents.isEmpty { return nil }
        return URL(fileURLWithPath: "/" + commonComponents.dropFirst().joined(separator: "/"))
    }

    /// The outcome of an organize pass. `tracks` always contains every input
    /// track — moved/copied ones repointed at their new URL, failed or skipped
    /// ones unchanged — so callers can rewrite crate references even after a
    /// partial failure instead of stranding already-moved files.
    public struct OrganizeResult: Sendable {
        public let tracks: [LoadedTrack]
        /// Human-readable per-file failures ("name.flac: reason"). Empty on success.
        public let failures: [String]
    }

    public enum OrganizeError: LocalizedError {
        case partialFailure([String])
        public var errorDescription: String? {
            guard case .partialFailure(let failures) = self else { return nil }
            return "\(failures.count) file(s) could not be organised:\n" + failures.joined(separator: "\n")
        }
    }

    /// Legacy throwing wrapper. Unlike the old behavior it finishes the whole
    /// batch before throwing, but a throw still discards the repointed tracks —
    /// batch callers should use `organizeReportingFailures` instead.
    @discardableResult
    public func organize(
        tracks: [LoadedTrack],
        destinationFolder: URL,
        copyOnly: Bool = false,
        organiseByAlbumArtist: Bool = true,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [LoadedTrack] {
        let result = await organizeReportingFailures(
            tracks: tracks, destinationFolder: destinationFolder, copyOnly: copyOnly,
            organiseByAlbumArtist: organiseByAlbumArtist, onProgress: onProgress
        )
        guard result.failures.isEmpty else { throw OrganizeError.partialFailure(result.failures) }
        return result.tracks
    }

    public func organizeReportingFailures(
        tracks: [LoadedTrack],
        destinationFolder: URL,
        copyOnly: Bool = false,
        organiseByAlbumArtist: Bool = true,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> OrganizeResult {
        let total = tracks.count
        var count = 0
        var failures: [String] = []
        var updatedTracks: [LoadedTrack] = []
        updatedTracks.reserveCapacity(tracks.count)

        let commonAncestor = organiseByAlbumArtist ? nil : commonAncestorDirectory(for: tracks.map { $0.track.fileURL })

        var processedPairs: Set<String> = []
        var uniqueSourceDirs: Set<URL> = []

        for track in tracks {
            let fileURL = track.track.fileURL
            guard fileManager.fileExists(atPath: fileURL.path) else {
                count += 1
                onProgress?(count, total)
                updatedTracks.append(track)
                continue
            }

            let targetURL: URL
            let targetDir: URL
            let fileExtension = fileURL.pathExtension

            if organiseByAlbumArtist {
                // Extract tags with fallbacks
                let artist = track.metadata.albumArtist ?? track.metadata.artist ?? track.track.artist
                let album = track.metadata.album ?? track.track.album
                let year = track.metadata.year.map(String.init) ?? ""
                let trackNum = track.metadata.trackNumber ?? track.track.trackNumber ?? 0
                let title = track.metadata.title ?? track.track.title

                let artistFolder = PathComponentSanitizer.sanitize(artist, fallback: "Unknown Artist")

                let albumFolderName: String
                let sanitizedAlbum = PathComponentSanitizer.sanitize(album, fallback: "Unknown Album")
                if !year.isEmpty {
                    albumFolderName = "[\(year)] - \(sanitizedAlbum)"
                } else {
                    albumFolderName = sanitizedAlbum
                }

                let trackPrefix = trackNum > 0 ? String(format: "%02d - ", trackNum) : ""
                let sanitizedTitle = PathComponentSanitizer.sanitize(title, fallback: "Track")
                let fileName = "\(trackPrefix)\(sanitizedTitle).\(fileExtension)"

                targetDir = destinationFolder
                    .appendingPathComponent(artistFolder, isDirectory: true)
                    .appendingPathComponent(albumFolderName, isDirectory: true)
                targetURL = targetDir.appendingPathComponent(fileName)
            } else {
                // Keep the relative structure from commonAncestor
                if let ancestor = commonAncestor, fileURL.path.hasPrefix(ancestor.path) {
                    let relativeComponents = Array(fileURL.pathComponents.dropFirst(ancestor.pathComponents.count))
                    if relativeComponents.isEmpty {
                        targetURL = destinationFolder.appendingPathComponent(fileURL.lastPathComponent)
                        targetDir = destinationFolder
                    } else {
                        targetURL = destinationFolder.appendingPathComponent(relativeComponents.joined(separator: "/"))
                        targetDir = targetURL.deletingLastPathComponent()
                    }
                } else {
                    targetURL = destinationFolder.appendingPathComponent(fileURL.lastPathComponent)
                    targetDir = destinationFolder
                }
            }

            do {
                try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)
            } catch {
                failures.append("\(fileURL.lastPathComponent): \(error.localizedDescription)")
                updatedTracks.append(track)
                count += 1
                onProgress?(count, total)
                continue
            }

            // Handle name collision
            var attempt = 1
            var uniqueTargetURL = targetURL
            
            // Check if source and target are the same path
            if targetURL.standardizedFileURL.path == fileURL.standardizedFileURL.path {
                count += 1
                onProgress?(count, total)
                updatedTracks.append(track)
                continue
            }
            
            while fileManager.fileExists(atPath: uniqueTargetURL.path) {
                // If it exists but it's the exact same file, we can break or rename
                if uniqueTargetURL.standardizedFileURL.path == fileURL.standardizedFileURL.path {
                    break
                }
                let base = targetURL.deletingPathExtension().lastPathComponent
                let parentDir = targetURL.deletingLastPathComponent()
                uniqueTargetURL = parentDir.appendingPathComponent("\(base) (\(attempt)).\(fileExtension)")
                attempt += 1
            }

            if uniqueTargetURL.standardizedFileURL.path != fileURL.standardizedFileURL.path {
                do {
                    if copyOnly {
                        try fileManager.copyItem(at: fileURL, to: uniqueTargetURL)
                    } else {
                        try fileManager.moveItem(at: fileURL, to: uniqueTargetURL)
                        // Clean up empty parent directories of the original file
                        var originalDir = fileURL.deletingLastPathComponent()
                        while originalDir.path.hasPrefix(destinationFolder.path) || originalDir.pathComponents.count > 3 {
                            let contents = try? fileManager.contentsOfDirectory(atPath: originalDir.path)
                            if let contents, contents.isEmpty {
                                try? fileManager.removeItem(at: originalDir)
                                originalDir = originalDir.deletingLastPathComponent()
                            } else {
                                break
                            }
                        }
                    }
                } catch {
                    // A failed move leaves the file at its source, so the
                    // original (still-valid) track goes back to the caller.
                    failures.append("\(fileURL.lastPathComponent): \(error.localizedDescription)")
                    updatedTracks.append(track)
                    count += 1
                    onProgress?(count, total)
                    continue
                }

                // Copy supporting files (artwork, cue sheets, booklets, logs)
                let sourceDir = fileURL.deletingLastPathComponent()
                let sourceDirPath = sourceDir.standardizedFileURL.path
                let pairKey = "\(sourceDirPath) -> \(targetDir.standardizedFileURL.path)"
                if !processedPairs.contains(pairKey) {
                    processedPairs.insert(pairKey)
                    copySupportingFiles(from: sourceDir, to: targetDir)
                    writeAutoManifestIfMissing(in: targetDir)
                    uniqueSourceDirs.insert(sourceDir)
                }
            }

            // Repoint at the new location via withFileURL so every tag field
            // survives — a hand-rolled copy here once dropped disc numbers and
            // collapsed multi-disc albums into "DISC 1" after a Prep Crate commit.
            // Record Divider markers are time-based, so they stay valid too.
            updatedTracks.append(LoadedTrack(track: track.track.withFileURL(uniqueTargetURL),
                                             metadata: track.metadata,
                                             recordMarkers: track.recordMarkers))

            count += 1
            onProgress?(count, total)
        }

        if !copyOnly {
            for sourceDir in uniqueSourceDirs {
                if fileManager.fileExists(atPath: sourceDir.path), !hasAnyAudioFiles(in: sourceDir) {
                    try? fileManager.removeItem(at: sourceDir)
                    
                    // Clean up empty parent directories
                    var parent = sourceDir.deletingLastPathComponent()
                    while parent.pathComponents.count > 3 {
                        if let contents = try? fileManager.contentsOfDirectory(atPath: parent.path), contents.isEmpty {
                            try? fileManager.removeItem(at: parent)
                            parent = parent.deletingLastPathComponent()
                        } else {
                            break
                        }
                    }
                }
            }
        }

        return OrganizeResult(tracks: updatedTracks, failures: failures)
    }

    private func copySupportingFiles(from sourceDir: URL, to targetDir: URL) {
        guard let contents = try? fileManager.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: nil) else {
            return
        }

        let audioExtensions: Set<String> = ["mp3", "aac", "m4a", "flac", "wav", "aiff", "ogg", "opus", "caf"]

        for item in contents {
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            
            if isDirectory {
                let name = item.lastPathComponent.lowercased()
                let isSupportingFolder = name.contains("art") || name.contains("cover") || name.contains("booklet") || name.contains("scan") || name.contains("doc") || name.contains("extra")
                
                if isSupportingFolder {
                    let destFolder = targetDir.appendingPathComponent(item.lastPathComponent)
                    if !fileManager.fileExists(atPath: destFolder.path) {
                        try? fileManager.copyItem(at: item, to: destFolder)
                    }
                }
            } else {
                let ext = item.pathExtension.lowercased()
                if !audioExtensions.contains(ext) {
                    let destFile = targetDir.appendingPathComponent(item.lastPathComponent)
                    if !fileManager.fileExists(atPath: destFile.path) {
                        try? fileManager.copyItem(at: item, to: destFile)
                    }
                }
            }
        }
    }

    /// Freshly imported albums used to land with every image un-roled (AUTO),
    /// which let an arbitrary booklet page become the album's face until the
    /// user sorted the ART grid by hand. Classify once at import — filename
    /// heuristics plus cover promotion — and persist the result. A manifest
    /// that traveled with the files (it's a supporting file) is never touched.
    private func writeAutoManifestIfMissing(in albumDir: URL) {
        guard ArtworkManifest.load(from: albumDir) == nil else { return }
        let images = AlbumArtCatalog.gatherImageURLs(in: albumDir, fileManager: fileManager)
        guard !images.isEmpty else { return }
        try? ArtworkManifest(roles: AlbumArtCatalog.autoClassify(imageURLs: images)).save(to: albumDir)
    }

    private func hasAnyAudioFiles(in dir: URL) -> Bool {
        let enumerator = fileManager.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        let audioExtensions: Set<String> = ["mp3", "aac", "m4a", "flac", "wav", "aiff", "ogg", "opus", "caf"]
        
        while let fileURL = enumerator?.nextObject() as? URL {
            let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDirectory {
                let ext = fileURL.pathExtension.lowercased()
                if audioExtensions.contains(ext) {
                    return true
                }
            }
        }
        return false
    }
}
