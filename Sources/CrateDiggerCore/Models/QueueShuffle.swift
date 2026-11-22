import Foundation

/// What the shuffle key does to the queue that is already loaded.
///
/// Shuffle used to be read only when a queue was built, so switching it off
/// mid-album changed nothing: Next and Previous kept walking the shuffled
/// order until something else was played. Both directions now reorder the
/// loaded queue around the playing track, which keeps playing.
///
/// Each answer is a permutation of the queue's positions (`order[i]` is the
/// old position of the item that lands at `i`), so the playback service and
/// the view model's parallel `LoadedTrack` array can apply the same one.
public enum QueueShuffle {

    /// Shuffle on: the playing item at the head, everything else after it in
    /// random order — so Next is a surprise and Previous has nowhere to go.
    public static func shuffledOrder<G: RandomNumberGenerator>(
        count: Int,
        current: Int?,
        using generator: inout G
    ) -> [Int] {
        guard count > 0 else { return [] }
        guard let current, (0..<count).contains(current) else {
            return Array(0..<count).shuffled(using: &generator)
        }
        let rest = (0..<count).filter { $0 != current }.shuffled(using: &generator)
        return [current] + rest
    }

    public static func shuffledOrder(count: Int, current: Int?) -> [Int] {
        var generator = SystemRandomNumberGenerator()
        return shuffledOrder(count: count, current: current, using: &generator)
    }

    /// Shuffle off: back into `sourceOrder`, the order the tracks had before
    /// they were shuffled (the album, the crate, the playlist).
    ///
    /// An item the source never held — one queued with Play Next or Play Last
    /// after the queue started — has no place of its own, so it travels with
    /// the item it followed. With no source order at all the queue is left
    /// exactly as it is.
    public static func unshuffledOrder<ID: Hashable>(ids: [ID], sourceOrder: [ID]) -> [Int] {
        var rank: [ID: Int] = [:]
        for (position, id) in sourceOrder.enumerated() where rank[id] == nil {
            rank[id] = position
        }
        // (rank, place among the strays that follow it, queue position)
        var keys: [(rank: Int, stray: Int, position: Int)] = []
        keys.reserveCapacity(ids.count)
        var lastRank = -1
        var stray = 0
        for (position, id) in ids.enumerated() {
            if let known = rank[id] {
                lastRank = known
                stray = 0
                keys.append((known, 0, position))
            } else {
                stray += 1
                keys.append((lastRank, stray, position))
            }
        }
        return keys
            .sorted { ($0.rank, $0.stray, $0.position) < ($1.rank, $1.stray, $1.position) }
            .map(\.position)
    }
}
