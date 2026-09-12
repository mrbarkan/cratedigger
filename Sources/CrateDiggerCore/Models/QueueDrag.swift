import Foundation

/// Reordering Up Next by dragging one row onto another.
public enum QueueDrag {
    private static let prefix = "queue::"

    /// What a queued row carries while it is dragged.
    public static func payload(for trackID: UUID) -> String {
        prefix + trackID.uuidString
    }

    /// The `moveInQueue(from:to:)` a drop means: where the dragged track sits,
    /// and the insertion index ahead of the row it was dropped on, or the end
    /// of the queue for a drop below the last row (`target` nil). Nil when the
    /// drag is not a queued track (a browser track dragged over the queue) or
    /// either row has left the queue since the drag began.
    public static func move(payload: String, before target: UUID?, in queue: [UUID]) -> (from: Int, to: Int)? {
        guard payload.hasPrefix(prefix),
              let dragged = UUID(uuidString: String(payload.dropFirst(prefix.count))),
              let from = queue.firstIndex(of: dragged)
        else { return nil }
        guard let target else { return (from, queue.count) }
        guard let to = queue.firstIndex(of: target) else { return nil }
        return (from, to)
    }
}
