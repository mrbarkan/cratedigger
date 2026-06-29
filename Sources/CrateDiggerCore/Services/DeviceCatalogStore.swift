import Foundation

/// Persists a scanned device's track catalog to disk so re-selecting a device —
/// even across app launches — doesn't re-walk it. One JSON file per device under
/// Application Support; only RESCAN refreshes it. Artwork bytes are omitted by
/// `ArtworkAsset`'s Codable, so these stay small.
public struct DeviceCatalogStore {
    private let directory: URL
    private let fileManager: FileManager

    public init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let directory {
            self.directory = directory
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = base.appendingPathComponent("CrateDigger/DeviceCatalogs", isDirectory: true)
        }
    }

    public func load(key: String) -> [LoadedTrack]? {
        guard let data = try? Data(contentsOf: url(for: key)) else { return nil }
        return try? JSONDecoder().decode([LoadedTrack].self, from: data)
    }

    public func save(_ tracks: [LoadedTrack], key: String) {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(tracks) else { return }
        try? data.write(to: url(for: key), options: .atomic)
    }

    public func remove(key: String) {
        try? fileManager.removeItem(at: url(for: key))
    }

    private func url(for key: String) -> URL {
        directory.appendingPathComponent(sanitized(key)).appendingPathExtension("cdtracks")
    }

    private func sanitized(_ key: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = String(key.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "device" : cleaned
    }
}
