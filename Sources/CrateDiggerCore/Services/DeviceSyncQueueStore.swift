import Foundation

/// Persists per-device-profile sync queues (JSON) and manages their staging
/// trees (pre-baked conversions laid out exactly as they'll land on the
/// device). Queue: `<base>/DeviceSyncQueues/<profileID>.json`. Staging:
/// `<base>/DeviceStaging/<profileID>/…`. Deleting is aggressive by design —
/// staged bytes must never outlive their purpose.
public struct DeviceSyncQueueStore {
    private let queuesDirectory: URL
    private let stagingBaseDirectory: URL
    private let fileManager: FileManager

    public init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base: URL
        if let directory {
            base = directory
        } else {
            base = (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory()))
                .appendingPathComponent("CrateDigger", isDirectory: true)
        }
        self.queuesDirectory = base.appendingPathComponent("DeviceSyncQueues", isDirectory: true)
        self.stagingBaseDirectory = base.appendingPathComponent("DeviceStaging", isDirectory: true)
    }

    public func load(profileID: UUID) -> [DeviceSyncQueueEntry] {
        guard let data = try? Data(contentsOf: queueURL(for: profileID)) else { return [] }
        return (try? JSONDecoder().decode([DeviceSyncQueueEntry].self, from: data)) ?? []
    }

    public func save(_ entries: [DeviceSyncQueueEntry], profileID: UUID) {
        try? fileManager.createDirectory(at: queuesDirectory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: queueURL(for: profileID), options: .atomic)
    }

    /// Drop the whole queue: JSON + entire staging tree.
    public func remove(profileID: UUID) {
        try? fileManager.removeItem(at: queueURL(for: profileID))
        try? fileManager.removeItem(at: stagingDirectory(for: profileID))
    }

    public func stagingDirectory(for profileID: UUID) -> URL {
        stagingBaseDirectory.appendingPathComponent(profileID.uuidString, isDirectory: true)
    }

    public func stagedFileURL(for entry: DeviceSyncQueueEntry, profileID: UUID) -> URL {
        stagingDirectory(for: profileID).appendingPathComponent(entry.destinationRelativePath)
    }

    /// Delete one staged file and prune now-empty parent directories up to
    /// (but not including) the profile's staging root.
    public func removeStagedFile(for entry: DeviceSyncQueueEntry, profileID: UUID) {
        let root = stagingDirectory(for: profileID).standardizedFileURL
        let file = stagedFileURL(for: entry, profileID: profileID)
        try? fileManager.removeItem(at: file)
        var dir = file.deletingLastPathComponent().standardizedFileURL
        while dir.path.hasPrefix(root.path), dir.path != root.path {
            let contents = (try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? []
            guard contents.isEmpty else { break }
            try? fileManager.removeItem(at: dir)
            dir = dir.deletingLastPathComponent().standardizedFileURL
        }
    }

    /// Launch-time trash guard: delete queues + staging for profiles that no
    /// longer exist.
    public func sweepOrphans(validProfileIDs: Set<UUID>) {
        let valid = Set(validProfileIDs.map { $0.uuidString.lowercased() })
        for url in (try? fileManager.contentsOfDirectory(
            at: queuesDirectory, includingPropertiesForKeys: nil)) ?? [] {
            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            if !valid.contains(stem) { try? fileManager.removeItem(at: url) }
        }
        for url in (try? fileManager.contentsOfDirectory(
            at: stagingBaseDirectory, includingPropertiesForKeys: nil)) ?? [] {
            if !valid.contains(url.lastPathComponent.lowercased()) {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func queueURL(for profileID: UUID) -> URL {
        queuesDirectory.appendingPathComponent(profileID.uuidString)
            .appendingPathExtension("json")
    }
}
