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

        // A backup from an earlier migration is never written over.
        try FileManager.default.copyItem(at: bakFile, to: oldFile)
        let earlier = try Data(contentsOf: bakFile)
        XCTAssertTrue(try ArtistProfileMigration.migrate(pictures: pictureStore(), into: reloaded,
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
}
