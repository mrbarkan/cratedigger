import Foundation

public enum DuplicateScanMode: String, Sendable {
    /// Same recording AND same (normalized) album tag — re-rips/re-encodes of
    /// one release. A missing album tag on one copy drops the pair out of
    /// strict; documented ceiling.
    case strict
    /// Same recording anywhere in the library (album + compilation copies).
    case broad
}

public struct DuplicateGroup: Sendable, Identifiable, Hashable {
    public var id: String { bestTrack.track.id.uuidString }
    public let bestTrack: LoadedTrack
    public let worstTracks: [LoadedTrack]

    public init(bestTrack: LoadedTrack, worstTracks: [LoadedTrack]) {
        self.bestTrack = bestTrack
        self.worstTracks = worstTracks
    }
}

public final class LibraryCleanupService {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: - Duplicate match normalization

    /// Decoration tails that don't change the recording. Word-bounded so
    /// "mono" never matches "Monochrome". A bracket group is only stripped
    /// when it contains a decoration keyword AND no different-recording
    /// marker — "(Live Remastered Version)" survives whole: a missed dup
    /// (false negative) is cheaper than trashing a distinct recording.
    private static let decorationKeywords = try! NSRegularExpression(
        pattern: "\\b(remaster(ed)?|reissued?|explicit|deluxe|anniversary|editions?|bonus|mono|stereo)\\b",
        options: [.caseInsensitive]
    )
    private static let protectedKeywords = try! NSRegularExpression(
        pattern: "\\b(live|mix|remix|edit|demo|acoustic|instrumental|dub|session)\\b",
        options: [.caseInsensitive]
    )
    private static let bracketGroup = try! NSRegularExpression(
        pattern: "[\\(\\[][^\\)\\]]*[\\)\\]]"
    )
    private static let featuringToken = try! NSRegularExpression(
        pattern: "\\b(featuring|feat\\.|ft\\.)",
        options: [.caseInsensitive]
    )

