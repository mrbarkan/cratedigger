import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ArtistProfileStoreError: LocalizedError, Equatable {
    /// The profiles file is present but would not read. Reported instead of
    /// saving, so the owner's edits are not replaced by what is in memory.
    case unreadableStore(path: String)
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
/// `addPhoto` decodes and re-encodes images.
public final class ArtistProfileStore: @unchecked Sendable {
    public static let fileName = "library.cdartistinfo", photosFolder = "ArtistPhotos"

    private let fileURL: URL
    private let photosDirectory: URL
    private let fileManager: FileManager
    private var byKey: [String: ArtistProfile] = [:]
    /// Hashes whose last reference may have gone: their files are deleted
    /// by the next `save`, once the index no longer names them.
    private var possiblyUnused: Set<String> = []
    private var isDirty = false
    private var isUnreadable = false
    private let lock = NSLock()

    public init(indexDirectory: URL, fileManager: FileManager = .default) {
        fileURL = indexDirectory.appendingPathComponent(Self.fileName)
        photosDirectory = indexDirectory.appendingPathComponent(Self.photosFolder, isDirectory: true)
        self.fileManager = fileManager
        load()
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
    public func applyFetched(name: String, facts: ArtistFacts?, identity: ArtistProfile.Identity, at date: Date) {
        update(name: name) { profile in
            profile.fetched = facts
            profile.identity = identity
            profile.checkedAt = Self.wholeSecond(date)
        }
    }

    /// Stores a photo's bytes in `ArtistPhotos` and adds it to the end of
    /// the profile's photos (creating the profile), or returns the photo
    /// already there with the same bytes. The owner's photos (and migrated
    /// ones, already prepared) are kept as given when they are JPEG or PNG;
    /// fetched ones are scaled to at most 1,600 px on the long side and
    /// re-encoded as JPEG. Anything over 32 MB or 50 megapixels, or not a
    /// whole image, throws. The first photo of a profile with no default
    /// becomes the default, without counting as the owner's pick.
    @discardableResult
    public func addPhoto(name: String, data: Data, source: ArtistPhoto.Source, sourceID: String?,
                         credit: ArtistPictureCredit?) throws -> ArtistPhoto {
        let key = PodBoxArtName.folded(name)
        guard !key.isEmpty else { throw ArtistProfileStoreError.unnamedArtist(name: name) }
        let stored = try ArtistPhotoImage.stored(data, source: source)
        let hash = Self.sha256(stored.data)

        lock.lock()
        defer { lock.unlock() }
        var profile = byKey[key] ?? ArtistProfile(foldedKey: key, displayName: name)
        if let existing = profile.photos.first(where: { $0.hash == hash }) { return existing }

        let url = photosDirectory.appendingPathComponent(hash + "." + stored.fileExtension)
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: photosDirectory, withIntermediateDirectories: true)
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
        possiblyUnused.insert(hash)
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
    /// (canonical bytes: sorted keys, ISO dates), then deletes the files of
    /// photos no profile uses any more. Throws, writing nothing, when the
    /// file on disk could not be read.
    public func save() throws {
        lock.lock()
        defer { lock.unlock() }
        if isUnreadable { throw ArtistProfileStoreError.unreadableStore(path: fileURL.path) }
        if isDirty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(sortedProfiles()).write(to: fileURL, options: .atomic)
            isDirty = false
        }
        guard !possiblyUnused.isEmpty else { return }
        let used = Set(byKey.values.flatMap { $0.photos.map(\.hash) })
        for hash in possiblyUnused where !used.contains(hash) && Self.isHexHash(hash) {
            for fileExtension in ArtistPhotoImage.fileExtensions {
                try? fileManager.removeItem(at: photosDirectory.appendingPathComponent(hash + "." + fileExtension))
            }
        }
        possiblyUnused.removeAll()
    }

    // MARK: - Private

    private func sortedProfiles() -> [ArtistProfile] {
        byKey.keys.sorted().compactMap { byKey[$0] }
    }

    /// No file is an empty store. Any other failure to read it, or a file
    /// that is not a list, marks the store unreadable, which blocks `save`.
    /// Inside the list, a record that will not decode is skipped and the
    /// rest load; a wrong key is put right, and of two records for one key
    /// the first is kept.
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
        guard let rows = try? decoder.decode([LossyElement<ArtistProfile>].self, from: data) else {
            isUnreadable = true
            return
        }
        for case var profile? in rows.map(\.value) {
            let key = PodBoxArtName.folded(profile.displayName)
            guard !key.isEmpty, byKey[key] == nil else {
                isDirty = true
                continue
            }
            if profile.foldedKey != key {
                profile.foldedKey = key
                isDirty = true
            }
            byKey[key] = profile
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
