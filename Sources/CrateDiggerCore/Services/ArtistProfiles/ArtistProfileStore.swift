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
            return "\"\(name)\" has no letters or digits to keep an artist profile under."
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
/// index file). Profiles are keyed by `PodBoxArtName.folded` of the name.
///
/// Everything here writes on the Mac only, and callers check
/// `refuseWhileLibraryDisconnected` first. Safe to use from any thread:
/// every member holds one lock, so a background lookup and the artist page
/// can share it. Do not call it from AppKit's main thread for photo work:
/// `addPhoto` decodes and re-encodes images. Keep one store per index
/// folder: `save` deletes photo files its own profiles do not name.
public final class ArtistProfileStore: @unchecked Sendable {
    public static let fileName = "library.cdartistinfo", photosFolder = "ArtistPhotos"
    /// The one-time copy of a file that did not load whole, kept beside it.
    public static let backupFileName = fileName + ".bak"

    private let indexDirectory: URL
    private let fileURL: URL
    private let photosDirectory: URL
    private let fileManager: FileManager
    private var byKey: [String: ArtistProfile] = [:]
    private var migrated = false
    private var isDirty = false
    private var isUnreadable = false
    private var isUnreachable = false
    /// The load left something out (a record or an element that would not
    /// decode, a nameless record, two records merged): the next save first
    /// keeps a copy of the file as it was read.
    private var needsBackup = false
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
    /// name folds to nothing.
    public func profile(forName name: String) -> ArtistProfile? {
        let key = PodBoxArtName.folded(name)
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
    /// is none. A name that folds to nothing is ignored. The closure runs
    /// under the store's lock, so it must not call the store, and it cannot
    /// move the profile to another key.
    public func update(name: String, _ change: (inout ArtistProfile) -> Void) {
        let key = PodBoxArtName.folded(name)
        guard !key.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let before = byKey[key]
        var profile = before ?? ArtistProfile(foldedKey: key, displayName: name)
        change(&profile)
        profile.foldedKey = key
        guard profile != before else { return }
        byKey[key] = profile
        isDirty = true
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
        let key = PodBoxArtName.folded(name)
        guard !key.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        var profile = byKey[key] ?? ArtistProfile(foldedKey: key, displayName: name)
        let rejectedIDs = Set(profile.rejectedMusicBrainzIDs)
        var identity = identity
        switch identity {
        case _ where profile.identity == .rejected && identity != .rejected:
            return false
        case .confirmed(let id, _) where rejectedIDs.contains(id):
            return false
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
        if profile != before {
            byKey[key] = profile
            isDirty = true
        }
        return true
    }

    /// Look Up Again: the identity goes back to `.unknown`, so the next
    /// lookup's answer is taken even after "None of these". The ids the
    /// owner said are "Not This Artist" stay rejected.
    public func resetIdentity(name: String) {
        let key = PodBoxArtName.folded(name)
        guard !key.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard var profile = byKey[key], profile.identity != .unknown else { return }
        profile.identity = .unknown
        byKey[key] = profile
        isDirty = true
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
        let key = PodBoxArtName.folded(name)
        guard !key.isEmpty else { throw ArtistProfileStoreError.unnamedArtist(name: name) }
        try checkWritable()
        let stored = try ArtistPhotoImage.stored(data, source: source)
        let hash = Self.sha256(stored.data)

        lock.lock()
        defer { lock.unlock() }
        var profile = byKey[key] ?? ArtistProfile(foldedKey: key, displayName: name)
        if let existing = profile.photos.first(where: { $0.hash == hash }) { return existing }

        let url = photosDirectory.appendingPathComponent(hash + "." + stored.fileExtension)
        if !fileManager.fileExists(atPath: url.path) {
            // Never intermediate folders: an index folder that has gone
            // (its drive unplugged) must not be made again on the boot disk.
            if !fileManager.fileExists(atPath: photosDirectory.path) {
                try fileManager.createDirectory(at: photosDirectory, withIntermediateDirectories: false)
            }
            try stored.data.write(to: url, options: .atomic)
        }
        let photo = ArtistPhoto(hash: hash, source: source, sourceID: sourceID, credit: credit,
                                pixelWidth: stored.pixelWidth, pixelHeight: stored.pixelHeight,
                                added: Self.wholeSecond(Date()))
        if !profile.photos.contains(where: { $0.hash == profile.defaultPhoto }) {
            profile.defaultPhoto = hash
        }
        profile.photos.append(photo)
        byKey[key] = profile
        isDirty = true
        return photo
    }

    /// Removes a photo from the profile. A looked-up photo is remembered in
    /// `rejectedPhotoSources`, so no lookup adds it back. Removing the
    /// default makes the next photo (else the one before) the default, and
    /// the owner's pick is cleared. The file is deleted by the next `save`
    /// when no profile uses it any more.
    public func removePhoto(name: String, hash: String) {
        let key = PodBoxArtName.folded(name)
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
        byKey[key] = profile
        isDirty = true
    }

    /// The owner's choice of default photo, which no lookup changes. A hash
    /// the profile does not hold is ignored.
    public func setDefault(name: String, hash: String) {
        let key = PodBoxArtName.folded(name)
        guard !key.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard var profile = byKey[key], profile.photos.contains(where: { $0.hash == hash }),
              profile.defaultPhoto != hash || !profile.defaultPickedByOwner else { return }
        profile.defaultPhoto = hash
        profile.defaultPickedByOwner = true
        byKey[key] = profile
        isDirty = true
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
    /// (canonical bytes: sorted keys, ISO dates), then deletes every photo
    /// file in `ArtistPhotos` that no profile names (a removed photo, or one
    /// left by a crash between `addPhoto` and `save`). Throws, writing
    /// nothing, when the file on disk could not be read or the index folder
    /// was not there. After a load that left something out, the file as it
    /// was read is first copied to `library.cdartistinfo.bak` (once: an
    /// existing backup is kept), and photos that backup names are never
    /// deleted, so restoring it brings them back.
    public func save() throws {
        lock.lock()
        defer { lock.unlock() }
        try checkWritableLocked()
        if needsBackup {
            let backup = indexDirectory.appendingPathComponent(Self.backupFileName)
            if !fileManager.fileExists(atPath: backup.path) {
                try fileManager.copyItem(at: fileURL, to: backup)
            }
            needsBackup = false
        }
        if isDirty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            encoder.dateEncodingStrategy = .iso8601
            let contents = StoredFile(picturesMigrated: migrated, profiles: sortedProfiles())
            try encoder.encode(contents).write(to: fileURL, options: .atomic)
            isDirty = false
        }
        sweepUnusedPhotos()
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

    /// Deletes `<hash>.jpg|png` files no profile names. Only names that are
    /// a hash and one of our extensions are touched; anything else the owner
    /// put in the folder stays.
    private func sweepUnusedPhotos() {
        guard let names = try? fileManager.contentsOfDirectory(atPath: photosDirectory.path) else { return }
        var used = Set(byKey.values.flatMap { $0.photos.map(\.hash) })
        used.formUnion(hashesNamedByBackup())
        for name in names {
            let file = URL(fileURLWithPath: name)
            let hash = file.deletingPathExtension().lastPathComponent
            guard ArtistPhotoImage.fileExtensions.contains(file.pathExtension), Self.isHexHash(hash),
                  !used.contains(hash) else { continue }
            try? fileManager.removeItem(at: photosDirectory.appendingPathComponent(name))
        }
    }

    /// Every 64-hex-digit string in the backup file, read as text: whatever
    /// it names stays restorable even where its records would not decode.
    private func hashesNamedByBackup() -> Set<String> {
        let backup = indexDirectory.appendingPathComponent(Self.backupFileName)
        guard let data = try? Data(contentsOf: backup) else { return [] }
        var hashes: Set<String> = []
        var run: [UInt8] = []
        func flush() {
            if run.count == 64 { hashes.insert(String(decoding: run, as: UTF8.self)) }
            run.removeAll(keepingCapacity: true)
        }
        for byte in data {
            if (48...57).contains(byte) || (97...102).contains(byte) { run.append(byte) } else { flush() }
        }
        flush()
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
        let losses = DecodingLosses()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.userInfo[.decodingLosses] = losses
        let rows: [LossyElement<ArtistProfile>]
        if let list = try? decoder.decode([LossyElement<ArtistProfile>].self, from: data) {
            rows = list
        } else if let file = try? decoder.decode(LoadedFile.self, from: data) {
            rows = file.profiles
            migrated = file.picturesMigrated
        } else {
            isUnreadable = true
            return
        }
        for case var profile? in rows.map(\.value) {
            let key = PodBoxArtName.folded(profile.displayName)
            guard !key.isEmpty else {
                losses.count += 1
                continue
            }
            if profile.foldedKey != key {
                profile.foldedKey = key
                isDirty = true
            }
            if let earlier = byKey[key] {
                profile = Self.merged(earlier, profile)
                losses.count += 1
            }
            byKey[key] = profile
        }
        if losses.count > 0 {
            needsBackup = true
            isDirty = true
        }
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
        let secondIsNewer = (second.checkedAt ?? .distantPast) > (first.checkedAt ?? .distantPast)
        let takeSecond = first.identity != .rejected && (second.identity == .rejected || secondIsNewer)
        if takeSecond {
            result.identity = second.identity
            result.fetched = second.fetched
            result.checkedAt = second.checkedAt
        }
        return result
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
