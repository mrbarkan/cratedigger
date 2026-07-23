import CryptoKit
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

    // ponytail: metadata + duration matching only. If re-encodes with rewritten
    // tags still slip through, the upgrade path is chromaprint fingerprints via
    // the bundled ffmpeg (-f chromaprint), cached by path+mtime.
    public func findDuplicates(
        in index: LibraryIndex,
        mode: DuplicateScanMode = .strict,
        ignoring ignoredSignatures: Set<String> = []
    ) -> [DuplicateGroup] {
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
            guard var key = Self.duplicateMatchKey(
                artist: loadedTrack.track.artist, title: loadedTrack.track.title
            ) else { continue }
            if mode == .strict {
                key += " @@ " + Self.normalizeForMatch(loadedTrack.track.album)
            }
            if let version = versionAlbumOfTrack[loadedTrack.track.id] {
                key += " :: \(version)"
            }
            grouped[key, default: []].append(loadedTrack)
        }

        // One stat pass up front — the old code stat'd inside the sort
        // comparator (O(n log n) syscalls on a 14k library).
        var sizeByPath: [String: Int64] = [:]
        for tracks in grouped.values where tracks.count > 1 {
            for t in tracks {
                let path = t.track.fileURL.path
                if sizeByPath[path] == nil {
                    sizeByPath[path] =
                        (try? fileManager.attributesOfItem(atPath: path)[.size] as? Int64).flatMap { $0 } ?? 0
                }
            }
        }

        var duplicateGroups: [DuplicateGroup] = []
        func appendGroup(_ cluster: [LoadedTrack]) {
            let sorted = cluster.sorted { isBetterTrack(lhs: $0, rhs: $1, sizeByPath: sizeByPath) }
            guard let best = sorted.first else { return }
            let group = DuplicateGroup(bestTrack: best, worstTracks: Array(sorted.dropFirst()))
            guard !ignoredSignatures.contains(Self.signature(for: group)) else { return }
            duplicateGroups.append(group)
        }
        for (_, tracks) in grouped where tracks.count > 1 {
            for cluster in Self.durationClusters(tracks) where cluster.count > 1 {
                appendGroup(cluster)
            }
            // Unknown durations can't time-verify, but an exact byte-size match
            // is even stronger evidence than duration — those pairs still
            // surface (the " (1)" double-import case). Size 0/unreadable never
            // clusters, same rationale as the duration guard.
            let unknownDuration = tracks.filter { $0.track.durationSeconds <= 0 }
            let bySize = Dictionary(grouping: unknownDuration) { sizeByPath[$0.track.fileURL.path] ?? 0 }
            for (size, cluster) in bySize where size > 0 && cluster.count > 1 {
                appendGroup(cluster)
            }
        }
        return duplicateGroups.sorted {
            $0.bestTrack.track.title.localizedCaseInsensitiveCompare($1.bestTrack.track.title) == .orderedAscending
        }
    }

    /// Sort by duration, split where the gap to the previous track exceeds 2s.
    /// Unknown durations (≤0) never cluster — flagging a "duplicate" we can't
    /// time-verify is how legit files get trashed.
    static func durationClusters(_ tracks: [LoadedTrack]) -> [[LoadedTrack]] {
        let known = tracks
            .filter { $0.track.durationSeconds > 0 }
            .sorted { $0.track.durationSeconds < $1.track.durationSeconds }
        var clusters: [[LoadedTrack]] = []
        for track in known {
            if let prev = clusters.last?.last,
               track.track.durationSeconds - prev.track.durationSeconds <= 2.0 {
                clusters[clusters.count - 1].append(track)
            } else {
                clusters.append([track])
            }
        }
        return clusters
    }

    /// Stable identity for "this exact set of files is not a duplicate":
    /// SHA-256 over the sorted member paths. Membership changes → new
    /// signature → the group resurfaces for review. Intended.
    public static func signature(for group: DuplicateGroup) -> String {
        let joined = ([group.bestTrack] + group.worstTracks)
            .map { $0.track.fileURL.standardizedFileURL.path }
            .sorted()
            .joined(separator: "\n")
        return SHA256.hash(data: Data(joined.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func isBetterTrack(lhs: LoadedTrack, rhs: LoadedTrack, sizeByPath: [String: Int64]) -> Bool {
        // 1. Format Priority: Lossless > Lossy
        let lhsIsLossless = isLossless(format: lhs.track.formatName ?? "")
        let rhsIsLossless = isLossless(format: rhs.track.formatName ?? "")
        if lhsIsLossless != rhsIsLossless {
            return lhsIsLossless
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

        // 4. File Size fallback (larger is better)
        return (sizeByPath[lhs.track.fileURL.path] ?? 0) > (sizeByPath[rhs.track.fileURL.path] ?? 0)
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
