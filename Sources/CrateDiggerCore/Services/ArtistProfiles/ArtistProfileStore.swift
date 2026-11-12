import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ArtistProfileStoreError: LocalizedError, Equatable {
    /// The profiles file is present but would not read. Reported instead of
    /// saving, so the owner's edits are not replaced by what is in memory.
    case unreadableStore(path: String)
    /// The library's index folder was not there when the store was made
    /// (a library drive unplugged): saving would put a near-empty file in
    /// place of the real one once the drive is back.
    case unreachableIndexFolder(path: String)
    /// A name with no letters or digits to key a profile by.
    case unnamedArtist(name: String)
    /// Bytes that are not a whole image CrateDigger can read.
    case unreadablePhoto
    /// Over 32 MB, or over 50 megapixels.
    case photoTooLarge

    public var errorDescription: String? {
        switch self {
        case .unreadableStore(let path):
            return "The artist profiles at \(path) could not be read, so CrateDigger has not written over them. "
                + "Move that file aside to start fresh, or restore it from a backup."
        case .unreachableIndexFolder(let path):
            return "The library folder at \(path) could not be reached, so artist profiles were not saved. "
                + "Connect the library's drive and try again."
        case .unnamedArtist(let name):
            return "An artist with no name has no profile to keep this under."
        case .unreadablePhoto:
            return "That file is not a picture CrateDigger can read, or it is incomplete."
        case .photoTooLarge:
            return "That picture is too large. Artist photos can be up to 32 MB and 50 megapixels."
        }
    }
}

/// The artist profiles (`library.cdartistinfo` in the library's index folder,
/// so library moves and the offline copy carry it) and their photos (an
/// `ArtistPhotos` folder beside it, one file per SHA-256, never inside the
/// index file). Profiles are keyed by `ArtistProfileKey.key(for:)` of the name.
///
/// Everything here writes on the Mac only, and callers check
/// `refuseWhileLibraryDisconnected` first. Safe to use from any thread:
/// every member holds one lock, so a background lookup and the artist page
/// can share it. Do not call it from AppKit's main thread for photo work:
/// `addPhoto` decodes and re-encodes images.
///
/// Another writer of the same folder (a second Mac sharing the library, or
/// a store made before this one) is not overwritten: `save` reads the file
/// again and merges (`merging(mine:base:disk:)`), and deletes only photo
/// files this store itself dropped that the file on disk does not name
/// either. Keep one store per folder in one app all the same: the merge is
/// a safety net, not a way to share edits live.
public final class ArtistProfileStore: @unchecked Sendable {
    public static let fileName = "library.cdartistinfo", photosFolder = "ArtistPhotos"
    /// The copy of a file that did not load whole, kept beside it. Later
    /// ones are numbered (`library.cdartistinfo.2.bak`, `.3.bak`), so no
    /// backup is ever written over.
    public static let backupFileName = fileName + ".bak"

    /// The library index folder this store reads and writes.
    public let indexDirectory: URL
    private let fileURL: URL
    private let photosDirectory: URL
    private let fileManager: FileManager
    private var byKey: [String: ArtistProfile] = [:]
    /// The profiles as this store last read them from the file or wrote
    /// them to it: the base the next save merges against.
    private var base: [String: ArtistProfile] = [:]
    /// Hashes this store took out of a profile since its last save (a photo
    /// removed, a migrated photo replaced, what came with an identity
    /// dropped). Only these files may be deleted, and only when nothing
    /// names them any more.
    private var dropped: Set<String> = []
    private var migrated = false
    private var isDirty = false
    private var isUnreadable = false
    private var isUnreachable = false
    /// The load left something out (a record or an element that would not
    /// decode, a nameless record, two records merged): the next save first
    /// keeps a copy of the file as it was read.
    private var needsBackup = false
    /// The same loss, for the store's whole life: a store that could not read
    /// every record never deletes photo files, since the records it dropped
    /// may name them.
    private var loadWasLossy = false
    private let lock = NSLock()

    public init(indexDirectory: URL, fileManager: FileManager = .default) {
        self.indexDirectory = indexDirectory
        fileURL = indexDirectory.appendingPathComponent(Self.fileName)
        photosDirectory = indexDirectory.appendingPathComponent(Self.photosFolder, isDirectory: true)
        self.fileManager = fileManager
        load()
    }

