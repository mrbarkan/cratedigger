import Foundation

/// The file types that make up a library index: crate membership lists, the
/// shared track store and listening history. Moving the index and copying it
/// both read this list, so a new index file is added here once, not in each.
public enum LibraryIndexFiles {
    public static let extensions: Set<String> = ["cdcrate", "cdtracks", "cdplays"]

    public static func isIndexFile(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }
}

/// A read-only copy of the library index on the internal disk, so a library
/// kept on an external drive can still be browsed while the drive is out.
///
/// Covers need nothing here: thumbnails already live in `ArtworkStore` on the
/// internal disk, and index files carry only artwork hashes.
///
/// Every write builds a whole new copy in a hidden folder beside this one and
/// swaps it in only once every file has landed, so a copy interrupted part-way
/// (a drive pulled out mid-read) leaves the previous copy exactly as it was.
public struct LibraryIndexCopy: Sendable {
    /// Where the copy came from and when. Written last into the new copy, so a
    /// copy with a record is a complete one.
    public struct Record: Codable, Equatable, Sendable {
        public let sourcePath: String
        public let copiedAt: Date

        public init(sourcePath: String, copiedAt: Date) {
            self.sourcePath = sourcePath
            self.copiedAt = copiedAt
        }

        public var sourceFolder: URL { URL(fileURLWithPath: sourcePath, isDirectory: true) }
        public var volumeName: String? { LibraryLocation.volumeName(of: sourceFolder) }
    }

    public static let recordFilename = "copy.json"

    public let directory: URL

    public init(directory: URL = LibraryIndexCopy.defaultDirectory) {
        self.directory = directory
    }

    /// `Application Support/CrateDigger/LibraryCopy`.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CrateDigger", isDirectory: true)
            .appendingPathComponent("LibraryCopy", isDirectory: true)
    }

    /// The record of the current copy, or nil when there is no complete copy.
    public func record() -> Record? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(Self.recordFilename)) else {
            return nil
        }
        return try? Self.decoder.decode(Record.self, from: data)
    }

    /// Replace the copy with the index files in `source`. Throws, leaving the
    /// previous copy untouched, if any file cannot be read.
    @discardableResult
    public func write(from source: URL, now: Date = Date()) throws -> Record {
        let fileManager = FileManager.default
        let parent = directory.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        // Same parent, so the final swap is a rename on one volume.
        let staging = parent.appendingPathComponent(
            ".\(directory.lastPathComponent)-\(UUID().uuidString)", isDirectory: true
        )
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)

        do {
            let files = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                .filter(LibraryIndexFiles.isIndexFile)
            for file in files {
                try fileManager.copyItem(at: file, to: staging.appendingPathComponent(file.lastPathComponent))
            }
            let record = Record(sourcePath: source.standardizedFileURL.path, copiedAt: now)
            try Self.encoder.encode(record)
                .write(to: staging.appendingPathComponent(Self.recordFilename), options: .atomic)

            if fileManager.fileExists(atPath: directory.path) {
                _ = try fileManager.replaceItemAt(directory, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: directory)
            }
            return record
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
