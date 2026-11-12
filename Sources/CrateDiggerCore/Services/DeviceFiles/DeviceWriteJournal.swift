import Darwin
import Foundation

/// One thing CrateDigger did to one file on a device.
public struct DeviceFileRecord: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case created, replaced, deleted
        /// Written before a session's first write: a `.cdtmp` path that
        /// session may leave behind if it is interrupted. Not ownership.
        case tempIntent
    }

    /// NFC, case-folded (`DeviceWritePolicy.key(forRelativePath:)`).
    public let relativeKey: String
    /// As written.
    public let relativePath: String
    public let kind: Kind
    /// `DeviceFileRole.rawValue`, or the delete reason for a deletion.
    public let role: String
    public let size: Int64?
    /// nil for audio (spec D18).
    public let sha256: String?
    /// Replaced or deleted files: a copy kept on the Mac, relative to the journal folder.
    public let backupFile: String?
    /// Audio only, from phase 3: a tie-break hint, never proof.
    public let libraryPath: String?
    public let volumeUUID: String?
    public let sessionID: UUID
    public let date: Date
    /// Who a written file is for, when the writer said (an artist picture's
    /// player key). Absent from records written before it existed.
    public let subject: String?

    public init(relativePath: String, kind: Kind, role: String, size: Int64? = nil, sha256: String? = nil,
                backupFile: String? = nil, libraryPath: String? = nil, volumeUUID: String? = nil,
                sessionID: UUID, date: Date = Date(), subject: String? = nil) {
        relativeKey = DeviceWritePolicy.key(forRelativePath: relativePath)
        self.relativePath = relativePath
        self.kind = kind
        self.role = role
        self.size = size
        self.sha256 = sha256
        self.backupFile = backupFile
        self.libraryPath = libraryPath
        self.volumeUUID = volumeUUID
        self.sessionID = sessionID
        self.date = date
        self.subject = subject
    }
}

/// What CrateDigger wrote to one device, kept on the Mac: the proof of
/// ownership a writer needs before it may replace or delete a file (spec
/// invariant I3), and the backups that make a replace or delete reversible.
///
/// `<AppSupport>/CrateDigger/DeviceJournal/<profileID>/journal.jsonl`, one
/// JSON record per line, appended and flushed; backups under
/// `backups/<sessionID>/<relativePath>`. A line cut off by a crash is
/// skipped on load, so the file it described reads as not ours: the safe way
/// to be wrong.
public final class DeviceWriteJournal: @unchecked Sendable {
    public static let fileName = "journal.jsonl"
    public static let backupsFolder = "backups"

    /// `<dir>/<profileID>/`.
    public let folder: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var allRecords: [DeviceFileRecord] = []
    /// Every non-`tempIntent` record per key, oldest first.
    private var historyByKey: [String: [DeviceFileRecord]] = [:]
    /// Every `tempIntent` per key: which volume and session announced it.
    private var intentsByKey: [String: [(volumeUUID: String?, sessionID: UUID)]] = [:]

    /// One instance per profile and folder for the whole app, so every
    /// writer sees every record the others appended.
    private static let sharedLock = NSLock()
    private static var sharedJournals: [String: DeviceWriteJournal] = [:]

    /// The app's one journal for `profileID` (loaded on first use, so call
    /// it off the main actor the first time).
    public static func shared(profileID: UUID, directory: URL? = nil) -> DeviceWriteJournal {
        let folder = (directory ?? defaultDirectory).appendingPathComponent(profileID.uuidString, isDirectory: true)
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let journal = sharedJournals[folder.path] { return journal }
        let journal = DeviceWriteJournal(profileID: profileID, directory: directory)
        sharedJournals[folder.path] = journal
        return journal
    }

