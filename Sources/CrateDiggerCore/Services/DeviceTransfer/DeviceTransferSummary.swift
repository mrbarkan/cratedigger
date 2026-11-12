import Foundation

/// The line a device transfer ends with, shared by every path that writes to
/// a device: "120 files copied · 14 already there · 6 albums finished".
/// Tracks are counted for what was copied, already there or failed; albums
/// for what the review decided. Parts that are zero are left out.
public struct DeviceTransferSummary {
    public static func statusLine(
        copied: Int,
        alreadyThere: Int,
        gapAlbums: Int,
        replaced: Int,
        keptBoth: Int,
        leftAlone: Int,
        failed: Int
    ) -> String {
        var parts: [String] = []
        if copied > 0 { parts.append("\(copied) \(copied == 1 ? "file" : "files") copied") }
        if alreadyThere > 0 { parts.append("\(alreadyThere) already there") }
        if gapAlbums > 0 { parts.append("\(albums(gapAlbums)) finished") }
        if replaced > 0 { parts.append("\(albums(replaced)) replaced") }
        if keptBoth > 0 { parts.append("\(albums(keptBoth)) kept beside the old copy") }
        if leftAlone > 0 { parts.append("\(albums(leftAlone)) left alone") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.isEmpty ? "Nothing to send" : parts.joined(separator: " · ")
    }

    /// The line for a plan once it ran. An album only counts as finished,
    /// replaced or kept when none of its copies failed; its failures are in
    /// the failed count instead.
    public static func statusLine(for plan: DeviceTransferFilePlan, outcome: DeviceTransferExecutor.Outcome) -> String {
        let failedAlbums = Set(outcome.failed.map(\.copy.album))
        func failedAlbumCount(of kind: DeviceTransferFilePlan.Copy.Kind) -> Int {
            Set(plan.copies.filter { $0.kind == kind }.map(\.album)).intersection(failedAlbums).count
        }
        return statusLine(
            copied: outcome.written.count,
            alreadyThere: plan.skippedPresent,
            gapAlbums: max(0, plan.gapAlbums - failedAlbumCount(of: .gap)),
            replaced: max(0, plan.replacedAlbums - failedAlbumCount(of: .replacement)),
            keptBoth: max(0, plan.keptBothAlbums - failedAlbumCount(of: .keptBoth)),
            leftAlone: plan.leftAlone,
            failed: failedCount(for: plan, outcome: outcome)
        )
    }

    /// Copies that failed, tracks no destination could be planned for, and
    /// old files a Replace could not remove.
    public static func failedCount(for plan: DeviceTransferFilePlan, outcome: DeviceTransferExecutor.Outcome) -> Int {
        outcome.failed.count + plan.unplanned.count + outcome.failedDeletions.count
    }

    private static func albums(_ count: Int) -> String {
        "\(count) \(count == 1 ? "album" : "albums")"
    }
}
