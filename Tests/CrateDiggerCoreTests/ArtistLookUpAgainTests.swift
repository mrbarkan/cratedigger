import XCTest
@testable import CrateDiggerCore

/// Look Up Again as the page runs it: a lookup that fails after the reset
/// leaves the artist, and the file, as the owner had them.
final class ArtistLookUpAgainTests: XCTestCase {
    private var folder: URL!
    private let date = Date(timeIntervalSinceReferenceDate: 700_000_000)
    private struct Offline: Error {}

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtistLookUpAgainTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private let candidates = [
        ArtistIdentityCandidate(musicBrainzID: "mb-1", name: "Air", disambiguation: "French duo"),
        ArtistIdentityCandidate(musicBrainzID: "mb-2", name: "Air", disambiguation: "Japanese band"),
    ]

    private func seeded(_ identity: ArtistProfile.Identity) throws -> ArtistProfileStore {
        let store = ArtistProfileStore(indexDirectory: folder)
        store.update(name: "Air") { $0.identity = identity }
        try store.save()
        return store
    }

    func testAFailedLookUpAgainKeepsTheCandidates() async throws {
        let store = try seeded(.uncertain(candidates))
        var seen: ArtistProfile.Identity?
        do {
            try await store.lookUpAgain(name: "Air", resetFirst: true, at: date) { profile in
                seen = profile?.identity
                throw Offline()
            }
            XCTFail("the failure reaches the caller")
        } catch is Offline {}
        XCTAssertEqual(seen, .unknown, "the lookup ran after the reset")
        XCTAssertEqual(store.profile(forName: "Air")?.identity, .uncertain(candidates))
        XCTAssertEqual(ArtistProfileStore(indexDirectory: folder).profile(forName: "Air")?.identity,
                       .uncertain(candidates), "the file still holds the candidates")
    }

    func testAFailedLookUpAgainKeepsNoneOfThese() async throws {
        let store = try seeded(.rejected)
        try? await store.lookUpAgain(name: "Air", resetFirst: true, at: date) { _ in throw Offline() }
        XCTAssertEqual(ArtistProfileStore(indexDirectory: folder).profile(forName: "Air")?.identity, .rejected)
    }

    func testTheRestoreNeverUndoesAnIdentitySetMeanwhile() async throws {
        let store = try seeded(.uncertain(candidates))
        try? await store.lookUpAgain(name: "Air", resetFirst: true, at: date) { _ in
            // The owner picks a candidate while the lookup is out.
            store.update(name: "Air") { $0.confirmIdentity(musicBrainzID: "mb-1") }
            throw Offline()
        }
        XCTAssertEqual(store.profile(forName: "Air")?.identity, .confirmed(musicBrainzID: "mb-1", wikidataID: nil))
    }

    func testASuccessfulLookUpAgainLandsAndSaves() async throws {
        let store = try seeded(.rejected)
        try await store.lookUpAgain(name: "Air", resetFirst: true, at: date) { _ in
            ArtistLookupResult(identity: .confirmed(musicBrainzID: "mb-1", wikidataID: nil),
                               facts: ArtistFacts(kind: "Group"), basedOn: .unknown)
        }
        let reread = ArtistProfileStore(indexDirectory: folder).profile(forName: "Air")
        XCTAssertEqual(reread?.identity, .confirmed(musicBrainzID: "mb-1", wikidataID: nil))
        XCTAssertEqual(reread?.fetched?.kind, "Group")
    }
}
