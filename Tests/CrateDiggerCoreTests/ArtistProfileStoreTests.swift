import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CrateDiggerCore

final class ArtistProfileStoreTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtistProfileStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var photosDirectory: URL { folder.appendingPathComponent(ArtistProfileStore.photosFolder, isDirectory: true) }
    private var storeFile: URL { folder.appendingPathComponent(ArtistProfileStore.fileName) }

    private func makeStore() -> ArtistProfileStore { ArtistProfileStore(indexDirectory: folder) }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A solid sRGB image encoded as `type`; `shade` makes each one's bytes differ.
    private func image(_ width: Int, _ height: Int, shade: CGFloat = 0.3, as type: UTType = .jpeg) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: shade, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: width, height: height)
    }

    // MARK: - Picking a found photo

    func testPickingAFoundPhotoAddsItAndDropsTheReference() throws {
        let store = makeStore()
        let mine = try store.addPhoto(name: "Air", data: image(500, 500), source: .owner, sourceID: nil, credit: nil)
        store.setDefault(name: "Air", hash: mine.hash)
        let credit = ArtistPictureCredit(fileName: "Air 2007.jpg", licence: "CC BY 2.0", author: "Someone")
        let commons = ArtistPictureRecord.HeldCandidate(source: .commons, sourceID: "mb-1",
                                                        imageURL: URL(string: "https://upload.wikimedia.org/a.jpg")!,
                                                        credit: credit)
        let deezer = ArtistPictureRecord.HeldCandidate(source: .deezer, sourceID: "77",
                                                       imageURL: URL(string: "https://e.dzcdn.net/b.jpg")!)
        store.update(name: "Air") { $0.photoCandidates = [commons, deezer] }

        let added = try store.addCandidatePhoto(name: "Air", candidate: commons, data: image(2_400, 1_800, shade: 0.6))

        let profile = try XCTUnwrap(store.profile(forName: "Air"))
        XCTAssertEqual(profile.photos.map(\.hash), [mine.hash, added.hash])
        XCTAssertEqual(added.source, .commons)
        XCTAssertEqual(added.sourceID, "mb-1")
        XCTAssertEqual(added.credit, credit)
        XCTAssertEqual(max(added.pixelWidth, added.pixelHeight), 1_600, "stored as a fetched photo")
        XCTAssertEqual(profile.photoCandidates, [deezer], "the reference is now a photo")
        XCTAssertEqual(profile.defaultPhoto, mine.hash, "the default is chosen separately")
        XCTAssertTrue(profile.defaultPickedByOwner)
    }

    func testAFoundPhotoFromASourceProfilesDoNotKeepIsRefused() {
        let store = makeStore()
        let fanart = ArtistPictureRecord.HeldCandidate(source: .fanartTV, sourceID: "1",
                                                       imageURL: URL(string: "https://example.com/c.jpg")!)
        XCTAssertThrowsError(try store.addCandidatePhoto(name: "Air", candidate: fanart, data: image(500, 500)))
        XCTAssertNil(store.profile(forName: "Air"))
    }

    // MARK: - Facts

    func testOwnerFieldsWinFieldByField() {
        var profile = ArtistProfile(foldedKey: "massiveattack", displayName: "Massive Attack")
        profile.fetched = ArtistFacts(kind: "Group", origin: "Bristol, England", begin: "1988",
                                      bio: "A trip hop group.",
                                      bioSourceURL: URL(string: "https://en.wikipedia.org/wiki/Massive_Attack"),
                                      members: [ArtistMember(name: "Robert Del Naja", begin: "1988", isCurrent: true)],
                                      genres: ["trip hop"])
        profile.owner = ArtistFacts(origin: "Bristol", genres: ["trip hop", "electronic"])
        let facts = profile.facts
        XCTAssertEqual(facts.kind, "Group")
        XCTAssertEqual(facts.origin, "Bristol")
        XCTAssertEqual(facts.begin, "1988")
        XCTAssertNil(facts.end)
        XCTAssertEqual(facts.bio, "A trip hop group.")
        XCTAssertEqual(facts.bioSourceURL, URL(string: "https://en.wikipedia.org/wiki/Massive_Attack"))
        XCTAssertEqual(facts.members?.map(\.name), ["Robert Del Naja"])
        XCTAssertEqual(facts.genres, ["trip hop", "electronic"])

        // A bio the owner wrote carries no Wikipedia credit, even when they paste a URL.
        profile.owner?.bio = "My own words."
        profile.owner?.bioSourceURL = URL(string: "https://example.com")
        XCTAssertEqual(profile.facts.bio, "My own words.")
        XCTAssertNil(profile.facts.bioSourceURL)

        XCTAssertEqual(ArtistProfile(foldedKey: "air", displayName: "Air").facts, ArtistFacts())
    }

    func testOwnerEmptyStringClearsField() {
        var profile = ArtistProfile(foldedKey: "air", displayName: "Air")
        profile.fetched = ArtistFacts(kind: "Group", origin: "Versailles, France", bio: "A French duo.",
                                      bioSourceURL: URL(string: "https://en.wikipedia.org/wiki/Air_(French_band)"),
                                      genres: ["electronic"])
        profile.owner = ArtistFacts(origin: "", bio: "", genres: [])
        let facts = profile.facts
        XCTAssertNil(facts.origin)
        XCTAssertNil(facts.bio)
        XCTAssertNil(facts.bioSourceURL, "a cleared bio leaves no credit behind")
        XCTAssertEqual(facts.genres, [])
        XCTAssertEqual(facts.kind, "Group")
    }

    func testFetchedUpdateNeverTouchesOwnerFields() throws {
        let store = makeStore()
        let photo = try store.addPhoto(name: "Portishead", data: image(800, 800), source: .owner, sourceID: nil,
                                       credit: nil)
        store.update(name: "Portishead") { profile in
            profile.owner = ArtistFacts(origin: "Bristol", bio: "Mine.")
            profile.defaultPickedByOwner = true
            profile.noPhoto = true
            profile.notOnIPod = true
            profile.rejectedPhotoSources = ["deezer:1"]
            profile.rejectedMusicBrainzIDs = ["mb-old"]
        }
        let before = try XCTUnwrap(store.profile(forName: "Portishead"))
        let when = Date(timeIntervalSinceReferenceDate: 810_000_000)
        let fetched = ArtistFacts(kind: "Group", origin: "Bristol, England", bio: "From Wikipedia.")
        store.applyFetched(name: "Portishead", facts: fetched,
                           identity: .confirmed(musicBrainzID: "mb-1", wikidataID: "Q1"), at: when)

        var expected = before
        expected.fetched = fetched
        expected.identity = .confirmed(musicBrainzID: "mb-1", wikidataID: "Q1")
        expected.checkedAt = when
        XCTAssertEqual(store.profile(forName: "Portishead"), expected)
        XCTAssertEqual(store.profile(forName: "Portishead")?.photos, [photo])
        XCTAssertEqual(store.profile(forName: "Portishead")?.facts.bio, "Mine.")
    }

    // MARK: - Photos

    func testAddPhotoStoresOncePerHash() throws {
        let store = makeStore()
        let bytes = image(600, 500)
        let first = try store.addPhoto(name: "Björk", data: bytes, source: .owner, sourceID: nil, credit: nil)
        XCTAssertEqual(first.hash, sha256(bytes), "an owner JPEG is kept exactly as given")
        XCTAssertEqual(first.source, .owner)
        XCTAssertEqual(first.pixelWidth, 600)
        XCTAssertEqual(first.pixelHeight, 500)
        XCTAssertEqual(store.photoURL(hash: first.hash),
                       photosDirectory.appendingPathComponent(first.hash + ".jpg"))
        XCTAssertEqual(store.photoData(hash: first.hash), bytes)

        let again = try store.addPhoto(name: "Bjork", data: bytes, source: .owner, sourceID: nil, credit: nil)
        XCTAssertEqual(again, first)
        XCTAssertEqual(store.profile(forName: "Björk")?.photos.count, 1)

        let png = image(400, 400, shade: 0.9, as: .png)
        let second = try store.addPhoto(name: "Björk", data: png, source: .owner, sourceID: nil, credit: nil)
        XCTAssertEqual(store.photoURL(hash: second.hash),
                       photosDirectory.appendingPathComponent(second.hash + ".png"))
        XCTAssertEqual(store.photoData(hash: second.hash), png)
        XCTAssertEqual(store.profile(forName: "Björk")?.photos.map(\.hash), [first.hash, second.hash],
                       "photos keep the order they were added in")
        let files = try FileManager.default.contentsOfDirectory(atPath: photosDirectory.path).sorted()
        XCTAssertEqual(files, [first.hash + ".jpg", second.hash + ".png"].sorted())

        XCTAssertThrowsError(try store.addPhoto(name: "Björk", data: Data("not an image".utf8), source: .owner,
                                                sourceID: nil, credit: nil))
    }

    func testFetchedPhotoIsCappedAt1600() throws {
        let store = makeStore()
        let credit = ArtistPictureCredit(fileName: "Air.jpg", licence: "CC BY 2.0", author: "Someone")
        let photo = try store.addPhoto(name: "Air", data: image(2400, 1200), source: .commons, sourceID: "mb-air",
                                       credit: credit)
        XCTAssertEqual(photo.pixelWidth, 1600)
        XCTAssertEqual(photo.pixelHeight, 800)
        XCTAssertEqual(photo.credit, credit)
        XCTAssertEqual(photo.sourceID, "mb-air")
        let stored = try XCTUnwrap(store.photoData(hash: photo.hash))
        XCTAssertEqual(pixelSize(of: stored), CGSize(width: 1600, height: 800))
        XCTAssertEqual(store.photoURL(hash: photo.hash).pathExtension, "jpg")

        // A small fetched picture is re-encoded, never enlarged.
        let small = try store.addPhoto(name: "Air", data: image(500, 400, shade: 0.8, as: .png), source: .deezer,
                                       sourceID: "7", credit: nil)
        XCTAssertEqual(small.pixelWidth, 500)
        XCTAssertEqual(small.pixelHeight, 400)
        XCTAssertEqual(store.photoURL(hash: small.hash).pathExtension, "jpg")
    }

    func testOwnerPhotoOverCapsIsRefused() throws {
        let store = makeStore()
        let tooBig = Data(count: ArtistPictureImage.maximumSourceBytes + 1)
        XCTAssertThrowsError(try store.addPhoto(name: "Air", data: tooBig, source: .owner, sourceID: nil,
                                                credit: nil)) { error in
            XCTAssertEqual(error as? ArtistProfileStoreError, .photoTooLarge)
        }
        // A header claiming more than 50 megapixels, without making such an image.
        XCTAssertThrowsError(try ArtistPhotoImage.stored(image(400, 400), source: .owner,
                                                         reportedSize: CGSize(width: 10_000, height: 5_001))) { error in
            XCTAssertEqual(error as? ArtistProfileStoreError, .photoTooLarge)
        }
        XCTAssertNoThrow(try ArtistPhotoImage.stored(image(400, 400), source: .owner,
                                                     reportedSize: CGSize(width: 10_000, height: 5_000)))
        XCTAssertNil(store.profile(forName: "Air"), "a refused photo makes no profile")
        XCTAssertFalse(FileManager.default.fileExists(atPath: photosDirectory.path))
    }

    func testFirstPhotoBecomesDefaultNotPicked() throws {
        let store = makeStore()
        let first = try store.addPhoto(name: "Low", data: image(400, 400, shade: 0.1), source: .deezer,
                                       sourceID: "1", credit: nil)
        _ = try store.addPhoto(name: "Low", data: image(400, 400, shade: 0.2), source: .deezer, sourceID: "2",
                               credit: nil)
        let profile = try XCTUnwrap(store.profile(forName: "Low"))
        XCTAssertEqual(profile.defaultPhoto, first.hash)
        XCTAssertFalse(profile.defaultPickedByOwner)
        XCTAssertEqual(profile.defaultPhotoRef, first)
        XCTAssertEqual(profile.displayName, "Low")
        XCTAssertEqual(profile.foldedKey, PodBoxArtName.folded("Low"))
    }

    func testSetDefaultMarksPickedByOwner() throws {
        let store = makeStore()
        _ = try store.addPhoto(name: "Low", data: image(400, 400, shade: 0.1), source: .deezer, sourceID: "1",
                               credit: nil)
        let second = try store.addPhoto(name: "Low", data: image(400, 400, shade: 0.2), source: .owner,
                                        sourceID: nil, credit: nil)
        store.update(name: "Low") { $0.noPhoto = true; $0.notOnIPod = true }
        store.setDefault(name: "Low", hash: second.hash)
        var profile = try XCTUnwrap(store.profile(forName: "Low"))
        XCTAssertEqual(profile.defaultPhoto, second.hash)
        XCTAssertTrue(profile.defaultPickedByOwner)
        XCTAssertTrue(profile.noPhoto, "the owner's flags survive a change of default")
        XCTAssertTrue(profile.notOnIPod)

        // A hash the profile does not hold changes nothing.
        store.setDefault(name: "Low", hash: String(repeating: "a", count: 64))
        profile = try XCTUnwrap(store.profile(forName: "Low"))
        XCTAssertEqual(profile.defaultPhoto, second.hash)
    }

    func testRemovingDefaultPicksNextAndClearsPicked() throws {
        let store = makeStore()
        let a = try store.addPhoto(name: "Low", data: image(400, 400, shade: 0.1), source: .owner, sourceID: nil,
                                   credit: nil)
        let b = try store.addPhoto(name: "Low", data: image(400, 400, shade: 0.2), source: .owner, sourceID: nil,
                                   credit: nil)
        let c = try store.addPhoto(name: "Low", data: image(400, 400, shade: 0.3), source: .owner, sourceID: nil,
                                   credit: nil)
        store.setDefault(name: "Low", hash: b.hash)
        store.removePhoto(name: "Low", hash: b.hash)
        var profile = try XCTUnwrap(store.profile(forName: "Low"))
        XCTAssertEqual(profile.photos.map(\.hash), [a.hash, c.hash])
        XCTAssertEqual(profile.defaultPhoto, c.hash, "the next photo takes over")
        XCTAssertFalse(profile.defaultPickedByOwner)

        store.setDefault(name: "Low", hash: c.hash)
        store.removePhoto(name: "Low", hash: c.hash)
        profile = try XCTUnwrap(store.profile(forName: "Low"))
        XCTAssertEqual(profile.defaultPhoto, a.hash, "with none after it, the one before")
        XCTAssertFalse(profile.defaultPickedByOwner)

        store.removePhoto(name: "Low", hash: a.hash)
        profile = try XCTUnwrap(store.profile(forName: "Low"))
        XCTAssertNil(profile.defaultPhoto)
        XCTAssertNil(profile.defaultPhotoRef)

        // Removing a photo that is not the default leaves an owner's pick alone.
        let d = try store.addPhoto(name: "Low", data: image(400, 400, shade: 0.4), source: .owner, sourceID: nil,
                                   credit: nil)
        let e = try store.addPhoto(name: "Low", data: image(400, 400, shade: 0.5), source: .owner, sourceID: nil,
                                   credit: nil)
        store.setDefault(name: "Low", hash: d.hash)
        store.removePhoto(name: "Low", hash: e.hash)
        profile = try XCTUnwrap(store.profile(forName: "Low"))
        XCTAssertEqual(profile.defaultPhoto, d.hash)
        XCTAssertTrue(profile.defaultPickedByOwner)
    }

    func testRemovedFetchedPhotoIsRemembered() throws {
        let store = makeStore()
        let fetched = try store.addPhoto(name: "Air", data: image(400, 400, shade: 0.1), source: .deezer,
                                         sourceID: "42", credit: nil)
        let commons = try store.addPhoto(name: "Air", data: image(400, 400, shade: 0.2), source: .commons,
                                         sourceID: "mb-air", credit: nil)
        let owner = try store.addPhoto(name: "Air", data: image(400, 400, shade: 0.3), source: .owner,
                                       sourceID: nil, credit: nil)
        XCTAssertEqual(fetched.rejectionKey, "deezer:42")
        XCTAssertNil(owner.rejectionKey)

        store.removePhoto(name: "Air", hash: fetched.hash)
        store.removePhoto(name: "Air", hash: commons.hash)
        store.removePhoto(name: "Air", hash: owner.hash)
        store.removePhoto(name: "Air", hash: fetched.hash) // twice: remembered once
        let profile = try XCTUnwrap(store.profile(forName: "Air"))
        XCTAssertEqual(profile.rejectedPhotoSources, ["deezer:42", "commons:mb-air"])
        XCTAssertEqual(profile.photos, [])
    }

    func testPhotoFileKeptWhileAnotherProfileUsesIt() throws {
        let store = makeStore()
        let bytes = image(400, 400)
        let shared = try store.addPhoto(name: "Air", data: bytes, source: .owner, sourceID: nil, credit: nil)
        _ = try store.addPhoto(name: "Beck", data: bytes, source: .owner, sourceID: nil, credit: nil)
        let file = store.photoURL(hash: shared.hash)

        store.removePhoto(name: "Air", hash: shared.hash)
        try store.save()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Beck still shows it")
        XCTAssertEqual(store.photoData(hash: shared.hash), bytes)

        store.removePhoto(name: "Beck", hash: shared.hash)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "gone only once the index says so")
        try store.save()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testNoPhotoHidesDefaultRef() throws {
        let store = makeStore()
        let photo = try store.addPhoto(name: "Air", data: image(400, 400), source: .owner, sourceID: nil,
                                       credit: nil)
        store.update(name: "Air") { $0.noPhoto = true }
        let profile = try XCTUnwrap(store.profile(forName: "Air"))
        XCTAssertNil(profile.defaultPhotoRef)
        XCTAssertEqual(profile.defaultPhoto, photo.hash, "the choice is kept for when the owner turns it back on")

        store.update(name: "Air") { $0.noPhoto = false }
        XCTAssertEqual(store.profile(forName: "Air")?.defaultPhotoRef, photo)
    }

    // MARK: - The file

    func testRoundTripAndLenientDecode() throws {
        let store = makeStore()
        let photo = try store.addPhoto(name: "Air", data: image(400, 400), source: .commons, sourceID: "mb-air",
                                       credit: ArtistPictureCredit(fileName: "Air.jpg", licence: "CC BY 2.0"))
        store.update(name: "Air") { profile in
            profile.identity = .uncertain([ArtistIdentityCandidate(musicBrainzID: "mb-1", name: "Air",
                                                                   disambiguation: "French duo",
                                                                   origin: "France", releaseTitles: ["Moon Safari"])])
            profile.owner = ArtistFacts(links: [ArtistLink(kind: .other, url: URL(string: "https://air.fr")!)])
            profile.photoCandidates = [ArtistPictureRecord.HeldCandidate(
                source: .deezer, sourceID: "7", imageURL: URL(string: "https://e-cdns-images.dzcdn.net/x.jpg")!)]
            profile.photos[0].replaceFromURL = URL(string: "https://commons.wikimedia.org/wiki/Special:FilePath/Air.jpg")
        }
        store.applyFetched(name: "Beck", facts: ArtistFacts(kind: "Person", begin: "1970"),
                           identity: .confirmed(musicBrainzID: "mb-beck", wikidataID: nil),
                           at: Date(timeIntervalSinceReferenceDate: 800_000_000))
        store.applyFetched(name: "Boston", facts: nil, identity: .notFound, at: Date(timeIntervalSinceReferenceDate: 0))
        store.update(name: "Low") { $0.identity = .rejected }
        try store.save()

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.allProfiles(), store.allProfiles())
        XCTAssertEqual(reloaded.allProfiles().map(\.foldedKey), ["air", "beck", "boston", "low"])
        XCTAssertEqual(reloaded.profile(forName: "Air")?.photos, store.profile(forName: "Air")?.photos)
        XCTAssertEqual(reloaded.photoData(hash: photo.hash), store.photoData(hash: photo.hash))
        let text = try String(contentsOf: storeFile, encoding: .utf8)
        XCTAssertFalse(text.contains("/9j/"), "no image bytes in the index file")

        // A newer or hand-edited file: unknown fields, an unknown identity
        // state, an unknown photo source, a broken record and a bad hash.
        let hash = String(repeating: "b", count: 64)
        let json = """
        [
          {"foldedKey":"air","displayName":"Air","identity":{"state":"somethingNew"},"futureField":1,
           "photos":[{"hash":"\(hash)","source":"hologram","pixelWidth":1,"pixelHeight":1,"added":"2026-01-01T00:00:00Z"},
                     {"hash":"\(hash)","source":"owner","pixelWidth":10,"pixelHeight":20,"added":"2026-01-01T00:00:00Z"}],
           "owner":{"origin":"Paris","members":[{"name":"Nicolas Godin","isCurrent":true},{"oops":true}]},
           "noPhoto":"yes"},
          {"displayName":42},
          {"foldedKey":"beck","displayName":"Beck","identity":{"state":"confirmed","musicBrainzID":"mb-beck"},
           "checkedAt":"2026-02-01T00:00:00Z"},
          {"foldedKey":"wrong","displayName":"The Low"},
          {"foldedKey":"","displayName":"!!!"}
        ]
        """
        try Data(json.utf8).write(to: storeFile)
        let lenient = makeStore()
        XCTAssertEqual(lenient.allProfiles().map(\.foldedKey), ["air", "beck", "low"])
        let air = try XCTUnwrap(lenient.profile(forName: "Air"))
        XCTAssertEqual(air.identity, .unknown)
        XCTAssertEqual(air.photos.map(\.pixelHeight), [20])
        XCTAssertEqual(air.owner?.origin, "Paris")
        XCTAssertEqual(air.owner?.members?.map(\.name), ["Nicolas Godin"])
        XCTAssertFalse(air.noPhoto)
        XCTAssertEqual(lenient.profile(forName: "Beck")?.identity,
                       .confirmed(musicBrainzID: "mb-beck", wikidataID: nil))
        XCTAssertEqual(lenient.profile(forName: "Beck")?.checkedAt, ISO8601DateFormatter().date(from: "2026-02-01T00:00:00Z"))
        XCTAssertEqual(lenient.profile(forName: "Low")?.displayName, "The Low")
    }

    func testUnreadableFileBlocksSave() throws {
        try Data("not json".utf8).write(to: storeFile)
        let store = makeStore()
        XCTAssertEqual(store.allProfiles(), [])
        store.update(name: "Air") { $0.notOnIPod = true }
        XCTAssertThrowsError(try store.save()) { error in
            XCTAssertEqual(error as? ArtistProfileStoreError, .unreadableStore(path: storeFile.path))
        }
        XCTAssertEqual(try Data(contentsOf: storeFile), Data("not json".utf8))

        // A folder where the file should be: not "missing", so not "empty".
        try FileManager.default.removeItem(at: storeFile)
        try FileManager.default.createDirectory(at: storeFile, withIntermediateDirectories: true)
        let blocked = makeStore()
        blocked.update(name: "Air") { $0.notOnIPod = true }
        XCTAssertThrowsError(try blocked.save())

        // No file in a folder that is there is an empty store that saves.
        let freshFolder = folder.appendingPathComponent("Fresh", isDirectory: true)
        try FileManager.default.createDirectory(at: freshFolder, withIntermediateDirectories: true)
        let fresh = ArtistProfileStore(indexDirectory: freshFolder)
        XCTAssertEqual(fresh.allProfiles(), [])
        fresh.update(name: "Air") { $0.notOnIPod = true }
        XCTAssertNoThrow(try fresh.save())
    }

    /// Review I3: a store made while the library drive is away must never
    /// save a near-empty file over the real one once the drive is back.
    func testMissingIndexFolderBlocksSave() throws {
        let away = folder.appendingPathComponent("Unplugged/Crates", isDirectory: true)
        let store = ArtistProfileStore(indexDirectory: away)
        XCTAssertEqual(store.allProfiles(), [])
        store.update(name: "Air") { $0.notOnIPod = true }
        XCTAssertThrowsError(try store.save()) { error in
            XCTAssertEqual(error as? ArtistProfileStoreError, .unreachableIndexFolder(path: away.path))
        }
        XCTAssertThrowsError(try store.addPhoto(name: "Air", data: image(400, 400), source: .owner, sourceID: nil,
                                                credit: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: away.path), "nothing made in its place")

        // The drive comes back with the real file: this store still refuses.
        try FileManager.default.createDirectory(at: away, withIntermediateDirectories: true)
        let real = Data(#"{"picturesMigrated":true,"profiles":[{"displayName":"Beck","foldedKey":"beck"}]}"#.utf8)
        try real.write(to: away.appendingPathComponent(ArtistProfileStore.fileName))
        XCTAssertThrowsError(try store.save())
        XCTAssertEqual(try Data(contentsOf: away.appendingPathComponent(ArtistProfileStore.fileName)), real)
        XCTAssertEqual(ArtistProfileStore(indexDirectory: away).allProfiles().map(\.foldedKey), ["beck"])
    }

    // MARK: - The owner's word on identity

    /// Review I2: a lookup already running cannot undo "None of these" or
    /// "Not This Artist".
    func testLookupCannotUndoTheOwnersIdentityChoice() throws {
        let store = makeStore()
        let when = Date(timeIntervalSinceReferenceDate: 800_000_000)
        store.update(name: "Boston") { $0.identity = .rejected }
        XCTAssertFalse(store.applyFetched(name: "Boston", facts: ArtistFacts(kind: "Group"),
                                          identity: .confirmed(musicBrainzID: "mb-1", wikidataID: nil), at: when))
        XCTAssertEqual(store.profile(forName: "Boston"), ArtistProfile(foldedKey: "boston", displayName: "Boston",
                                                                      identity: .rejected))

        store.update(name: "Air") { $0.rejectedMusicBrainzIDs = ["mb-wrong"] }
        XCTAssertFalse(store.applyFetched(name: "Air", facts: ArtistFacts(origin: "Somewhere else"),
                                          identity: .confirmed(musicBrainzID: "mb-wrong", wikidataID: nil), at: when))
        XCTAssertNil(store.profile(forName: "Air")?.fetched)
        XCTAssertEqual(store.profile(forName: "Air")?.identity, .unknown)

        let wrong = ArtistIdentityCandidate(musicBrainzID: "mb-wrong", name: "Air")
        let right = ArtistIdentityCandidate(musicBrainzID: "mb-right", name: "Air", disambiguation: "French duo")
        XCTAssertTrue(store.applyFetched(name: "Air", facts: nil, identity: .uncertain([wrong, right]), at: when))
        XCTAssertEqual(store.profile(forName: "Air")?.identity, .uncertain([right]))
        XCTAssertTrue(store.applyFetched(name: "Air", facts: nil, identity: .uncertain([wrong]), at: when))
        XCTAssertEqual(store.profile(forName: "Air")?.identity, .notFound, "no candidate left to ask about")

        // Look Up Again clears "None of these" first; the rejected ids stay rejected.
        store.update(name: "Air") { $0.identity = .rejected }
        store.resetIdentity(name: "Air")
        XCTAssertEqual(store.profile(forName: "Air")?.identity, .unknown)
        XCTAssertEqual(store.profile(forName: "Air")?.rejectedMusicBrainzIDs, ["mb-wrong"])
        XCTAssertTrue(store.applyFetched(name: "Air", facts: ArtistFacts(kind: "Group"),
                                         identity: .confirmed(musicBrainzID: "mb-right", wikidataID: "Q1"), at: when))
        XCTAssertEqual(store.profile(forName: "Air")?.identity, .confirmed(musicBrainzID: "mb-right", wikidataID: "Q1"))
        store.resetIdentity(name: "Nobody")
        XCTAssertNil(store.profile(forName: "Nobody"), "resetting makes no profile")
    }

    // MARK: - Hand-edited and damaged files

    func testRecordsForOneArtistAreMerged() throws {
        let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)
        func photo(_ hash: String) -> String {
            #"{"hash":"\#(hash)","source":"owner","pixelWidth":400,"pixelHeight":400,"added":"2026-01-01T00:00:00Z"}"#
        }
        let json = """
        [
          {"foldedKey":"beatles","displayName":"The Beatles","photos":[\(photo(a))],"defaultPhoto":"\(a)",
           "owner":{"origin":"Liverpool"},"identity":{"state":"confirmed","musicBrainzID":"mb-old"},
           "checkedAt":"2026-01-01T00:00:00Z","rejectedPhotoSources":["deezer:1"]},
          {"foldedKey":"beatles","displayName":"Beatles, The","photos":[\(photo(a)),\(photo(b))],"defaultPhoto":"\(b)",
           "defaultPickedByOwner":true,"notOnIPod":true,"owner":{"origin":"Elsewhere","bio":"Mine."},
           "identity":{"state":"confirmed","musicBrainzID":"mb-new"},"checkedAt":"2026-06-01T00:00:00Z",
           "rejectedPhotoSources":["deezer:2"]}
        ]
        """
        try Data(json.utf8).write(to: storeFile)
        let store = makeStore()
        let beatles = try XCTUnwrap(store.profile(forName: "The Beatles"))
        XCTAssertEqual(store.allProfiles().count, 1)
        XCTAssertEqual(beatles.displayName, "The Beatles")
        XCTAssertEqual(beatles.photos.map(\.hash), [a, b])
        XCTAssertEqual(beatles.defaultPhoto, b, "the owner's pick wins")
        XCTAssertTrue(beatles.defaultPickedByOwner)
        XCTAssertTrue(beatles.notOnIPod)
        XCTAssertEqual(beatles.owner?.origin, "Liverpool")
        XCTAssertEqual(beatles.owner?.bio, "Mine.")
        XCTAssertEqual(beatles.rejectedPhotoSources, ["deezer:1", "deezer:2"])
        XCTAssertEqual(beatles.identity, .confirmed(musicBrainzID: "mb-new", wikidataID: nil), "the newer lookup")
    }

    func testLossyLoadKeepsOneBackupOfTheFileAsRead() throws {
        let backup = folder.appendingPathComponent(ArtistProfileStore.backupFileName)
        let clean = makeStore()
        clean.update(name: "Air") { $0.notOnIPod = true }
        try clean.save()
        let second = makeStore()
        second.update(name: "Air") { $0.noPhoto = true }
        try second.save()
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path), "a whole load needs no backup")

        let damaged = Data(#"[{"displayName":"Air","photos":[{"hash":"x"}]},{"displayName":7}]"#.utf8)
        try damaged.write(to: storeFile)
        let store = makeStore()
        XCTAssertEqual(store.allProfiles().map(\.foldedKey), ["air"])
        try store.save()
        XCTAssertEqual(try Data(contentsOf: backup), damaged)
        XCTAssertNotEqual(try Data(contentsOf: storeFile), damaged, "the repaired file is written back")

        // A later damaged load gets its own numbered backup; none is written over.
        let later = Data(#"[{"displayName":"Beck","identity":{"state":"future"}}]"#.utf8)
        try later.write(to: storeFile)
        let again = makeStore()
        again.update(name: "Beck") { $0.notOnIPod = true }
        try again.save()
        XCTAssertEqual(try Data(contentsOf: backup), damaged)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(ArtistProfileStore.fileName + ".2.bak")),
                       later)
        let third = Data(#"[{"displayName":5}]"#.utf8)
        try third.write(to: storeFile)
        try makeStore().save()
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(ArtistProfileStore.fileName + ".3.bak")),
                       third)
    }

    /// Re-review: a second lossy load (after the owner restored or edited
    /// the file) must not lose the photos of the record it drops. A store
    /// that could not read everything deletes no photo files at all, and
    /// every backup's photos stay restorable.
    func testLossyLoadNeverDeletesPhotos() throws {
        let store = makeStore()
        let air = try store.addPhoto(name: "Air", data: image(400, 400, shade: 0.1), source: .owner, sourceID: nil,
                                     credit: nil)
        let beck = try store.addPhoto(name: "Beck", data: image(400, 400, shade: 0.2), source: .owner, sourceID: nil,
                                      credit: nil)
        try store.save()
        let whole = try String(contentsOf: storeFile, encoding: .utf8)
        let stray = photosDirectory.appendingPathComponent(String(repeating: "c", count: 64) + ".jpg")
        try Data("x".utf8).write(to: stray)
        func damaging(_ name: String, in text: String) throws -> Data {
            let damaged = text.replacingOccurrences(of: "\"displayName\":\"\(name)\"", with: "\"displayName\":7")
            XCTAssertNotEqual(damaged, text)
            return Data(damaged.utf8)
        }
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

        // First lossy load: Beck's record is dropped.
        try damaging("Beck", in: whole).write(to: storeFile)
        let first = makeStore()
        XCTAssertNil(first.profile(forName: "Beck"))
        try first.save()
        XCTAssertTrue(exists(store.photoURL(hash: beck.hash)))
        XCTAssertTrue(exists(stray), "a lossy store sweeps nothing, not even a plain orphan")

        // The owner restores the whole file, then an edit breaks Air instead.
        try damaging("Air", in: whole).write(to: storeFile)
        let second = makeStore()
        XCTAssertNil(second.profile(forName: "Air"))
        second.removePhoto(name: "Beck", hash: beck.hash)
        try second.save()
        XCTAssertTrue(exists(store.photoURL(hash: air.hash)))
        XCTAssertTrue(exists(store.photoURL(hash: beck.hash)), "a removed photo waits for a clean store")
        XCTAssertTrue(exists(folder.appendingPathComponent(ArtistProfileStore.fileName + ".2.bak")))

        // A clean load sweeps again, but keeps whatever any backup names.
        let clean = makeStore()
        XCTAssertEqual(clean.allProfiles().map(\.foldedKey), ["beck"])
        try clean.save()
        XCTAssertFalse(exists(stray))
        XCTAssertTrue(exists(store.photoURL(hash: air.hash)), "named by the second backup")
        XCTAssertTrue(exists(store.photoURL(hash: beck.hash)), "named by the first backup")
    }

    func testSaveSweepsPhotoFilesNoProfileNames() throws {
        let store = makeStore()
        let kept = try store.addPhoto(name: "Air", data: image(400, 400, shade: 0.1), source: .owner, sourceID: nil,
                                      credit: nil)
        let edited = try store.addPhoto(name: "Air", data: image(400, 400, shade: 0.2), source: .owner,
                                        sourceID: nil, credit: nil)
        let stray = photosDirectory.appendingPathComponent(String(repeating: "c", count: 64) + ".jpg")
        let named = String(repeating: "d", count: 64)
        let namedByBackup = photosDirectory.appendingPathComponent(named + ".png")
        let ownersFile = photosDirectory.appendingPathComponent("notes.txt")
        for file in [stray, namedByBackup, ownersFile] { try Data("x".utf8).write(to: file) }
        try Data(#"[{"defaultPhoto":"\#(named)"}]"#.utf8)
            .write(to: folder.appendingPathComponent(ArtistProfileStore.backupFileName))

        // An edit that drops a photo without removePhoto: its file still goes.
        store.update(name: "Air") { $0.photos.removeAll { $0.hash == edited.hash } }
        try store.save()
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: photosDirectory.path))
        XCTAssertEqual(names, [kept.hash + ".jpg", named + ".png", "notes.txt"])
    }

    func testMigratedFlagIsSavedInTheFile() throws {
        let store = makeStore()
        XCTAssertFalse(store.picturesMigrated)
        store.markPicturesMigrated()
        try store.save()
        XCTAssertTrue(makeStore().picturesMigrated)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: storeFile)) as? [String: Any]
        XCTAssertEqual(object?["picturesMigrated"] as? Bool, true)
        XCTAssertNotNil(object?["profiles"] as? [Any])
    }

    func testEmptyKeyIsIgnored() {
        let store = makeStore()
        var called = false
        store.update(name: "!!!") { _ in called = true }
        store.update(name: "") { _ in called = true }
        store.applyFetched(name: "  ", facts: ArtistFacts(kind: "Group"), identity: .notFound, at: Date())
        XCTAssertFalse(called)
        XCTAssertEqual(store.allProfiles(), [])
        XCTAssertNil(store.profile(forName: "!!!"))
        XCTAssertThrowsError(try store.addPhoto(name: "!!!", data: image(400, 400), source: .owner, sourceID: nil,
                                                credit: nil)) { error in
            XCTAssertEqual(error as? ArtistProfileStoreError, .unnamedArtist(name: "!!!"))
        }
        // The closure cannot move a profile to another key.
        store.update(name: "Air") { $0.foldedKey = "beck" }
        XCTAssertEqual(store.allProfiles().map(\.foldedKey), ["air"])
    }

    func testMissingPhotoFileReadsAsUnavailable() throws {
        let store = makeStore()
        let photo = try store.addPhoto(name: "Air", data: image(400, 400), source: .owner, sourceID: nil,
                                       credit: nil)
        try store.save()
        try FileManager.default.removeItem(at: store.photoURL(hash: photo.hash))

        let reloaded = makeStore()
        XCTAssertNil(reloaded.photoData(hash: photo.hash))
        let profile = try XCTUnwrap(reloaded.profile(forName: "Air"))
        XCTAssertEqual(profile.photos, [photo])
        XCTAssertEqual(profile.defaultPhotoRef, photo)

        XCTAssertNil(reloaded.photoData(hash: "../../etc/passwd"), "only a hex hash names a file")
        // Bytes that no longer match their name read as unavailable too.
        try Data("tampered".utf8).write(to: reloaded.photoURL(hash: photo.hash))
        XCTAssertNil(reloaded.photoData(hash: photo.hash))
    }

    func testIndexFilesIncludeArtistInfo() {
        XCTAssertEqual(ArtistProfileStore.fileName, "library.cdartistinfo")
        XCTAssertEqual(ArtistProfileStore.photosFolder, "ArtistPhotos")
        XCTAssertTrue(LibraryIndexFiles.extensions.contains("cdartistinfo"))
        XCTAssertTrue(LibraryIndexFiles.isIndexFile(URL(fileURLWithPath: "/x/library.cdartistinfo")))
        XCTAssertFalse(LibraryIndexFiles.isIndexFile(URL(fileURLWithPath: "/x/ArtistPhotos")))
    }
}
