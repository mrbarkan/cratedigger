import Foundation

/// What's waiting to go to a device, in one glance.
///
/// A queue for an unplugged device is invisible by nature — the files aren't on
/// the device and may not be on this Mac either — so the count alone doesn't
/// tell you much. Copy-mode entries stream from the original files at sync time
/// and occupy nothing locally; convert-mode entries were baked up front and are
/// sitting in the staging tree. Those two need different answers to "how much
/// space is this using?", so the summary keeps them apart.
public struct DeviceSyncQueueSummary: Equatable, Sendable {
    /// Entries whose converted file has already been written to staging.
    public let stagedCount: Int
    /// Entries that will copy straight from the source file at sync time.
    public let copyCount: Int
    /// Bytes the staged files occupy on this Mac right now.
    public let stagedBytes: Int64
    /// Bytes the sync will write to the device, staged and copy-mode together.
    public let transferBytes: Int64
    /// Queued entries whose source file has gone missing — they will fail.
    public let missingSourceCount: Int

    public var totalCount: Int { stagedCount + copyCount }
    public var isEmpty: Bool { totalCount == 0 }

    public init(
        stagedCount: Int,
        copyCount: Int,
        stagedBytes: Int64,
        transferBytes: Int64,
        missingSourceCount: Int
    ) {
        self.stagedCount = stagedCount
        self.copyCount = copyCount
        self.stagedBytes = stagedBytes
        self.transferBytes = transferBytes
        self.missingSourceCount = missingSourceCount
    }

    public static let empty = DeviceSyncQueueSummary(
        stagedCount: 0, copyCount: 0, stagedBytes: 0, transferBytes: 0, missingSourceCount: 0
    )

    /// Build a summary. `sizeOfStaged` / `sizeOfSource` return nil when the file
    /// isn't there — injected so this stays testable without touching disk.
    public static func make(
        entries: [DeviceSyncQueueEntry],
        sizeOfStaged: (DeviceSyncQueueEntry) -> Int64?,
        sizeOfSource: (DeviceSyncQueueEntry) -> Int64?
    ) -> DeviceSyncQueueSummary {
        var stagedCount = 0
        var copyCount = 0
        var stagedBytes: Int64 = 0
        var transferBytes: Int64 = 0
        var missing = 0

        for entry in entries {
            if entry.isStaged {
                stagedCount += 1
                let size = sizeOfStaged(entry) ?? 0
                stagedBytes += size
                transferBytes += size
                // A staged entry stands on its own — its bake is already done,
                // so a missing source is not a failure the way it is for a copy.
            } else {
                copyCount += 1
                guard let size = sizeOfSource(entry) else {
                    missing += 1
                    continue
                }
                transferBytes += size
            }
        }

        return DeviceSyncQueueSummary(
            stagedCount: stagedCount,
            copyCount: copyCount,
            stagedBytes: stagedBytes,
            transferBytes: transferBytes,
            missingSourceCount: missing
        )
    }

    /// "12 tracks · 480 MB" — the one-line form for the queue bar.
    public var headline: String {
        guard !isEmpty else { return "Nothing queued" }
        let noun = totalCount == 1 ? "track" : "tracks"
        return "\(totalCount) \(noun) · \(Self.byteLabel(transferBytes))"
    }

    /// The qualifier under the headline, when there is something worth saying.
    public var detail: String? {
        guard !isEmpty else { return nil }
        var parts: [String] = []
        if stagedCount > 0 && copyCount > 0 {
            parts.append("\(stagedCount) converted, \(copyCount) as-is")
        } else if stagedCount > 0 {
            parts.append("converted, ready to copy")
        } else {
            parts.append("copied from the originals")
        }
        if stagedBytes > 0 {
            parts.append("\(Self.byteLabel(stagedBytes)) staged on this Mac")
        }
        if missingSourceCount > 0 {
            parts.append("\(missingSourceCount) missing source\(missingSourceCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    public static func byteLabel(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 MB" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
