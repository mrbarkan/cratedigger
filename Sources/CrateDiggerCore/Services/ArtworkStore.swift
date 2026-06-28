import Foundation

/// Content-addressed, on-disk store for full-resolution artwork bytes. Each blob
/// is written once under its own SHA-256 hash, so identical covers shared by
/// many tracks/albums/crates are stored a single time. Lives in the app's own
/// Application Support folder, so artwork resolves even when the source music
/// drive is offline and survives across launches (the old in-memory cache did
/// neither, which is why cold-launch thumbnails fell back to placeholders).
public final class ArtworkStore {
    private let directory: URL
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// `Application Support/CrateDigger/Artwork` — the app-owned, always-online location.
    public static var defaultDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("CrateDigger")
            .appendingPathComponent("Artwork")
    }

    private func url(for hash: String) -> URL {
        directory.appendingPathComponent(hash)
    }

    public func contains(_ hash: String) -> Bool {
        fileManager.fileExists(atPath: url(for: hash).path)
    }

    /// Write-once: a hash addresses identical bytes, so an existing blob is never
    /// rewritten. Empty data is ignored.
    public func put(_ data: Data, for hash: String) {
        guard !data.isEmpty else { return }
        let destination = url(for: hash)
        guard !fileManager.fileExists(atPath: destination.path) else { return }
        try? data.write(to: destination, options: .atomic)
    }

    public func data(for hash: String) -> Data? {
        try? Data(contentsOf: url(for: hash))
    }
}