    static func normalizeForMatch(_ raw: String) -> String {
        var s = raw.lowercased()

        // Strip decoration-only bracket groups, back to front so ranges stay valid.
        let groups = Self.bracketGroup.matches(in: s, range: NSRange(s.startIndex..., in: s))
        for match in groups.reversed() {
            guard let range = Range(match.range, in: s) else { continue }
            let content = String(s[range])
            let contentRange = NSRange(content.startIndex..., in: content)
            let isDecoration = Self.decorationKeywords.firstMatch(in: content, range: contentRange) != nil
            let isProtected = Self.protectedKeywords.firstMatch(in: content, range: contentRange) != nil
            if isDecoration && !isProtected {
                s.replaceSubrange(range, with: " ")
            }
        }

        s = Self.featuringToken.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "feat"
        )
        s = String(s.map { $0.isLetter || $0.isNumber || $0 == " " ? $0 : " " })
        return s.split(separator: " ").joined(separator: " ")
    }

    /// nil when the title normalizes to nothing — untitled tracks never group.
    static func duplicateMatchKey(artist: String, title: String) -> String? {
        let cleanTitle = normalizeForMatch(title)
        guard !cleanTitle.isEmpty else { return nil }
        return normalizeForMatch(artist) + " :: " + cleanTitle
    }

    public func findDeadTracks(in index: LibraryIndex) -> [LoadedTrack] {
        return index.allTracks.filter { track in
            !fileManager.fileExists(atPath: track.track.fileURL.path)
        }
    }

    public func findDuplicates(in index: LibraryIndex) -> [DuplicateGroup] {
        // Tracks inside a grouped release must only ever match duplicates within the
        // SAME member pressing — never across versions of the same release.
        var versionAlbumOfTrack: [UUID: String] = [:]
        for album in index.allAlbums where album.isVersionGroup {
            for version in album.versions ?? [] {
                for loaded in version.tracks {
                    versionAlbumOfTrack[loaded.track.id] = version.id
                }
            }
        }

        var grouped: [String: [LoadedTrack]] = [:]
        for loadedTrack in index.allTracks {
            let artist = loadedTrack.track.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let title = loadedTrack.track.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !title.isEmpty else { continue }
            let suffix = versionAlbumOfTrack[loadedTrack.track.id].map { " :: \($0)" } ?? ""
            let key = "\(artist) - \(title)\(suffix)"
            grouped[key, default: []].append(loadedTrack)
        }

        var duplicateGroups: [DuplicateGroup] = []
        for (_, tracks) in grouped where tracks.count > 1 {
            let sortedTracks = tracks.sorted { lhs, rhs in isBetterTrack(lhs: lhs, rhs: rhs) }
            if let best = sortedTracks.first {
                duplicateGroups.append(DuplicateGroup(bestTrack: best, worstTracks: Array(sortedTracks.dropFirst())))
            }
        }
        return duplicateGroups.sorted {
            $0.bestTrack.track.title.localizedCaseInsensitiveCompare($1.bestTrack.track.title) == .orderedAscending
        }
    }

    private func isBetterTrack(lhs: LoadedTrack, rhs: LoadedTrack) -> Bool {
        // 1. Format Priority: Lossless > Lossy
        let lhsIsLossless = isLossless(format: lhs.track.formatName ?? "")
        let rhsIsLossless = isLossless(format: rhs.track.formatName ?? "")
        if lhsIsLossless != rhsIsLossless {
            return lhsIsLossless // true if lhs is lossless and rhs is lossy
        }

        // 2. Bitrate comparison
        let lhsBitrate = lhs.track.bitrateKbps ?? 0
        let rhsBitrate = rhs.track.bitrateKbps ?? 0
        if lhsBitrate != rhsBitrate {
            return lhsBitrate > rhsBitrate
        }

        // 3. Sample Rate comparison
        let lhsSampleRate = lhs.track.sampleRateHz ?? 0
        let rhsSampleRate = rhs.track.sampleRateHz ?? 0
        if lhsSampleRate != rhsSampleRate {
            return lhsSampleRate > rhsSampleRate
        }

        // 4. File Size fallback (larger is better, assuming less compression or fuller file)
        let lhsSize = (try? fileManager.attributesOfItem(atPath: lhs.track.fileURL.path)[.size] as? Int64) ?? 0
        let rhsSize = (try? fileManager.attributesOfItem(atPath: rhs.track.fileURL.path)[.size] as? Int64) ?? 0
        return lhsSize > rhsSize
    }

    private func isLossless(format: String) -> Bool {
        let fmt = format.lowercased()
        return fmt.contains("flac") || fmt.contains("alac") || fmt.contains("wav") || fmt.contains("aiff") || fmt.contains("pcm")
    }

    public func deleteTracks(_ tracks: [LoadedTrack], useTrash: Bool = true) throws {
        for track in tracks {
            let url = track.track.fileURL
            if fileManager.fileExists(atPath: url.path) {
                if useTrash {
                    try fileManager.trashItem(at: url, resultingItemURL: nil)
                } else {
                    try fileManager.removeItem(at: url)
                }
            }
        }
    }

    public func copyTracks(_ tracks: [LoadedTrack], to destinationFolder: URL) throws {
        if !fileManager.fileExists(atPath: destinationFolder.path) {
            try fileManager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        }

        for track in tracks {
            let source = track.track.fileURL
            let dest = destinationFolder.appendingPathComponent(source.lastPathComponent)
            
            // Check for name collision
            var attempt = 1
            var uniqueDest = dest
            while fileManager.fileExists(atPath: uniqueDest.path) {
                let ext = source.pathExtension
                let base = source.deletingPathExtension().lastPathComponent
                uniqueDest = destinationFolder.appendingPathComponent("\(base) (\(attempt)).\(ext)")
                attempt += 1
            }
            
            try fileManager.copyItem(at: source, to: uniqueDest)
        }
    }
}
