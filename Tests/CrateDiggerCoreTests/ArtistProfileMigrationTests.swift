import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CrateDiggerCore

final class ArtistProfileMigrationTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtistProfileMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var oldFile: URL { folder.appendingPathComponent(ArtistPictureStore.fileName) }
    private var bakFile: URL { folder.appendingPathComponent(ArtistPictureStore.fileName + ".bak") }
    private let checked = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func pictureStore() -> ArtistPictureStore {
        ArtistPictureStore(indexDirectory: folder, imageDirectory: folder.appendingPathComponent("ArtistImages"))
    }

    /// The bytes the picture store holds for a found picture: a prepared 400 px JPEG.
    private func prepared(shade: CGFloat) throws -> Data {
        let context = CGContext(data: nil, width: 500, height: 500, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: shade, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 500, height: 500))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return try XCTUnwrap(ArtistPictureImage.prepare(output as Data))
    }

    private func record(_ name: String, _ outcome: ArtistPictureRecord.Outcome, source: ArtistPictureSourceID? = nil,
                        sourceID: String? = nil, picked: Bool = false, credit: ArtistPictureCredit? = nil,
                        candidates: [ArtistPictureRecord.HeldCandidate]? = nil) -> ArtistPictureRecord {
        ArtistPictureRecord(foldedKey: "", displayName: name, outcome: outcome, source: source, sourceID: sourceID,
                            pickedByUser: picked, checkedAt: checked, credit: credit, candidates: candidates)
    }

    /// Saves `records` (with their bytes) as a `library.cdartists`, then migrates.
    @discardableResult
    private func migrate(_ records: [(ArtistPictureRecord, Data?)], into profiles: ArtistProfileStore? = nil)
        throws -> (ArtistProfileStore, Bool) {
        let pictures = pictureStore()
        for (record, bytes) in records { try pictures.set(record, prepared: bytes) }
        try pictures.save()
        let store = profiles ?? ArtistProfileStore(indexDirectory: folder)
        let migrated = try ArtistProfileMigration.migrate(pictures: pictures, into: store, indexDirectory: folder)
        return (store, migrated)
    }

    func testPickedRecordBecomesOwnerDefault() throws {
        let bytes = try prepared(shade: 0.1)
        let (store, migrated) = try migrate([
            (record("AC/DC", .found, source: .userFile, sourceID: "/Music/acdc.jpg", picked: true), bytes),
        ])
        XCTAssertTrue(migrated)
        let profile = try XCTUnwrap(store.profile(forName: "AC/DC"))
        XCTAssertEqual(profile.displayName, "AC/DC")
        XCTAssertEqual(profile.photos.count, 1)
        let photo = try XCTUnwrap(profile.photos.first)
        XCTAssertEqual(photo.source, .migrated)
        XCTAssertEqual(photo.hash, ArtistProfileStore.sha256(bytes), "the prepared bytes are used as they are")
        XCTAssertEqual(store.photoData(hash: photo.hash), bytes)
        XCTAssertEqual(profile.defaultPhoto, photo.hash)
        XCTAssertTrue(profile.defaultPickedByOwner)
        XCTAssertNil(photo.replaceFromURL, "the owner's own file has no original to fetch")
        XCTAssertNil(profile.checkedAt, "facts were never looked up, so the worker still will")
        XCTAssertEqual(profile.identity, .unknown)
    }

    func testFoundRecordBecomesPlainDefault() throws {
        let (store, _) = try migrate([
            (record("Massive Attack", .found, source: .deezer, sourceID: "42"), try prepared(shade: 0.2)),
            (record("Sigur Rós", .notFound), nil),
        ])
        let profile = try XCTUnwrap(store.profile(forName: "Massive Attack"))
        XCTAssertEqual(profile.defaultPhotoRef, profile.photos.first)
        XCTAssertFalse(profile.defaultPickedByOwner)
        XCTAssertFalse(profile.notOnIPod)
        XCTAssertEqual(profile.photos.first?.sourceID, "deezer:42")
        XCTAssertEqual(profile.photos.first?.rejectionKey, "deezer:42",
                       "removing it keeps a later Deezer lookup from adding it back")
        XCTAssertNil(store.profile(forName: "Sigur Rós"), "a plain \"not found\" carries nothing over")
    }

    func testRejectedBecomesNotOnIPod() throws {
        let (store, _) = try migrate([(record("Boston", .rejected), nil)])
        let profile = try XCTUnwrap(store.profile(forName: "Boston"))
        XCTAssertTrue(profile.notOnIPod)
        XCTAssertFalse(profile.noPhoto, "No Picture never hid anything in the app")
        XCTAssertEqual(profile.photos, [])
    }

    func testCandidatesAndCreditCarryOver() throws {
        let held = [
            ArtistPictureRecord.HeldCandidate(
                source: .commons, sourceID: "mb-air", imageURL: URL(string: "https://upload.wikimedia.org/a/Air.jpg")!,
                credit: ArtistPictureCredit(fileName: "Air.jpg", licence: "CC BY 2.0", author: "Someone")),
            ArtistPictureRecord.HeldCandidate(
                source: .deezer, sourceID: "7", imageURL: URL(string: "https://e-cdns-images.dzcdn.net/x.jpg")!),
        ]
        let credit = ArtistPictureCredit(fileName: "Beck 2005.jpg", licence: "CC BY-SA 3.0", author: "A Photographer")
        let (store, _) = try migrate([
            (record("Air", .uncertain, candidates: held), nil),
            (record("Beck", .found, source: .commons, sourceID: "mb-beck", credit: credit), try prepared(shade: 0.3)),
        ])
        XCTAssertEqual(store.profile(forName: "Air")?.photoCandidates, held)
        XCTAssertEqual(store.profile(forName: "Air")?.photos, [])
        XCTAssertEqual(store.profile(forName: "Beck")?.photos.first?.credit, credit)
    }

    func testDeezerAndCommonsGetReplaceURL() throws {
        let kept = URL(string: "https://e-cdns-images.dzcdn.net/images/artist/abc/1000x1000.jpg")!
        let (store, _) = try migrate([
            (record("Beck", .found, source: .commons, sourceID: "mb-beck",
                    credit: ArtistPictureCredit(fileName: "Beck 2005.jpg")), try prepared(shade: 0.1)),
            (record("Low", .found, source: .deezer, sourceID: "9",
                    candidates: [ArtistPictureRecord.HeldCandidate(source: .deezer, sourceID: "9", imageURL: kept)]),
             try prepared(shade: 0.2)),
            (record("Air", .found, source: .deezer, sourceID: "7"), try prepared(shade: 0.3)),
            (record("Björk", .found, source: .libraryFolder, sourceID: "/Music/Bjork/artist.jpg"),
             try prepared(shade: 0.4)),
        ])
        XCTAssertEqual(store.profile(forName: "Beck")?.photos.first?.replaceFromURL,
                       CommonsArtistParser.imageURL(fileName: "Beck 2005.jpg", width: ArtistPhotoImage.fetchedLongSide))
        XCTAssertEqual(store.profile(forName: "Low")?.photos.first?.replaceFromURL, kept)
        XCTAssertNil(store.profile(forName: "Air")?.photos.first?.replaceFromURL, "no URL was kept for it")
        XCTAssertNil(store.profile(forName: "Björk")?.photos.first?.replaceFromURL, "only Deezer and Commons")
    }

    func testOldFileRenamedToBak() throws {
        let (store, _) = try migrate([(record("Air", .found, source: .deezer, sourceID: "7"), try prepared(shade: 0.1))])
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bakFile.path), "kept, never deleted")
        XCTAssertFalse(LibraryIndexFiles.isIndexFile(bakFile), "the backup is not part of the index any more")

        let reloaded = ArtistProfileStore(indexDirectory: folder)
        XCTAssertEqual(reloaded.allProfiles(), store.allProfiles(), "the profiles were saved before the rename")
        XCTAssertEqual(reloaded.allProfiles().count, 1)

        XCTAssertTrue(reloaded.picturesMigrated)

        // A backup from an earlier migration is never written over (here the
        // owner has thrown the profiles away, so the migration runs again).
        try FileManager.default.removeItem(at: folder.appendingPathComponent(ArtistProfileStore.fileName))
        try FileManager.default.copyItem(at: bakFile, to: oldFile)
        let earlier = try Data(contentsOf: bakFile)
        XCTAssertTrue(try ArtistProfileMigration.migrate(pictures: pictureStore(),
                                                         into: ArtistProfileStore(indexDirectory: folder),
                                                         indexDirectory: folder))
        XCTAssertEqual(try Data(contentsOf: bakFile), earlier)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent(ArtistPictureStore.fileName + ".2.bak").path))
    }

    func testSecondRunDoesNothing() throws {
        let pictures = pictureStore()
        try pictures.set(record("Air", .found, source: .deezer, sourceID: "7"), prepared: try prepared(shade: 0.1))
        try pictures.save()
        let store = ArtistProfileStore(indexDirectory: folder)
        XCTAssertTrue(try ArtistProfileMigration.migrate(pictures: pictures, into: store, indexDirectory: folder))
        store.update(name: "Air") { $0.noPhoto = true }
        try store.save()
        let after = store.allProfiles()
        let fileAfter = try Data(contentsOf: folder.appendingPathComponent(ArtistProfileStore.fileName))

        XCTAssertFalse(try ArtistProfileMigration.migrate(pictures: pictures, into: store, indexDirectory: folder))
        XCTAssertEqual(store.allProfiles(), after)
        try store.save()
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(ArtistProfileStore.fileName)), fileAfter)

        // No old file at all, or one with nothing in it: nothing to migrate.
        let empty = folder.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let none = ArtistPictureStore(indexDirectory: empty, imageDirectory: empty.appendingPathComponent("Images"))
        XCTAssertFalse(try ArtistProfileMigration.migrate(pictures: none, into: ArtistProfileStore(indexDirectory: empty),
                                                          indexDirectory: empty))
        try Data("[]".utf8).write(to: empty.appendingPathComponent(ArtistPictureStore.fileName))
        XCTAssertFalse(try ArtistProfileMigration.migrate(pictures: none, into: ArtistProfileStore(indexDirectory: empty),
                                                          indexDirectory: empty))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: empty.appendingPathComponent(ArtistProfileStore.fileName).path))
    }

    /// Review I1: the app still writes `library.cdartists` until the iPod
    /// side reads profiles, so the file can come back. A second migration
    /// must not undo anything the owner did since the first.
    func testOwnerChoicesSurviveTheOldFileComingBack() throws {
        let (store, _) = try migrate([
            (record("Air", .found, source: .deezer, sourceID: "7"), try prepared(shade: 0.1)),
            (record("Beck", .found, source: .commons, sourceID: "mb-beck"), try prepared(shade: 0.2)),
            (record("Boston", .rejected), nil),
        ])
        let air = try XCTUnwrap(store.profile(forName: "Air")?.photos.first)
        store.removePhoto(name: "Air", hash: air.hash)
        let own = try store.addPhoto(name: "Beck", data: try prepared(shade: 0.9), source: .owner, sourceID: nil,
                                     credit: nil)
        store.setDefault(name: "Beck", hash: own.hash)
        store.update(name: "Boston") { $0.notOnIPod = false }
        try store.save()
        let afterOwner = store.allProfiles()

        // The old file reappears (written again by the Artist Pictures sheet).
        try FileManager.default.copyItem(at: bakFile, to: oldFile)
        let reopened = ArtistProfileStore(indexDirectory: folder)
        XCTAssertTrue(reopened.picturesMigrated)
        XCTAssertFalse(try ArtistProfileMigration.migrate(pictures: pictureStore(), into: reopened,
                                                          indexDirectory: folder))
        XCTAssertEqual(reopened.allProfiles(), afterOwner)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldFile.path), "left alone for the app that wrote it")
    }

    func testProfilesThatAlreadyExistAreNotTouched() throws {
        let profiles = ArtistProfileStore(indexDirectory: folder)
        profiles.update(name: "Air") { $0.owner = ArtistFacts(origin: "Versailles") }
        let before = try XCTUnwrap(profiles.profile(forName: "Air"))
        try migrate([
            (record("Air", .found, source: .deezer, sourceID: "7", picked: true), try prepared(shade: 0.1)),
            (record("Beck", .rejected), nil),
        ], into: profiles)
        XCTAssertEqual(profiles.profile(forName: "Air"), before)
        XCTAssertEqual(profiles.profile(forName: "Beck")?.notOnIPod, true)
        XCTAssertTrue(profiles.picturesMigrated)
    }

    func testSaveFailureKeepsOldFile() throws {
        // A folder where the profiles file should be: the store cannot save.
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(ArtistProfileStore.fileName),
                                                withIntermediateDirectories: true)
        let profiles = ArtistProfileStore(indexDirectory: folder)
        XCTAssertThrowsError(try migrate([(record("Air", .rejected), nil)], into: profiles))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bakFile.path))
        XCTAssertEqual(pictureStore().allRecords().map(\.displayName), ["Air"], "the old records are all still there")
    }

    /// Every crates folder on the Mac shares the old prepared-picture cache:
    /// migrating one deletes only the files it carried, so a second folder
    /// still holding `library.cdartists` migrates with its bytes, owner picks
    /// included.
    func testMigratingOneFolderLeavesTheSharedCacheToTheOthers() throws {
        let cache = folder.appendingPathComponent("SharedArtistImages", isDirectory: true)
        let first = folder.appendingPathComponent("LibraryA", isDirectory: true)
        let second = folder.appendingPathComponent("LibraryB", isDirectory: true)
        for directory in [first, second] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let air = try prepared(shade: 0.2), beck = try prepared(shade: 0.7)
        let one = ArtistPictureStore(indexDirectory: first, imageDirectory: cache)
        try one.set(record("Air", .found, source: .deezer, sourceID: "1"), prepared: air)
        try one.save()
        let two = ArtistPictureStore(indexDirectory: second, imageDirectory: cache)
        try two.set(record("Beck", .found, source: .userFile, sourceID: "beck.jpg", picked: true), prepared: beck)
        try two.save()
        func cached(_ data: Data) -> URL {
            cache.appendingPathComponent(ArtistProfileStore.sha256(data) + ".jpg")
        }

        let a = ArtistProfileStore(indexDirectory: first)
        XCTAssertTrue(try ArtistProfileMigration.migrate(pictures: one, into: a, indexDirectory: first,
                                                         legacyCache: cache))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cached(air).path), "carried, saved: gone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cached(beck).path), "the other folder's stays")

        let b = ArtistProfileStore(indexDirectory: second)
        XCTAssertTrue(try ArtistProfileMigration.migrate(pictures: ArtistPictureStore(indexDirectory: second,
                                                                                      imageDirectory: cache),
                                                         into: b, indexDirectory: second, legacyCache: cache))
        let profile = try XCTUnwrap(b.profile(forName: "Beck"))
        XCTAssertEqual(profile.defaultPhoto, ArtistProfileStore.sha256(beck))
        XCTAssertTrue(profile.defaultPickedByOwner)
        XCTAssertNotNil(b.photoData(hash: ArtistProfileStore.sha256(beck)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path), "empty once both are carried")
    }
}
