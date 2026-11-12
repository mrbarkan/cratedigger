import Foundation

/// Carries the iPod's artist pictures (`library.cdartists`) into artist
/// profiles, once, so the app and the iPod share one record per artist.
///
/// Every record with prepared bytes becomes a `.migrated` photo and its
/// profile's default: the owner's pick (`pickedByUser`) as an owner-picked
/// default, an automatic find as an ordinary one. A Deezer or Commons photo
/// whose original the record can still name gets `replaceFromURL`, so the
/// background worker can swap the 400 px copy for a full-size one. "No
/// Picture" (`.rejected`) becomes `notOnIPod`, which hides nothing in the
/// app. Held candidates and credits carry over. Once the profiles are saved,
/// `library.cdartists` is renamed `library.cdartists.bak` (never deleted),
/// which is also what marks the migration as done.
///
/// Reads images and writes files: run it off the main actor, after
/// `refuseWhileLibraryDisconnected`.
public enum ArtistProfileMigration {
    /// Runs once: returns false when there was nothing to migrate or it already ran.
    @discardableResult
    public static func migrate(pictures: ArtistPictureStore, into profiles: ArtistProfileStore,
                               indexDirectory: URL, fileManager: FileManager = .default) throws -> Bool {
        let oldFile = indexDirectory.appendingPathComponent(ArtistPictureStore.fileName)
        // No file: it already ran, or there never were pictures. An empty or
        // unreadable file reads as no records; it is left where it is.
        guard fileManager.fileExists(atPath: oldFile.path) else { return false }
        let records = pictures.allRecords()
        guard !records.isEmpty else { return false }

        for record in records {
            try carry(record, from: pictures, into: profiles)
        }
        try profiles.save()
        try fileManager.moveItem(at: oldFile, to: backupURL(for: oldFile, fileManager: fileManager))
        return true
    }

    // MARK: - Private

    private static func carry(_ record: ArtistPictureRecord, from pictures: ArtistPictureStore,
                              into profiles: ArtistProfileStore) throws {
        let name = record.displayName
        if let bytes = pictures.preparedData(for: record) {
            let photo: ArtistPhoto?
            do {
                photo = try profiles.addPhoto(name: name, data: bytes, source: .migrated,
                                              sourceID: migratedSourceID(record), credit: record.credit)
            } catch ArtistProfileStoreError.unreadablePhoto, ArtistProfileStoreError.photoTooLarge {
                // A cached picture that no longer reads: the background
                // worker finds one again. Anything else (a disk that will
                // not take the file) stops the migration.
                photo = nil
            }
            if let photo {
                let replaceFrom = replaceURL(for: record)
                profiles.update(name: name) { profile in
                    if let index = profile.photos.firstIndex(where: { $0.hash == photo.hash }),
                       profile.photos[index].replaceFromURL == nil {
                        profile.photos[index].replaceFromURL = replaceFrom
                    }
                    if record.pickedByUser {
                        profile.defaultPhoto = photo.hash
                        profile.defaultPickedByOwner = true
                    } else if !profile.defaultPickedByOwner {
                        profile.defaultPhoto = photo.hash
                    }
                }
            }
        }
        if record.outcome == .rejected {
            profiles.update(name: name) { $0.notOnIPod = true }
        }
        if let held = record.candidates, !held.isEmpty {
            profiles.update(name: name) { profile in
                for candidate in held where !profile.photoCandidates.contains(candidate) {
                    profile.photoCandidates.append(candidate)
                }
            }
        }
    }

    /// `<source>:<id>` in the profile photo's own source names (`deezer:42`,
    /// `commons:<MusicBrainz id>`), so the photo's `rejectionKey` matches
    /// what a later lookup of that source would add. nil without an id.
    static func migratedSourceID(_ record: ArtistPictureRecord) -> String? {
        guard let source = record.source, let id = record.sourceID, !id.isEmpty else { return nil }
        let name: String
        switch source {
        case .userFile: name = ArtistPhoto.Source.owner.rawValue
        case .libraryFolder: name = ArtistPhoto.Source.library.rawValue
        case .deezer: name = ArtistPhoto.Source.deezer.rawValue
        case .commons: name = ArtistPhoto.Source.commons.rawValue
        case .fanartTV, .discogs, .theAudioDB: name = source.rawValue
        }
        return "\(name):\(id)"
    }

    /// Where the full-size original of a Deezer or Commons picture is: the
    /// held candidate with the record's own id when the record kept one,
    /// else, for Commons, the file the credit names (at most 1,600 px wide,
    /// the size fetched photos are stored at). nil otherwise: a found
    /// Deezer record keeps only the artist's id, not the picture's address.
    static func replaceURL(for record: ArtistPictureRecord) -> URL? {
        guard let source = record.source, source == .deezer || source == .commons else { return nil }
        if let held = record.candidates?.first(where: { $0.source == source && $0.sourceID == record.sourceID }) {
            return held.imageURL
        }
        if source == .commons, let fileName = record.credit?.fileName, !fileName.isEmpty {
            return CommonsArtistParser.imageURL(fileName: fileName, width: ArtistPhotoImage.fetchedLongSide)
        }
        return nil
    }

    /// `library.cdartists.bak`, or `.2.bak`, `.3.bak` when an earlier one is
    /// there: a backup is never written over.
    private static func backupURL(for file: URL, fileManager: FileManager) -> URL {
        let folder = file.deletingLastPathComponent(), name = file.lastPathComponent
        var candidate = folder.appendingPathComponent(name + ".bak")
        var number = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(name).\(number).bak")
            number += 1
        }
        return candidate
    }
}
