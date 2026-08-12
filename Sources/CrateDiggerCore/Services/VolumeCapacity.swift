import Foundation

public extension URL {
    /// Free bytes on the volume this URL lives on, or nil if the volume won't say.
    ///
    /// `volumeAvailableCapacityForImportantUsage` is the number to prefer — on
    /// APFS it counts purgeable space, so it matches what Finder promises — but
    /// it reports 0 on FAT32/exFAT, i.e. on exactly the players this app syncs
    /// to. That's what showed a connected 192 GB iPod as "0.0 GB FREE · 100%
    /// USED". Fall back to the plain available-capacity key there.
    var volumeFreeBytes: Int64? {
        guard let values = try? resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]) else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        return values.volumeAvailableCapacity.map(Int64.init)
    }
}
