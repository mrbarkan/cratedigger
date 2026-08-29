import Foundation

/// What SAVE will actually do to an album folder.
///
/// Computed up front and separately from doing it, because this is where the
/// mistakes live: a staged `cover.jpg` landing on top of the `cover.jpg`
/// already there, a removal for a file that isn't there any more, the same
/// name claimed twice in one batch. Working it out as a plan makes each of
/// those a case with a test rather than a surprise on someone's library.
public struct ArtworkCommitPlan: Equatable, Sendable {
    public struct Write: Equatable, Sendable {
        /// The staged file's own name, as it sits in the staging folder.
        public let stagedName: String
        /// What it will be called in the album folder.
        public let finalName: String

        public init(stagedName: String, finalName: String) {
            self.stagedName = stagedName
            self.finalName = finalName
        }
    }

    /// Filenames to move to the Trash, in the album folder.
    public var trash: [String]
    public var writes: [Write]
    public var stripEmbedded: Bool

    public var isEmpty: Bool { trash.isEmpty && writes.isEmpty && !stripEmbedded }
    public var changeCount: Int { trash.count + writes.count + (stripEmbedded ? 1 : 0) }
}

public enum ArtworkCommitPlanner {

    /// - Parameters:
    ///   - existing: filenames already in the album folder.
    ///   - staged: filenames sitting in the staging folder, in display order.
    ///   - removals: existing filenames the user marked for removal.
    ///   - stripEmbedded: whether the tracks' embedded picture should go.
    public static func plan(existing: [String],
                            staged: [String],
                            removals: Set<String>,
                            stripEmbedded: Bool) -> ArtworkCommitPlan {
        // A removal for a file that has since vanished is not an error, it's a
        // no-op — the user's intent (it should not be there) already holds.
        let existingSet = Set(existing)
        let trash = existing.filter { removals.contains($0) }

        // Names that will still be occupied once the trashing is done. A staged
        // file may reuse the name of a file being removed — replacing cover.jpg
        // is the single most common thing anyone does here.
        var claimed = existingSet.subtracting(trash)

        var writes: [ArtworkCommitPlan.Write] = []
        for name in staged {
            let final = uniqueName(for: name, avoiding: claimed)
            claimed.insert(final)
            writes.append(.init(stagedName: name, finalName: final))
        }

        return ArtworkCommitPlan(trash: trash, writes: writes, stripEmbedded: stripEmbedded)
    }

    /// `cover.jpg` → `cover_2.jpg` → `cover_3.jpg`, the same shape
    /// `OutputPathPlanner` uses for conversion outputs.
    public static func uniqueName(for name: String, avoiding taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var suffix = 2
        while true {
            let candidate = ext.isEmpty ? "\(base)_\(suffix)" : "\(base)_\(suffix).\(ext)"
            if !taken.contains(candidate) { return candidate }
            suffix += 1
        }
    }
}