    public static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appendingPathComponent("CrateDigger/DeviceJournal", isDirectory: true)
    }

    public init(profileID: UUID, directory: URL? = nil, fileManager: FileManager = .default) {
        folder = (directory ?? Self.defaultDirectory)
            .appendingPathComponent(profileID.uuidString, isDirectory: true)
        self.fileManager = fileManager
        load()
    }

    var journalURL: URL { folder.appendingPathComponent(Self.fileName) }

    /// The latest record for `key`, if our last act there was a write. With
    /// a `volumeUUID`, records made on another volume are not ours here: a
    /// profile can match two devices, and the same path on each is a
    /// different file. A record or a caller with no UUID cannot tell, and
    /// matches.
    public func ownedRecord(forKey key: String, volumeUUID: String? = nil) -> DeviceFileRecord? {
        lock.lock()
        defer { lock.unlock() }
        let history = historyByKey[DeviceWritePolicy.key(forRelativePath: key)] ?? []
        guard let record = history.last(where: { Self.sameVolume($0.volumeUUID, volumeUUID) }),
              record.kind == .created || record.kind == .replaced
        else { return nil }
        return record
    }

    /// True unless both UUIDs are known and differ.
    public static func sameVolume(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return true }
        return a == b
    }

    /// Every record, in the order written (temp intents included).
    public var records: [DeviceFileRecord] {
        lock.lock()
        defer { lock.unlock() }
        return allRecords
    }

    public func records(sessionID: UUID) -> [DeviceFileRecord] {
        records.filter { $0.sessionID == sessionID }
    }

    /// Whether a session other than `sessionID` said it would make a temp at
    /// `key` on this volume (`sameVolume`): only such a temp is ever cleared
    /// as stale. Indexed, so a long journal costs nothing per write.
    public func hasTempIntent(forKey key: String, volumeUUID: String?, otherThan sessionID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (intentsByKey[DeviceWritePolicy.key(forRelativePath: key)] ?? []).contains {
            $0.sessionID != sessionID && Self.sameVolume($0.volumeUUID, volumeUUID)
        }
    }

    /// Appended and flushed to disk before returning. The file is opened
    /// with `O_APPEND` and each call's lines go in one `write`, so two
    /// writers (two instances, or another process) can never interleave
    /// inside a line or overwrite each other.
    public func append(_ records: [DeviceFileRecord]) throws {
        guard !records.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var payload = Data()
        for record in records {
            payload.append(try encoder.encode(record))
            payload.append(0x0a)
        }

        lock.lock()
        defer { lock.unlock() }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = journalURL
        // On the Mac, never on the device. Read too: checks the last byte.
        let fd = open(url.path, O_RDWR | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { throw Self.posixError(url) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Self.posixError(url) }
        if info.st_size > 0 {
            // A crash can leave a last line without its newline; start ours on a fresh line.
            var last: UInt8 = 0
            if pread(fd, &last, 1, off_t(info.st_size - 1)) == 1, last != 0x0a { payload.insert(0x0a, at: 0) }
        }
        let written = payload.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == payload.count else { throw Self.posixError(url) }
        guard fsync(fd) == 0 else { throw Self.posixError(url) }
        for record in records { remember(record) }
    }

    private static func posixError(_ url: URL) -> CocoaError {
        CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path,
                                                 NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)])
    }

    /// Keeps `data` on the Mac under `backups/<sessionID>/<relativePath>` and
    /// returns that path relative to `folder`.
    public func backUp(_ data: Data, relativePath: String, sessionID: UUID) throws -> String {
        let (url, relative) = try backupDestination(relativePath: relativePath, sessionID: sessionID)
        try data.write(to: url) // on the Mac
        return relative
    }

    /// Copies the file at `url` (on the device) to the Mac; see `backUp(_:relativePath:sessionID:)`.
    public func backUp(fileAt url: URL, relativePath: String, sessionID: UUID) throws -> String {
        let (destination, relative) = try backupDestination(relativePath: relativePath, sessionID: sessionID)
        try fileManager.copyItem(at: url, to: destination) // device to Mac: reads the device only
        return relative
    }

    // MARK: - Private

    private func backupDestination(relativePath: String, sessionID: UUID) throws -> (URL, String) {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0 == "." || $0 == ".." }) else {
            throw DeviceWritePolicyError.forbidden("a backup needs a plain relative path")
        }
        let base = [Self.backupsFolder, sessionID.uuidString] + parts.dropLast()
        let directory = base.reduce(folder) { $0.appendingPathComponent($1, isDirectory: true) }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // The same file backed up twice in one session keeps both copies.
        var name = parts[parts.count - 1]
        var counter = 1
        while fileManager.fileExists(atPath: directory.appendingPathComponent(name).path) {
            counter += 1
            name = "\(parts[parts.count - 1]).\(counter)"
        }
        return (directory.appendingPathComponent(name), (base + [name]).joined(separator: "/"))
    }

    private func load() {
        guard let data = fileManager.contents(atPath: journalURL.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for line in data.split(separator: 0x0a) where !line.isEmpty {
            // Blank, foreign or cut-off lines are skipped: what they described reads as not ours.
            guard let record = try? decoder.decode(DeviceFileRecord.self, from: Data(line)) else { continue }
            remember(record)
        }
    }

    private func remember(_ record: DeviceFileRecord) {
        allRecords.append(record)
        guard record.kind != .tempIntent else {
            intentsByKey[DeviceWritePolicy.key(forRelativePath: record.relativeKey), default: []]
                .append((record.volumeUUID, record.sessionID))
            return
        }
        historyByKey[DeviceWritePolicy.key(forRelativePath: record.relativeKey), default: []].append(record)
    }
}
