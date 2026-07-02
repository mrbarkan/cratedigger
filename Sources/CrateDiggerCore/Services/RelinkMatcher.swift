import Foundation

/// Matches missing-track file URLs to replacements found under a folder the user
/// pointed us at, so a whole moved library can be re-attached in one pick.
///
/// Matching is by filename (case-insensitive); when several candidates share a
/// name, the one with the longest shared *trailing* path wins (so `Rock/Album/01.flac`
/// prefers `NewDrive/Rock/Album/01.flac` over `NewDrive/Jazz/Album/01.flac`). Each
/// candidate is claimed at most once, so duplicate filenames map to distinct files.
/// Pure — no disk access; the caller supplies the candidate list.
public enum RelinkMatcher {

    /// - Parameters:
    ///   - missing: last-known file URLs of the tracks that need re-attaching.
    ///   - candidates: file URLs discovered under the chosen folder.
    /// - Returns: old URL → new URL for every missing file that found a match.
    public static func match(missing: [URL], candidates: [URL]) -> [URL: URL] {
        // Pool candidates by lowercased filename, path-sorted for deterministic ties.
        var pool: [String: [URL]] = [:]
        for candidate in candidates {
            pool[candidate.lastPathComponent.lowercased(), default: []].append(candidate)
        }
        for key in pool.keys { pool[key]?.sort { $0.path < $1.path } }

        var result: [URL: URL] = [:]
        // Path-sorted so greedy claiming of shared-name candidates is stable.
        for old in missing.sorted(by: { $0.path < $1.path }) {
            let name = old.lastPathComponent.lowercased()
            guard var available = pool[name], !available.isEmpty else { continue }

            var bestIndex = 0
            var bestScore = -1
            for (index, candidate) in available.enumerated() {
                let score = sharedTrailingCount(old, candidate)
                if score > bestScore { bestScore = score; bestIndex = index }
            }
            result[old] = available[bestIndex]
            available.remove(at: bestIndex)
            pool[name] = available
        }
        return result
    }

    /// Number of path components two URLs share, counting from the tail.
    private static func sharedTrailingCount(_ a: URL, _ b: URL) -> Int {
        let ac = a.standardizedFileURL.pathComponents
        let bc = b.standardizedFileURL.pathComponents
        var count = 0
        var i = ac.count - 1, j = bc.count - 1
        while i >= 0, j >= 0, ac[i].lowercased() == bc[j].lowercased() {
            count += 1; i -= 1; j -= 1
        }
        return count
    }
}
