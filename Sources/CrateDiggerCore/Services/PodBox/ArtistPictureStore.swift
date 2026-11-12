import CryptoKit
import Foundation

/// Where an artist picture came from.
public enum ArtistPictureSourceID: String, Codable, Sendable {
    case userFile, libraryFolder, deezer, commons, fanartTV, discogs, theAudioDB
}

/// What CrateDigger knows about one artist's picture, whatever device it
/// ends up on. Keyed by `PodBoxArtName.folded`, so every spelling the player
/// treats as one person (`The Beatles`, `Beatles, The`) shares one record.
public struct ArtistPictureRecord: Codable, Hashable, Sendable {
    public enum Outcome: String, Codable, Sendable { case found, notFound, uncertain, rejected }

    /// How long a "not found" is trusted before the finder looks again.
    public static let notFoundLifetime: TimeInterval = 30 * 86_400

    public var foldedKey: String, displayName: String
    public var outcome: Outcome
    public var source: ArtistPictureSourceID?
    public var sourceID: String?
    public var preparedHash: String?                   // SHA-256 of the exact bytes to write
    public var pickedByUser: Bool
    public var checkedAt: Date

    public init(foldedKey: String, displayName: String, outcome: Outcome, source: ArtistPictureSourceID? = nil,
                sourceID: String? = nil, preparedHash: String? = nil, pickedByUser: Bool = false, checkedAt: Date) {
        self.foldedKey = foldedKey
        self.displayName = displayName
        self.outcome = outcome
        self.source = source
        self.sourceID = sourceID
        self.preparedHash = preparedHash
        self.pickedByUser = pickedByUser
        self.checkedAt = checkedAt
    }

    /// A "not found" older than 30 days is worth asking again. Nothing else
    /// goes stale: a found picture stays, and "No Picture" is the owner's word.
    public func isStale(now: Date) -> Bool {
        outcome == .notFound && now.timeIntervalSince(checkedAt) > Self.notFoundLifetime
    }
}

public enum ArtistPictureStoreError: LocalizedError, Equatable {
    /// The records file is present but would not decode. Reported instead of
    /// saving, so the owner's picks are not replaced by what is in memory.
    case unreadableStore(path: String)
    /// A record whose name the player cannot key, or whose `foldedKey` is
    /// not its name's fold.
    case invalidRecord(name: String)

    public var errorDescription: String? {
        switch self {
        case .unreadableStore(let path):
            return "The artist picture list at \(path) could not be read, so CrateDigger has not written over it. "
                + "Move that file aside to start fresh, or restore it from a backup."
        case .invalidRecord(let name):
            return "\"\(name)\" has no letters or digits the iPod can match a picture to."
        }
    }
}

/// The artist picture records (`library.cdartists`, in the library's index
/// folder, so it moves and is copied with the rest of the index) and their
/// prepared JPEGs (`<preparedHash>.jpg` in Application Support, a cache:
/// a missing one gives nil and the finder fetches it again). Everything here
/// writes on the Mac only. Callers check `refuseWhileLibraryDisconnected`.
public final class ArtistPictureStore {
    public static let fileName = "library.cdartists"

    private let fileURL: URL
    private let imageDirectory: URL
    private let fileManager: FileManager
    private var byKey: [String: ArtistPictureRecord] = [:]
    /// The player's keys (`key` and `altKey` of each record's name) -> folded key,
    /// so `Herbert, Frank` and `Frank Herbert` find one record.
    private var byPlayerKey: [UInt32: String] = [:]
    private var isDirty = false
    private var isUnreadable = false

    /// `imageDirectory` default: `<Application Support>/CrateDigger/ArtistImages`.
    public init(indexDirectory: URL, imageDirectory: URL? = nil, fileManager: FileManager = .default) {
        fileURL = indexDirectory.appendingPathComponent(Self.fileName)
        self.imageDirectory = imageDirectory ?? Self.defaultImageDirectory(fileManager)
        self.fileManager = fileManager
        load()
    }

    /// The record for any spelling the player takes for the same person
    /// (`The Beatles` and `Beatles, The`; `Frank Herbert` and `Herbert, Frank`).
    /// nil when there is none, or when the name has nothing the player keys.
    public func record(forName name: String) -> ArtistPictureRecord? {
        let folded = PodBoxArtName.folded(name)
        guard !folded.isEmpty else { return nil }
        if let exact = byKey[folded] { return exact }
        for key in Self.playerKeys(name) {
            if let folded = byPlayerKey[key], let record = byKey[folded] { return record }
        }
        return nil
    }