    /// The iPod's artist pictures have been carried into these profiles
    /// (`ArtistProfileMigration`); saved in the file, so it never runs twice.
    public var picturesMigrated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return migrated
    }

    public func markPicturesMigrated() {
        lock.lock()
        defer { lock.unlock() }
        guard !migrated else { return }
        migrated = true
        isDirty = true
    }

    /// The profile for any spelling that folds to the same key
    /// (`The Beatles`, `Beatles, The`); nil when there is none, or when the
    /// name is empty.
    public func profile(forName name: String) -> ArtistProfile? {
        let key = ArtistProfileKey.key(for: name)
        guard !key.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return byKey[key]
    }

    /// Every profile, by folded key.
    public func allProfiles() -> [ArtistProfile] {
        lock.lock()
        defer { lock.unlock() }
        return sortedProfiles()
    }

    /// Changes the profile for `name`, creating it (named `name`) when there
    /// is none. An empty name is ignored. The closure runs
    /// under the store's lock, so it must not call the store, and it cannot
    /// move the profile to another key.
    public func update(name: String, _ change: (inout ArtistProfile) -> Void) {
        update(name: name, ifIdentityIs: nil, change)
    }

    /// `update`, only while the profile's identity (`.unknown` when there is
    /// no profile) is `expected`, checked under the same lock as the write,
    /// so a lookup's result cannot land on an identity the owner has changed
    /// since. Returns whether the change ran; nil `expected` always runs it.
    @discardableResult
    public func update(name: String, ifIdentityIs expected: ArtistProfile.Identity?,
                       _ change: (inout ArtistProfile) -> Void) -> Bool {
        let key = ArtistProfileKey.key(for: name)
        guard !key.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        let before = byKey[key]
        if let expected, (before?.identity ?? .unknown) != expected { return false }
        var profile = before ?? ArtistProfile(foldedKey: key, displayName: name)
        change(&profile)
        profile.foldedKey = key
        guard profile != before else { return true }
        put(profile, at: key)
        return true
    }

    /// A lookup's result: replaces the fetched facts, the identity and
    /// `checkedAt`, and nothing else, so nothing the owner set can change.
    /// The owner's word on who the artist is also stands against a lookup
    /// that was already running when it was given: nothing is applied to an
    /// artist the owner marked "None of these" (`.rejected`), or when the
    /// lookup confirms an id the owner said is "Not This Artist"; rejected
    /// ids are taken out of an uncertain list (none left reads as
    /// `.notFound`). Returns whether anything was applied. Look Up Again
    /// calls `resetIdentity` first.
    @discardableResult
    public func applyFetched(name: String, facts: ArtistFacts?, identity: ArtistProfile.Identity,
                             at date: Date) -> Bool {
        applyFetchedLocked(name: name, facts: facts, identity: identity, at: date, expected: nil) != nil
    }

    /// `applyFetched`, only while the profile's identity (`.unknown` when
    /// there is no profile) is still `expected`, the one the lookup started
    /// from: checked under the same lock as the write, so a refresh that
    /// was running when the owner pasted an id or picked a candidate never
    /// undoes it. Returns the identity written (an uncertain list loses the
    /// owner's rejected ids, so it can differ from `identity`), for the
    /// result's later writes to guard on; nil when nothing was applied.
    public func applyFetched(name: String, facts: ArtistFacts?, identity: ArtistProfile.Identity, at date: Date,
                             ifIdentityIs expected: ArtistProfile.Identity) -> ArtistProfile.Identity? {
        applyFetchedLocked(name: name, facts: facts, identity: identity, at: date, expected: expected)
    }

    private func applyFetchedLocked(name: String, facts: ArtistFacts?, identity: ArtistProfile.Identity, at date: Date,
                                    expected: ArtistProfile.Identity?) -> ArtistProfile.Identity? {
        let key = ArtistProfileKey.key(for: name)
        guard !key.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let expected, (byKey[key]?.identity ?? .unknown) != expected { return nil }
        var profile = byKey[key] ?? ArtistProfile(foldedKey: key, displayName: name)
        let rejectedIDs = Set(profile.rejectedMusicBrainzIDs)
        var identity = identity
        switch identity {
        case _ where profile.identity == .rejected && identity != .rejected:
            return nil
        case .confirmed(let id, _) where rejectedIDs.contains(id):
            return nil
        case .uncertain(let candidates):
            let kept = candidates.filter { !rejectedIDs.contains($0.musicBrainzID) }
            identity = kept.isEmpty ? .notFound : .uncertain(kept)
        default:
            break
        }
        let before = byKey[key]
        profile.fetched = facts
        profile.identity = identity
        profile.checkedAt = Self.wholeSecond(date)
        if profile != before { put(profile, at: key) }
        return identity
    }

    /// Look Up Again: the identity goes back to `.unknown`, so the next
    /// lookup's answer is taken even after "None of these". The ids the
    /// owner said are "Not This Artist" stay rejected. The owner's word,
    /// so it is dated (`identityChangedByOwnerAt`).
    public func resetIdentity(name: String, at date: Date = Date()) {
        let key = ArtistProfileKey.key(for: name)
        guard !key.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard var profile = byKey[key], profile.identity != .unknown else { return }
        profile.identity = .unknown
        profile.identityChangedByOwnerAt = Self.wholeSecond(date)
        put(profile, at: key)
    }

    /// Stores a photo's bytes in `ArtistPhotos` and adds it to the end of
    /// the profile's photos (creating the profile), or returns the photo
    /// already there with the same bytes. The owner's photos (and migrated
    /// ones, already prepared) are kept as given when they are JPEG or PNG;
    /// fetched ones are scaled to at most 1,600 px on the long side and
    /// re-encoded as JPEG. Anything over 32 MB or 50 megapixels, or not a
    /// whole image, throws, as does a store that could not save. The first
    /// photo of a profile with no default becomes the default, without
    /// counting as the owner's pick.
    @discardableResult
    public func addPhoto(name: String, data: Data, source: ArtistPhoto.Source, sourceID: String?,
                         credit: ArtistPictureCredit?) throws -> ArtistPhoto {
        // A decision that always keeps the photo never refuses: nil cannot come back.
        try addPhoto(name: name, data: data, source: source, sourceID: sourceID, credit: credit) { _, _, _ in true }!
    }

    /// `addPhoto`, decided under the store's lock, so a lookup's photo
    /// lands only on the profile it was meant for. `decide` gets the profile
    /// as it is (nil when there is none), the profile with the photo added
    /// (or unchanged, when the same bytes were already one of its photos),
    /// which it may change further (a swap), and the photo. It must not call
    /// the store. When it returns false nothing is written, not even the
    /// file, and nil comes back. Throws as `addPhoto` does.
    public func addPhoto(name: String, data: Data, source: ArtistPhoto.Source, sourceID: String?,
                         credit: ArtistPictureCredit?,
                         if decide: (_ before: ArtistProfile?, _ after: inout ArtistProfile, _ photo: ArtistPhoto) -> Bool)
        throws -> ArtistPhoto? {
        let key = ArtistProfileKey.key(for: name)
        guard !key.isEmpty else { throw ArtistProfileStoreError.unnamedArtist(name: name) }
        try checkWritable()
        let stored = try ArtistPhotoImage.stored(data, source: source)
        let hash = Self.sha256(stored.data)

        lock.lock()
        defer { lock.unlock() }
        let before = byKey[key]
        var profile = before ?? ArtistProfile(foldedKey: key, displayName: name)
        if let existing = profile.photos.first(where: { $0.hash == hash }) {
            guard decide(before, &profile, existing) else { return nil }
            profile.foldedKey = key
            // The same bytes again, for a photo whose file has gone (another
            // Mac's clean-up, a hand-tidied folder): the file comes back.
            if !hasPhotoFile(hash: hash) { try writePhotoFile(stored, hash: hash) }
            if profile != before { put(profile, at: key) }
            return existing
        }

        let photo = ArtistPhoto(hash: hash, source: source, sourceID: sourceID, credit: credit,
                                pixelWidth: stored.pixelWidth, pixelHeight: stored.pixelHeight,
                                added: Self.wholeSecond(Date()))
        if !profile.photos.contains(where: { $0.hash == profile.defaultPhoto }) {
            profile.defaultPhoto = hash
        }
        profile.photos.append(photo)
        guard decide(before, &profile, photo) else { return nil }
        profile.foldedKey = key

        try writePhotoFile(stored, hash: hash)
        put(profile, at: key)
        return photo
    }

    /// Writes a photo's file unless it is there already. Never intermediate
    /// folders: an index folder that has gone (its drive unplugged) must not
    /// be made again on the boot disk.
    private func writePhotoFile(_ stored: ArtistPhotoImage.Stored, hash: String) throws {
        let url = photosDirectory.appendingPathComponent(hash + "." + stored.fileExtension)
        guard !fileManager.fileExists(atPath: url.path) else { return }
        if !fileManager.fileExists(atPath: photosDirectory.path) {
            try fileManager.createDirectory(at: photosDirectory, withIntermediateDirectories: false)
        }
        try stored.data.write(to: url, options: .atomic)
    }

    /// Removes a photo from the profile. A looked-up photo is remembered in
    /// `rejectedPhotoSources`, so no lookup adds it back. Removing the
    /// default makes the next photo (else the one before) the default, and
    /// the owner's pick is cleared. The file is deleted by the next `save`
    /// when no profile uses it any more.
    public func removePhoto(name: String, hash: String) {
        let key = ArtistProfileKey.key(for: name)
        guard !key.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard var profile = byKey[key], let index = profile.photos.firstIndex(where: { $0.hash == hash }) else {
            return
        }
        let photo = profile.photos.remove(at: index)
        if let rejection = photo.rejectionKey, !profile.rejectedPhotoSources.contains(rejection) {
            profile.rejectedPhotoSources.append(rejection)
        }
        if profile.defaultPhoto == hash {
            profile.defaultPhoto = index < profile.photos.count ? profile.photos[index].hash : profile.photos.last?.hash
            profile.defaultPickedByOwner = false
        }
        put(profile, at: key)
    }

    /// The owner's choice of default photo, which no lookup changes. A hash
    /// the profile does not hold is ignored.
    public func setDefault(name: String, hash: String) {
        let key = ArtistProfileKey.key(for: name)
        guard !key.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard var profile = byKey[key], profile.photos.contains(where: { $0.hash == hash }),
              profile.defaultPhoto != hash || !profile.defaultPickedByOwner else { return }
        profile.defaultPhoto = hash
        profile.defaultPickedByOwner = true
        put(profile, at: key)
    }

    /// A photo's bytes. nil when the hash is not one, the file cannot be
    /// reached (a library drive unplugged, a file deleted) or its bytes no
    /// longer match the hash: the page shows a placeholder for it.
    public func photoData(hash: String) -> Data? {
        guard Self.isHexHash(hash) else { return nil }
        for fileExtension in ArtistPhotoImage.fileExtensions {
            let url = photosDirectory.appendingPathComponent(hash + "." + fileExtension)
            if let data = try? Data(contentsOf: url), Self.sha256(data) == hash { return data }
        }
        return nil
    }

    /// Whether a photo's file is there, without reading it: a cheap check
    /// for many artists at once. `photoData` is the one that proves the bytes.
    /// Takes no lock, so an `addPhoto` decision may call it.
    public func hasPhotoFile(hash: String) -> Bool {
        guard Self.isHexHash(hash) else { return false }
        return ArtistPhotoImage.fileExtensions.contains { fileExtension in
            fileManager.fileExists(atPath: photosDirectory.appendingPathComponent(hash + "." + fileExtension).path)
        }
    }

    /// Where a photo's file is: `<hash>.png` when that exists, else
    /// `<hash>.jpg`. Something that is not a hash names no file of ours; it
    /// gives the folder's `invalid.jpg`, which nothing writes.
    public func photoURL(hash: String) -> URL {
        guard Self.isHexHash(hash) else { return photosDirectory.appendingPathComponent("invalid.jpg") }
        let png = photosDirectory.appendingPathComponent(hash + ".png")
        if fileManager.fileExists(atPath: png.path) { return png }
        return photosDirectory.appendingPathComponent(hash + ".jpg")
    }

    /// Writes `library.cdartistinfo` atomically when anything changed
    /// (canonical bytes: sorted keys, ISO dates), merged with the file as it
    /// is on disk now (`merging(mine:base:disk:)`), so profiles another Mac
    /// added or changed since this store read the file are kept. Then
    /// deletes the photo files this store dropped (`dropped`) that no
    /// profile names, neither in memory nor in the file as it reads after
    /// the write, nor in any backup. Nothing else in `ArtistPhotos` is ever
    /// deleted: a file this store never knew may be another Mac's new photo.
    ///
    /// Throws, writing nothing, when the file on disk could not be read
    /// (now or when the store was made) or the index folder was not there.
    /// After a load that left something out, the file as it was read is
    /// first copied to a backup (`library.cdartistinfo.bak`, or the next
    /// numbered one when that exists), and this store deletes no photo
    /// files at all; the same when the file read again here loses something.
    /// Photos any backup names are never deleted, so restoring one brings
    /// them back.
    public func save() throws {
        lock.lock()
        defer { lock.unlock() }
        try checkWritableLocked()
        if needsBackup {
            try fileManager.copyItem(at: fileURL, to: nextBackupURL())
            needsBackup = false
        }
        if isDirty {
            if let disk = try readFileAgain() {
                byKey = Self.merging(mine: byKey, base: base, disk: disk.profiles)
                migrated = migrated || disk.migrated
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            encoder.dateEncodingStrategy = .iso8601
            let contents = StoredFile(picturesMigrated: migrated, profiles: sortedProfiles())
            try encoder.encode(contents).write(to: fileURL, options: .atomic)
            base = byKey
            isDirty = false
        }
        if !loadWasLossy { sweepDroppedPhotos() }
    }

    // MARK: - Private

    private func checkWritable() throws {
        lock.lock()
        defer { lock.unlock() }
        try checkWritableLocked()
    }

    private func checkWritableLocked() throws {
        if isUnreachable { throw ArtistProfileStoreError.unreachableIndexFolder(path: indexDirectory.path) }
        if isUnreadable { throw ArtistProfileStoreError.unreadableStore(path: fileURL.path) }
    }

    private func sortedProfiles() -> [ArtistProfile] {
        byKey.keys.sorted().compactMap { byKey[$0] }
    }

    /// Sets a changed profile, noting the photos it no longer names. Lock held.
    private func put(_ profile: ArtistProfile, at key: String) {
        if let before = byKey[key] {
            dropped.formUnion(Set(before.photos.map(\.hash)).subtracting(profile.photos.map(\.hash)))
        }
        byKey[key] = profile
        isDirty = true
    }

    /// Deletes the `<hash>.jpg|png` files of the photos this store dropped,
    /// unless a profile in memory, the profiles file as it reads now (read
    /// again just before, so another Mac's latest save counts) or a backup
    /// names them. Nothing else in the folder is touched.
    private func sweepDroppedPhotos() {
        guard !dropped.isEmpty else { return }
        var used = Set(byKey.values.flatMap { $0.photos.map(\.hash) })
        used.formUnion(hashesNamed(byFilesWhere: { $0 == Self.fileName || Self.isBackupName($0) }))
        for hash in dropped where !used.contains(hash) && Self.isHexHash(hash) {
            for fileExtension in ArtistPhotoImage.fileExtensions {
                let url = photosDirectory.appendingPathComponent(hash + "." + fileExtension)
                if fileManager.fileExists(atPath: url.path) { try? fileManager.removeItem(at: url) }
            }
        }
        dropped = []
    }

    /// `library.cdartistinfo.bak` and the numbered ones.
    public static func isBackupName(_ name: String) -> Bool {
        name.hasPrefix(fileName + ".") && name.hasSuffix(".bak")
    }

    /// The profiles file as it is on disk now, for `save` to merge with;
    /// nil when there is none. Throws when it is there and will not read.
    /// A file that reads with losses (a record a newer version wrote) is
    /// first kept as a backup, and this store stops deleting photo files.
    private func readFileAgain() throws -> (profiles: [String: ArtistProfile], migrated: Bool)? {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            throw ArtistProfileStoreError.unreadableStore(path: fileURL.path)
        }
        guard let read = Self.decodeFile(data) else {
            throw ArtistProfileStoreError.unreadableStore(path: fileURL.path)
        }
        // A store whose own load was lossy has kept that file already.
        if read.losses > 0, !loadWasLossy {
            try fileManager.copyItem(at: fileURL, to: nextBackupURL())
            loadWasLossy = true
        }
        return (read.profiles, read.migrated)
    }

    /// `library.cdartistinfo.bak`, else `.2.bak`, `.3.bak`: the first free one.
    private func nextBackupURL() -> URL {
        var candidate = indexDirectory.appendingPathComponent(Self.backupFileName)
        var number = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = indexDirectory.appendingPathComponent("\(Self.fileName).\(number).bak")
            number += 1
        }
        return candidate
    }

    /// Every 64-hex-digit string in the index folder's files whose names
    /// pass `wanted` (the profiles file, its backups), read as text: whatever
    /// they name stays, even where their records would not decode.
    private func hashesNamed(byFilesWhere wanted: (String) -> Bool) -> Set<String> {
        let names = (try? fileManager.contentsOfDirectory(atPath: indexDirectory.path)) ?? []
        var hashes: Set<String> = []
        var run: [UInt8] = []
        func flush() {
            if run.count == 64 { hashes.insert(String(decoding: run, as: UTF8.self)) }
            run.removeAll(keepingCapacity: true)
        }
        for name in names where wanted(name) {
            guard let data = try? Data(contentsOf: indexDirectory.appendingPathComponent(name)) else { continue }
            for byte in data {
                if (48...57).contains(byte) || (97...102).contains(byte) { run.append(byte) } else { flush() }
            }
            flush()
        }
        return hashes
    }

    /// No file is an empty store, as long as the index folder itself is
    /// there; a missing folder (its drive unplugged) blocks `save`. Any other
    /// failure to read the file, or a file that is neither a list nor
    /// `{"profiles": [...]}`, marks the store unreadable, which blocks
    /// `save`. Inside, a record that will not decode is skipped and the rest
    /// load; a wrong key is put right; two records for one key are merged.
    private func load() {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch CocoaError.fileReadNoSuchFile {
            var isFolder: ObjCBool = false
            if !fileManager.fileExists(atPath: indexDirectory.path, isDirectory: &isFolder) || !isFolder.boolValue {
                isUnreachable = true
            }
            return
        } catch {
            isUnreadable = true
            return
        }
        guard let read = Self.decodeFile(data) else {
            isUnreadable = true
            return
        }
        byKey = read.profiles
        base = read.profiles
        migrated = read.migrated
        if read.rekeyed { isDirty = true }
        if read.losses > 0 {
            needsBackup = true
            loadWasLossy = true
            isDirty = true
        }
    }

    /// The profiles in a file's bytes, by folded key: nil when the bytes are
    /// neither a list nor `{"profiles": [...]}`. Inside, a record that will
    /// not decode or has no name is skipped and counted as a loss, a wrong
    /// key is put right (`rekeyed`), and two records for one key are merged
    /// (a loss too, so the file as read is kept).
    static func decodeFile(_ data: Data)
        -> (profiles: [String: ArtistProfile], migrated: Bool, losses: Int, rekeyed: Bool)? {
        let losses = DecodingLosses()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.userInfo[.decodingLosses] = losses
        let rows: [LossyElement<ArtistProfile>]
        var migrated = false
        if let list = try? decoder.decode([LossyElement<ArtistProfile>].self, from: data) {
            rows = list
        } else if let file = try? decoder.decode(LoadedFile.self, from: data) {
            rows = file.profiles
            migrated = file.picturesMigrated
        } else {
            return nil
        }
        var profiles: [String: ArtistProfile] = [:]
        var rekeyed = false
        for case var profile? in rows.map(\.value) {
            let key = ArtistProfileKey.key(for: profile.displayName)
            guard !key.isEmpty else {
                losses.count += 1
                continue
            }
            if profile.foldedKey != key {
                profile.foldedKey = key
                rekeyed = true
            }
            if let earlier = profiles[key] {
                profile = merged(earlier, profile)
                losses.count += 1
            }
            profiles[key] = profile
        }
        return (profiles, migrated, losses.count, rekeyed)
    }

    /// Two records for one artist (a hand-edited file, two spellings that
    /// fold alike) made one. The owner's data wins: owner facts field by
    /// field (the first record's where both set one), photos, candidates
    /// and rejections united, an owner-picked default, either "no photo" or
    /// "not on the iPod". The lookup's state (identity, fetched facts,
    /// checked date) comes whole from the record checked last, unless the
    /// other one carries the owner's "None of these".
    static func merged(_ first: ArtistProfile, _ second: ArtistProfile) -> ArtistProfile {
        func united<T: Equatable>(_ a: [T], _ b: [T]) -> [T] { a + b.filter { !a.contains($0) } }
        var result = first
        if let other = second.owner {
            result.owner = first.owner.map { $0.filling(from: other) } ?? other
        }
        result.photos = united(first.photos, second.photos.filter { photo in
            !first.photos.contains { $0.hash == photo.hash }
        })
        result.photoCandidates = united(first.photoCandidates, second.photoCandidates)
        result.rejectedPhotoSources = united(first.rejectedPhotoSources, second.rejectedPhotoSources)
        result.rejectedMusicBrainzIDs = united(first.rejectedMusicBrainzIDs, second.rejectedMusicBrainzIDs)
        if !first.defaultPickedByOwner,
           second.defaultPickedByOwner || !first.photos.contains(where: { $0.hash == first.defaultPhoto }) {
            result.defaultPhoto = second.defaultPhoto
            result.defaultPickedByOwner = second.defaultPickedByOwner
        }
        result.noPhoto = first.noPhoto || second.noPhoto
        result.notOnIPod = first.notOnIPod || second.notOnIPod
        result.photoSearchedAt = [first.photoSearchedAt, second.photoSearchedAt].compactMap { $0 }.max()
        let secondIsNewer = (second.checkedAt ?? .distantPast) > (first.checkedAt ?? .distantPast)
        let takeSecond = first.identity != .rejected && (second.identity == .rejected || secondIsNewer)
        if takeSecond {
            result.identity = second.identity
            result.fetched = second.fetched
            result.checkedAt = second.checkedAt
            result.identityChangedByOwnerAt = second.identityChangedByOwnerAt
        }
        return result
    }

    // MARK: - Merging with another writer's save

    /// What `save` writes when the file changed on disk since this store
    /// read it (`base`): a three-way merge, profile by profile.
    ///
    /// A profile only one side changed is that side's, whole; one only the
    /// file has (another Mac added it) is kept. For a profile both changed,
    /// field by field: **a field this store changed since it read the file
    /// wins; any other field is the file's.** When both changed the same
    /// field, this save is the newer edit and wins. The owner's facts merge
    /// field by field the same way. Who the artist is (identity, fetched
    /// facts, `checkedAt`, `identityChangedByOwnerAt`) moves as one: when
    /// the owner said who it is on either side since the base, the side
    /// whose owner word is newer (this store on a tie), so a lookup never
    /// undoes the owner, whatever its `checkedAt`; else the side whose
    /// lookup is newer by `checkedAt` (this store on a tie). A confirmed id
    /// the merged `rejectedMusicBrainzIDs` holds (one Mac confirmed it, the
    /// other said "Not This Artist") falls back to `.unknown`, looked up again. Lists (photos, candidates, rejected ids and
    /// sources) take the file's list with this store's own additions and
    /// removals applied. The default photo and whether the owner picked it
    /// move together; a default no longer among the photos falls to the
    /// first one, not as the owner's pick. `photoSearchedAt` is the later.
    static func merging(mine: [String: ArtistProfile], base: [String: ArtistProfile],
                        disk: [String: ArtistProfile]) -> [String: ArtistProfile] {
        var result = disk
        for (key, profile) in mine {
            let original = base[key]
            guard let theirs = disk[key] else {
                result[key] = profile
                continue
            }
            if theirs == original {
                result[key] = profile
            } else if profile != original {
                result[key] = merged3(mine: profile,
                                      base: original ?? ArtistProfile(foldedKey: key, displayName: profile.displayName),
                                      disk: theirs)
            }
        }
        return result
    }

    private static func merged3(mine: ArtistProfile, base: ArtistProfile, disk: ArtistProfile) -> ArtistProfile {
        var result = disk
        func take<T: Equatable>(_ path: WritableKeyPath<ArtistProfile, T>) {
            if mine[keyPath: path] != base[keyPath: path] { result[keyPath: path] = mine[keyPath: path] }
        }
        func lists<T: Equatable>(_ path: WritableKeyPath<ArtistProfile, [T]>) {
            let removed = base[keyPath: path].filter { !mine[keyPath: path].contains($0) }
            var list = disk[keyPath: path].filter { !removed.contains($0) }
            for item in mine[keyPath: path] where !base[keyPath: path].contains(item) && !list.contains(item) {
                list.append(item)
            }
            result[keyPath: path] = list
        }
        take(\.displayName)
        take(\.noPhoto)
        take(\.notOnIPod)
        lists(\.rejectedMusicBrainzIDs)
        lists(\.photoCandidates)
        lists(\.rejectedPhotoSources)

        let ownerHere = mine.identityChangedByOwnerAt != base.identityChangedByOwnerAt
        let ownerThere = disk.identityChangedByOwnerAt != base.identityChangedByOwnerAt
        let takeMine: Bool
        if ownerHere || ownerThere {
            takeMine = ownerHere && (!ownerThere || (mine.identityChangedByOwnerAt ?? .distantPast)
                >= (disk.identityChangedByOwnerAt ?? .distantPast))
        } else {
            let lookupHere = mine.identity != base.identity || mine.fetched != base.fetched
                || mine.checkedAt != base.checkedAt
            let lookupThere = disk.identity != base.identity || disk.fetched != base.fetched
                || disk.checkedAt != base.checkedAt
            takeMine = lookupHere
                && (!lookupThere || (mine.checkedAt ?? .distantPast) >= (disk.checkedAt ?? .distantPast))
        }
        if takeMine {
            result.identity = mine.identity
            result.fetched = mine.fetched
            result.checkedAt = mine.checkedAt
            result.identityChangedByOwnerAt = mine.identityChangedByOwnerAt
        }
        if case .confirmed(let id, _) = result.identity, result.rejectedMusicBrainzIDs.contains(id) {
            result.identity = .unknown
            result.fetched = nil
            result.checkedAt = nil
        }
        result.owner = mergedFacts(mine: mine.owner, base: base.owner, disk: disk.owner)

        // Photos by hash: this store's removals and additions on the file's
        // list; an entry this store changed (a migrated original's address)
        // is this store's.
        let baseHashes = Set(base.photos.map(\.hash)), mineHashes = Set(mine.photos.map(\.hash))
        var photos = disk.photos.filter { !baseHashes.contains($0.hash) || mineHashes.contains($0.hash) }
        for photo in mine.photos {
            if let at = photos.firstIndex(where: { $0.hash == photo.hash }) {
                if base.photos.first(where: { $0.hash == photo.hash }) != photo { photos[at] = photo }
            } else if !baseHashes.contains(photo.hash) {
                photos.append(photo)
            }
        }
        result.photos = photos
        if mine.defaultPhoto != base.defaultPhoto || mine.defaultPickedByOwner != base.defaultPickedByOwner {
            result.defaultPhoto = mine.defaultPhoto
            result.defaultPickedByOwner = mine.defaultPickedByOwner
        }
        if !result.photos.contains(where: { $0.hash == result.defaultPhoto }) {
            result.defaultPhoto = result.photos.first?.hash
            result.defaultPickedByOwner = false
        }
        result.photoSearchedAt = [mine.photoSearchedAt, disk.photoSearchedAt].compactMap { $0 }.max()
        return result
    }

    /// The owner's facts, field by field: this store's where it changed one, else the file's.
    private static func mergedFacts(mine: ArtistFacts?, base: ArtistFacts?, disk: ArtistFacts?) -> ArtistFacts? {
        let m = mine ?? ArtistFacts(), b = base ?? ArtistFacts()
        var result = disk ?? ArtistFacts()
        func take<T: Equatable>(_ path: WritableKeyPath<ArtistFacts, T>) {
            if m[keyPath: path] != b[keyPath: path] { result[keyPath: path] = m[keyPath: path] }
        }
        take(\.kind)
        take(\.origin)
        take(\.begin)
        take(\.end)
        take(\.bio)
        take(\.bioSourceURL)
        take(\.members)
        take(\.genres)
        take(\.links)
        return result == ArtistFacts() && mine == nil && disk == nil ? nil : result
    }

    /// What is written: `{"picturesMigrated": ..., "profiles": [...]}`.
    private struct StoredFile: Encodable {
        let picturesMigrated: Bool
        let profiles: [ArtistProfile]
    }

    /// What is read: the profiles are required, the flag is lenient.
    private struct LoadedFile: Decodable {
        let picturesMigrated: Bool
        let profiles: [LossyElement<ArtistProfile>]

        enum CodingKeys: String, CodingKey { case picturesMigrated, profiles }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            profiles = try c.decode([LossyElement<ArtistProfile>].self, forKey: .profiles)
            picturesMigrated = c.lenient(Bool.self, .picturesMigrated) ?? false
        }
    }

    /// The file keeps ISO 8601 dates, to the second; a date kept in memory
    /// is cut to the same, so a profile reads back exactly as it was saved.
    private static func wholeSecond(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded(.down))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 64 lowercase hex digits: the only thing that names a photo file.
    static func isHexHash(_ hash: String) -> Bool {
        hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// Turns the bytes of a new artist photo into the bytes stored for it.
/// Shares the picture preparer's limits (`ArtistPictureImage`): at most 32 MB
/// and 50 megapixels, and a JPEG or PNG must reach its end.
enum ArtistPhotoImage {
    /// The longest side a fetched photo is stored at.
    static let fetchedLongSide = 1_600
    static let fetchedQuality: CGFloat = 0.85
    static let fileExtensions = ["jpg", "png"]

    struct Stored {
        let data: Data
        let fileExtension: String
        let pixelWidth: Int
        let pixelHeight: Int
    }

    /// The owner's photos and migrated ones are kept byte for byte when they
    /// are JPEG or PNG; any other format the owner gives (HEIC, TIFF) is
    /// re-encoded as JPEG at its own size. Fetched photos are always
    /// re-encoded as JPEG, scaled down to 1,600 px on the long side.
    /// `reportedSize` stands in for the header's size in tests.
    static func stored(_ data: Data, source: ArtistPhoto.Source, reportedSize: CGSize? = nil) throws -> Stored {
        guard !data.isEmpty else { throw ArtistProfileStoreError.unreadablePhoto }
        guard data.count <= ArtistPictureImage.maximumSourceBytes else { throw ArtistProfileStoreError.photoTooLarge }
        guard let image = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(image) > 0,
              CGImageSourceGetStatusAtIndex(image, 0) == .statusComplete,
              let size = reportedSize ?? ArtistPictureImage.headerSize(image) else {
            throw ArtistProfileStoreError.unreadablePhoto
        }
        guard size.width * size.height <= CGFloat(ArtistPictureImage.maximumSourceArea) else {
            throw ArtistProfileStoreError.photoTooLarge
        }
        let type = CGImageSourceGetType(image) as String?
        let isWhole = ArtistPictureImage.isWhole(data, type: type)
        let keptAsGiven = source == .owner || source == .migrated

        if keptAsGiven, type == UTType.jpeg.identifier || type == UTType.png.identifier {
            guard isWhole else { throw ArtistProfileStoreError.unreadablePhoto }
            return Stored(data: data, fileExtension: type == UTType.png.identifier ? "png" : "jpg",
                          pixelWidth: Int(size.width), pixelHeight: Int(size.height))
        }
        // A download must prove it is complete; the owner's own HEIC or
        // TIFF cannot be walked, and ImageIO's decode is trusted for it.
        guard keptAsGiven || isWhole else { throw ArtistProfileStoreError.unreadablePhoto }

        let longSide = Int(max(size.width, size.height))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: keptAsGiven ? longSide : min(longSide, fetchedLongSide),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary),
              let opaque = flattened(decoded), let jpeg = encodeJPEG(opaque) else {
            throw ArtistProfileStoreError.unreadablePhoto
        }
        return Stored(data: jpeg, fileExtension: "jpg", pixelWidth: opaque.width, pixelHeight: opaque.height)
    }

    /// The image drawn into an opaque sRGB context over white, so a
    /// transparent area reads as paper rather than black once it is a JPEG.
    private static func flattened(_ image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(bounds)
        context.interpolationQuality = .high
        context.draw(image, in: bounds)
        return context.makeImage()
    }

    private static func encodeJPEG(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: fetchedQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