    /// The prepared bytes, read from the image cache. nil when the record has
    /// no hash, the file is gone, or the bytes no longer match the hash.
    public func preparedData(for record: ArtistPictureRecord) -> Data? {
        guard let hash = record.preparedHash, Self.isHexHash(hash),
              let data = try? Data(contentsOf: imageURL(hash: hash)),
              Self.sha256(data) == hash else { return nil }
        return data
    }

    /// Stores a record, replacing every record the player takes for the same
    /// person. Its `foldedKey` is worked out from `displayName` when empty,
    /// and must equal it otherwise. With `prepared`, its bytes are written to
    /// the image cache first and the record's `preparedHash` is set to their SHA-256.
    public func set(_ record: ArtistPictureRecord, prepared: Data?) throws {
        var record = record
        let folded = PodBoxArtName.folded(record.displayName)
        guard !folded.isEmpty, record.foldedKey.isEmpty || record.foldedKey == folded else {
            throw ArtistPictureStoreError.invalidRecord(name: record.displayName)
        }
        record.foldedKey = folded
        if let prepared {
            let hash = Self.sha256(prepared)
            let url = imageURL(hash: hash)
            if !fileManager.fileExists(atPath: url.path) {
                try fileManager.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
                try prepared.write(to: url, options: .atomic)
            }
            record.preparedHash = hash
        }
        let sameKeys = Self.playerKeys(record.displayName).compactMap { byPlayerKey[$0] }
        for old in Set(sameKeys + [folded]) { forget(foldedKey: old) }
        insert(record)
        isDirty = true
    }

    /// Every record, by folded key.
    public func allRecords() -> [ArtistPictureRecord] {
        byKey.keys.sorted().compactMap { byKey[$0] }
    }

    /// Writes `library.cdartists` atomically when anything changed: canonical
    /// bytes (sorted keys, ISO dates) so an unchanged list never reads as changed.
    public func save() throws {
        if isUnreadable { throw ArtistPictureStoreError.unreadableStore(path: fileURL.path) }
        guard isDirty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(allRecords())
        try data.write(to: fileURL, options: .atomic)
        isDirty = false
    }

    // MARK: - Private

    /// No file is an empty store. Any other failure to read or decode it
    /// marks the store unreadable, which blocks `save`.
    private func load() {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return
        } catch {
            isUnreadable = true
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let records = try? decoder.decode([ArtistPictureRecord].self, from: data) else {
            isUnreadable = true
            return
        }
        // A hand-edited file may carry a wrong folded key, a name with
        // nothing the player keys, or two records the player takes for one
        // person. Each is put right here, and the next save writes it back.
        for var record in records {
            let folded = PodBoxArtName.folded(record.displayName)
            guard !folded.isEmpty else {
                isDirty = true
                continue
            }
            if record.foldedKey != folded {
                record.foldedKey = folded
                isDirty = true
            }
            var rivals = Set(Self.playerKeys(record.displayName).compactMap { byPlayerKey[$0] })
            if byKey[folded] != nil { rivals.insert(folded) }
            guard !rivals.isEmpty else {
                insert(record)
                continue
            }
            isDirty = true
            if rivals.compactMap({ byKey[$0] }).contains(where: { Self.keeps($0, over: record) }) { continue }
            for old in rivals { forget(foldedKey: old) }
            insert(record)
        }
    }

    /// Of two records for one person, the owner's pick wins, then the
    /// newer check; on a tie the one already loaded stays.
    private static func keeps(_ kept: ArtistPictureRecord, over other: ArtistPictureRecord) -> Bool {
        if kept.pickedByUser != other.pickedByUser { return kept.pickedByUser }
        return kept.checkedAt >= other.checkedAt
    }

    private func insert(_ record: ArtistPictureRecord) {
        byKey[record.foldedKey] = record
        for key in Self.playerKeys(record.displayName) { byPlayerKey[key] = record.foldedKey }
    }

    private func forget(foldedKey: String) {
        guard let old = byKey.removeValue(forKey: foldedKey) else { return }
        for key in Self.playerKeys(old.displayName) where byPlayerKey[key] == foldedKey {
            byPlayerKey.removeValue(forKey: key)
        }
    }

    private static func playerKeys(_ name: String) -> [UInt32] {
        [PodBoxArtName.key(name), PodBoxArtName.altKey(name)].filter { $0 != 0 }
    }

    private func imageURL(hash: String) -> URL {
        imageDirectory.appendingPathComponent(hash + ".jpg")
    }

    private static func defaultImageDirectory(_ fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("CrateDigger/ArtistImages", isDirectory: true)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 64 lowercase hex digits: the only thing that names a cached file.
    private static func isHexHash(_ hash: String) -> Bool {
        hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
