import AssistantKit
@testable import CrateDiggerCore
import XCTest

@MainActor
final class LibraryAssistantTests: XCTestCase {

    // MARK: - Fixture

    /// A library in memory that the assistant reads and writes as it would
    /// the real one.
    final class FakeHost: LibraryAssistantHost {
        var tracksByPath: [String: LoadedTrack] = [:]
        var crateOrder: [String] = []
        var crates: [String: [String]] = [:]
        var prep: [LoadedTrack] = []
        var stats: [String: ListeningStats] = [:]
        var playlists: [Playlist] = []
        var streams: [StreamSource] = []
        var refusal: String?
        var folder = "/Library/Crates"
        var trashedCrates: [String] = []
        var trashedPlaylists: [String] = []
        var presented: AssistantTagProposal?
        var reviewRefusal: String?
        var restoredTags: [UUID: AssistantTagWrite] = [:]
        var journalChanges = 0
        var writeCalls = 0

        func add(_ track: LoadedTrack, to crate: String) {
            let path = TrackStore.key(for: track.track.fileURL)
            tracksByPath[path] = track
            if crates[crate] == nil { crateOrder.append(crate); crates[crate] = [] }
            crates[crate]!.append(path)
        }

        func assistantLibraryInput() -> AssistantLibraryInput {
            AssistantLibraryInput(
                crates: crateOrder.map { name in (name, crates[name]!.compactMap { tracksByPath[$0] }) },
                prepCrate: prep, stats: stats, playlists: playlists, streams: streams)
        }
        func assistantWriteRefusal() -> String? { refusal }
        func assistantLibraryFolder() -> String { folder }
        func assistantWriteCrates(_ memberships: [(name: String, paths: [String])]) throws {
            writeCalls += 1
            for (name, paths) in memberships {
                if crates[name] == nil { crateOrder.append(name) }
                crates[name] = paths
            }
        }
        func assistantTrashCrates(_ names: [String]) throws {
            trashedCrates += names
            for name in names { crates[name] = nil; crateOrder.removeAll { $0 == name } }
        }
        func assistantWritePlaylist(name: String, paths: [String]) throws {
            playlists.removeAll { $0.name == name }
            playlists.append(Playlist(name: name, trackURLs: paths.map { URL(fileURLWithPath: $0) }))
        }
        func assistantTrashPlaylist(name: String) throws {
            trashedPlaylists.append(name)
            playlists.removeAll { $0.name == name }
        }
        func assistantAddStreams(_ new: [StreamSource]) { streams += new }
        func assistantRemoveStreams(ids: [String]) { streams.removeAll { ids.contains($0.id) } }
        func assistantPresentTagReview(_ proposal: AssistantTagProposal) -> String? {
            if let reviewRefusal { return reviewRefusal }
            presented = proposal
            return nil
        }
        func assistantRestoreTags(_ writes: [UUID: AssistantTagWrite]) throws {
            restoredTags.merge(writes) { _, new in new }
            for (id, write) in writes {
                guard let (path, track) = tracksByPath.first(where: { $0.value.track.id == id }) else { continue }
                tracksByPath[path] = LoadedTrack(track: track.track,
                                                 metadata: write.values.applied(to: track.metadata, fields: write.fields))
            }
        }
        func assistantJournalDidChange() { journalChanges += 1 }

        /// Sets one track's tags, as an edit in CrateDigger would.
        func retag(_ id: UUID, _ change: (inout AssistantTagValues) -> Void) {
            guard let (path, track) = tracksByPath.first(where: { $0.value.track.id == id }) else { return }
            let before = AssistantTagValues(track)
            var tags = before
            change(&tags)
            tracksByPath[path] = LoadedTrack(track: track.track,
                                             metadata: tags.applied(to: track.metadata, fields: tags.changedFields(from: before)))
        }
    }

    private var host: FakeHost!
    private var assistant: LibraryAssistant!
    private var journalURL: URL!
    private let now = ISO8601DateFormatter().date(from: "2026-10-17T12:00:00Z")!

    private var miles1: LoadedTrack!, miles2: LoadedTrack!, bjork: LoadedTrack!, aphex: LoadedTrack!, loose: LoadedTrack!

    override func setUp() async throws {
        journalURL = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString).json")
        host = FakeHost()
        miles1 = Self.track("/Music/Miles Davis/Kind of Blue/01 So What.flac", title: "So What", artist: "Miles Davis",
                            album: "Kind of Blue", year: 1959, genre: "Jazz", number: 1)
        miles2 = Self.track("/Music/Miles Davis/Kind of Blue/02 Freddie Freeloader.flac", title: "Freddie Freeloader",
                            artist: "Miles Davis", album: "Kind of Blue", year: 1959, genre: "Jazz", number: 2)
        bjork = Self.track("/Music/Björk/Homogenic/01 Hunter.m4a", title: "Hunter", artist: "Björk",
                           album: "Homogenic", year: 1997, genre: "Electronic; Art Pop; Trip Hop", number: 1)
        aphex = Self.track("/Music/Aphex Twin/SAW 85-92/01 Xtal.mp3", title: "Xtal", artist: "Aphex Twin",
                           album: "Selected Ambient Works 85-92", year: 1992, genre: nil, number: 1)
        loose = Self.track("/Downloads/new/untitled.wav", title: "untitled", artist: "", album: "", year: nil, genre: nil, number: nil)
        for track in [miles1!, miles2!, bjork!, aphex!] { host.add(track, to: "Everything") }
        host.add(miles1, to: "Jazz Night")
        host.prep = [loose]
        host.stats[TrackStore.key(for: miles1.track.fileURL)] = ListeningStats(
            playCount: 12, lastPlayed: now, dateAdded: now, rating: 5, playsByMonth: ["2026-10": 3, "2026-01": 4, "2025-12": 5])
        host.stats[TrackStore.key(for: bjork.track.fileURL)] = ListeningStats(
            playCount: 20, dateAdded: now, playsByMonth: ["2025-06": 20])
        assistant = LibraryAssistant(host: host, journal: AssistantJournal(fileURL: journalURL),
                                     now: { [now] in now }, calendar: Calendar(identifier: .gregorian))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: journalURL)
    }

    static func track(_ path: String, title: String, artist: String, album: String, year: Int?, genre: String?, number: Int?) -> LoadedTrack {
        let url = URL(fileURLWithPath: path)
        return LoadedTrack(
            track: AudioTrack(fileURL: url, title: title, artist: artist, album: album, durationSeconds: 301,
                              formatName: url.pathExtension.uppercased(), year: year, trackNumber: number),
            metadata: ConversionMetadata(title: title, artist: artist.isEmpty ? nil : artist,
                                         album: album.isEmpty ? nil : album, trackNumber: number,
                                         year: year, genre: genre, comment: "keep me"))
    }

    private func run(_ tool: AssistantTool, _ arguments: [String: JSONValue] = [:]) async -> MCPToolResult {
        await assistant.call(AssistantCall(tool: tool.rawValue, arguments: arguments))
    }

    private func json(_ result: MCPToolResult, file: StaticString = #filePath, line: UInt = #line) throws -> JSONValue {
        XCTAssertFalse(result.isError, result.text, file: file, line: line)
        return try JSONDecoder().decode(JSONValue.self, from: Data(result.text.utf8))
    }

    private func id(_ track: LoadedTrack) -> JSONValue { .string(track.track.id.uuidString) }

    // MARK: - Reads

    func testOverviewCountsTheLibraryAndItsCrates() async throws {
        let overview = try json(await run(.libraryOverview))
        XCTAssertEqual(overview["tracks"]?.intValue, 4)          // the Prep Crate's loose file isn't in the library
        XCTAssertEqual(overview["albums"]?.intValue, 3)
        XCTAssertEqual(overview["prep_crate_tracks"]?.intValue, 1)
        XCTAssertEqual(overview["crates"]?.arrayValue?.compactMap { $0["name"]?.stringValue }, ["Everything", "Jazz Night"])
        XCTAssertEqual(overview["top_genres"]?.arrayValue?.first?["genre"], "Jazz")
        XCTAssertEqual(overview["tracks_without_genre"]?.intValue, 1)
        XCTAssertEqual(overview["years"]?["from"]?.intValue, 1959)
        XCTAssertNil(overview["read_only"])
    }

    func testOverviewSaysWhenTheLibraryIsReadOnly() async throws {
        host.refusal = "The library drive is disconnected."
        let overview = try json(await run(.libraryOverview))
        XCTAssertEqual(overview["read_only"], "The library drive is disconnected.")
    }

    func testNoResultEverCarriesAFilePath() async throws {
        for tool in [AssistantTool.libraryOverview, .searchTracks, .listAlbums, .listeningHistory] {
            let result = await run(tool, ["crate": tool == .searchTracks ? "Prep Crate" : .null])
            XCTAssertFalse(result.text.contains("/Music/"), "\(tool): \(result.text)")
            XCTAssertFalse(result.text.contains("/Downloads/"), "\(tool): \(result.text)")
        }
    }

    func testSearchFoldsCaseAndAccentsAndNeedsEveryWord() async throws {
        let found = try json(await run(.searchTracks, ["query": "BJORK hunter"]))
        XCTAssertEqual(found["total"]?.intValue, 1)
        XCTAssertEqual(found["tracks"]?.arrayValue?.first?["id"], id(bjork))
        XCTAssertEqual(found["tracks"]?.arrayValue?.first?["crates"], ["Everything"])
        let none = try json(await run(.searchTracks, ["query": "bjork xtal"]))
        XCTAssertEqual(none["total"]?.intValue, 0)
    }

    func testSearchFiltersCombine() async throws {
        let jazz = try json(await run(.searchTracks, ["genre": "jazz", "crate": "jazz night"]))
        XCTAssertEqual(jazz["tracks"]?.arrayValue?.compactMap { $0["id"] }, [id(miles1)])
        let untagged = try json(await run(.searchTracks, ["missing_tag": "genre"]))
        XCTAssertEqual(untagged["tracks"]?.arrayValue?.compactMap { $0["id"] }, [id(aphex)])
        let nineties = try json(await run(.searchTracks, ["year_from": 1990, "year_to": 1999, "sort": "year"]))
        XCTAssertEqual(nineties["tracks"]?.arrayValue?.compactMap { $0["id"] }, [id(aphex), id(bjork)])
        let played = try json(await run(.searchTracks, ["min_plays": 15]))
        XCTAssertEqual(played["tracks"]?.arrayValue?.compactMap { $0["id"] }, [id(bjork)])
    }

    func testSearchPages() async throws {
        let page = try json(await run(.searchTracks, ["limit": 2, "offset": 1]))
        XCTAssertEqual(page["total"]?.intValue, 4)
        XCTAssertEqual(page["offset"]?.intValue, 1)
        XCTAssertEqual(page["tracks"]?.arrayValue?.count, 2)
    }

    func testSearchRefusesAnUnknownCrateOrSort() async {
        let crate = await run(.searchTracks, ["crate": "Nope"])
        XCTAssertTrue(crate.isError)
        XCTAssertTrue(crate.text.contains("Everything"), crate.text)
        let sort = await run(.searchTracks, ["sort": "vibes"])
        XCTAssertTrue(sort.isError)
    }

    func testAlbumsGroupTracksAndListTheirIDsInOrder() async throws {
        let albums = try json(await run(.listAlbums, ["query": "kind of blue"]))
        let album = try XCTUnwrap(albums["albums"]?.arrayValue?.first)
        XCTAssertEqual(albums["total"]?.intValue, 1)
        XCTAssertEqual(album["title"], "Kind of Blue")
        XCTAssertEqual(album["album_artist"], "Miles Davis")
        XCTAssertEqual(album["year"]?.intValue, 1959)
        XCTAssertEqual(album["track_ids"], [id(miles1), id(miles2)])
        XCTAssertEqual(album["crates"], ["Everything", "Jazz Night"])
        XCTAssertEqual(album["plays"]?.intValue, 12)
    }

    func testHistoryReadsTheWindowFromTheMonthlyCounts() async throws {
        let allTime = try json(await run(.listeningHistory))
        XCTAssertEqual(allTime["top_tracks"]?.arrayValue?.compactMap { $0["id"] }, [id(bjork), id(miles1)])
        let year = try json(await run(.listeningHistory, ["window": "this_year"]))
        XCTAssertEqual(year["top_tracks"]?.arrayValue?.compactMap { $0["id"] }, [id(miles1)])
        XCTAssertEqual(year["total_plays"]?.intValue, 7)
        let month = try json(await run(.listeningHistory, ["window": "this_month"]))
        XCTAssertEqual(month["total_plays"]?.intValue, 3)
        XCTAssertEqual(month["top_artists"]?.arrayValue?.first?["artist"], "Miles Davis")
    }

    // MARK: - Filing into crates

    func testFilingCreatesCratesInOneUndoableStep() async throws {
        let result = try json(await run(.fileIntoCrates, [
            "summary": "2 mood crates",
            "assignments": [
                ["crate": "Late Night", "track_ids": [id(miles1), id(miles2)]],
                ["crate": "Restless", "track_ids": [id(bjork), id(aphex)]],
            ],
        ]))
        XCTAssertEqual(result["crates"]?.arrayValue?.compactMap { $0["crate"]?.stringValue }, ["Late Night", "Restless"])
        XCTAssertEqual(result["crates"]?.arrayValue?.first?["created"], true)
        XCTAssertEqual(host.crates["Late Night"], [miles1, miles2].map { TrackStore.key(for: $0.track.fileURL) })
        XCTAssertEqual(host.crates["Everything"]?.count, 4)       // a copy, not a move
        XCTAssertEqual(host.writeCalls, 1)
        XCTAssertEqual(assistant.journal.entries.map(\.summary), ["2 mood crates"])

        let undo = await run(.undoLastChange)
        XCTAssertFalse(undo.isError, undo.text)
        XCTAssertEqual(Set(host.trashedCrates), ["Late Night", "Restless"])
        XCTAssertTrue(assistant.journal.entries.isEmpty)
    }

    func testFilingWithRemoveFromCrateIsAMoveAndUndoPutsItBack() async throws {
        _ = try json(await run(.fileIntoCrates, [
            "summary": "Jazz out of Everything",
            "assignments": [["crate": "jazz night", "track_ids": [id(miles1), id(miles2)]]],
            "remove_from_crate": "Everything",
        ]))
        let key = { (t: LoadedTrack) in TrackStore.key(for: t.track.fileURL) }
        XCTAssertEqual(host.crates["Jazz Night"], [key(miles1), key(miles2)])   // matched the existing crate's spelling
        XCTAssertEqual(host.crates["Everything"], [key(bjork), key(aphex)])

        _ = await run(.undoLastChange)
        XCTAssertEqual(host.crates["Jazz Night"], [key(miles1)])
        XCTAssertEqual(Set(host.crates["Everything"] ?? []), Set([miles1, miles2, bjork, aphex].map(key)))
        XCTAssertTrue(host.trashedCrates.isEmpty)
    }

    func testUndoKeepsACrateTheUserHasAddedToSince() async throws {
        _ = try json(await run(.fileIntoCrates, [
            "summary": "Ambient", "assignments": [["crate": "Ambient", "track_ids": [id(aphex)]]],
        ]))
        host.crates["Ambient"]!.append(TrackStore.key(for: bjork.track.fileURL))   // the user's own addition

        let undo = await run(.undoLastChange)
        XCTAssertTrue(host.trashedCrates.isEmpty)
        XCTAssertEqual(host.crates["Ambient"], [TrackStore.key(for: bjork.track.fileURL)])
        XCTAssertTrue(undo.text.contains("Kept \"Ambient\""), undo.text)
    }

    func testFilingRefusesEverythingWhenAnIDIsUnknown() async {
        let result = await run(.fileIntoCrates, [
            "summary": "x",
            "assignments": [["crate": "New", "track_ids": [id(miles1), "00000000-0000-0000-0000-000000000000", "junk"]]],
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("2 track IDs aren't"), result.text)
        XCTAssertEqual(host.writeCalls, 0)
        XCTAssertNil(host.crates["New"])
        XCTAssertTrue(assistant.journal.entries.isEmpty)
    }

    func testFilingRefusesThePrepCrateEitherWay() async {
        let into = await run(.fileIntoCrates, ["summary": "x", "assignments": [["crate": "prep crate", "track_ids": [id(miles1)]]]])
        XCTAssertTrue(into.isError)
        let fromPrep = await run(.fileIntoCrates, ["summary": "x", "assignments": [["crate": "New", "track_ids": [id(loose)]]]])
        XCTAssertTrue(fromPrep.isError)
        XCTAssertTrue(fromPrep.text.contains("only in the Prep Crate"), fromPrep.text)
        XCTAssertEqual(host.writeCalls, 0)
    }

    func testFilingRefusesABadCrateName() async {
        let result = await run(.fileIntoCrates, ["summary": "x", "assignments": [["crate": "AC/DC", "track_ids": [id(miles1)]]]])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(host.writeCalls, 0)
    }

    func testFilingWhatIsAlreadyThereChangesNothing() async {
        let result = await run(.fileIntoCrates, ["summary": "x", "assignments": [["crate": "Jazz Night", "track_ids": [id(miles1)]]]])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.hasPrefix("Nothing changed"), result.text)
        XCTAssertTrue(assistant.journal.entries.isEmpty)
    }

    func testChangesAreRefusedWhileTheLibraryIsReadOnly() async {
        host.refusal = "The library drive is disconnected."
        let result = await run(.fileIntoCrates, ["summary": "x", "assignments": [["crate": "New", "track_ids": [id(miles1)]]]])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.text, "The library drive is disconnected.")
        XCTAssertEqual(host.writeCalls, 0)
    }

    // MARK: - Playlists and streams

    func testPlaylistRefusesToReplaceUnlessAskedAndUndoRestoresIt() async throws {
        host.playlists = [Playlist(name: "Best Of", trackURLs: [aphex.track.fileURL])]
        let refused = await run(.createPlaylist, ["summary": "x", "name": "best of", "track_ids": [id(bjork)]])
        XCTAssertTrue(refused.isError)

        _ = try json(await run(.createPlaylist, ["summary": "Pitchfork picks", "name": "best of",
                                                 "track_ids": [id(bjork), id(miles1)], "replace": true]))
        XCTAssertEqual(host.playlists.first?.trackURLs, [bjork.track.fileURL, miles1.track.fileURL])

        _ = await run(.undoLastChange)
        XCTAssertEqual(host.playlists.first?.name, "Best Of")
        XCTAssertEqual(host.playlists.first?.trackURLs.map(\.path), [aphex.track.fileURL.path])
    }

    func testUndoTrashesANewPlaylistButNotOneEditedSince() async throws {
        _ = try json(await run(.createPlaylist, ["summary": "a", "name": "Mix", "track_ids": [id(bjork)]]))
        host.playlists[0].trackURLs.append(aphex.track.fileURL)        // the user edits it
        let undo = await run(.undoLastChange)
        XCTAssertTrue(host.trashedPlaylists.isEmpty)
        XCTAssertTrue(undo.text.contains("Left the playlist"), undo.text)

        _ = try json(await run(.createPlaylist, ["summary": "b", "name": "Mix 2", "track_ids": [id(bjork)]]))
        _ = await run(.undoLastChange)
        XCTAssertEqual(host.trashedPlaylists, ["Mix 2"])
    }

    func testStreamsAddOnlyNewYouTubeLinksAndUndoRemovesThem() async throws {
        host.streams = [StreamSource(id: "old", url: "https://www.youtube.com/watch?v=aaaaaaaaaaa", title: "Old",
                                     channel: "c", kind: .video, hue: 0, addedAt: now)]
        let result = try json(await run(.addStreams, ["summary": "Lo-fi radio", "urls": [
            "https://www.youtube.com/watch?v=jfKfPfyJRdk",
            "https://vimeo.com/123",
            "https://www.youtube.com/watch?v=aaaaaaaaaaa",
        ]]))
        XCTAssertEqual(result["added"]?.arrayValue?.count, 1)
        XCTAssertEqual(result["skipped"]?.arrayValue?.compactMap { $0["reason"]?.stringValue },
                       ["only YouTube links are supported", "already saved"])
        XCTAssertEqual(host.streams.count, 2)

        _ = await run(.undoLastChange)
        XCTAssertEqual(host.streams.map(\.id), ["old"])
    }

    // MARK: - Tags

    func testProposalCarriesOnlyWhatChangesAndWritesNothing() async throws {
        let result = await run(.proposeTagChanges, ["summary": "One genre each", "changes": [
            ["track_id": id(bjork), "genre": "Art Pop"],
            ["track_id": id(miles1), "genre": "Jazz"],                  // already so
            ["track_id": id(aphex), "genre": "Ambient Techno", "year": "1992", "mood": "calm"],
            ["track_id": "nope", "genre": "x"],
        ]])
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("Sent 2 tracks (2 tag changes)"), result.text)
        XCTAssertTrue(result.text.contains("mood"), result.text)
        XCTAssertTrue(result.text.contains("wasn't found"), result.text)

        let proposal = try XCTUnwrap(host.presented)
        XCTAssertEqual(proposal.summary, "One genre each")
        XCTAssertEqual(proposal.items.map(\.trackID), [bjork.track.id, aphex.track.id])
        XCTAssertEqual(proposal.items[0].changedFields, ["genre"])
        XCTAssertEqual(proposal.items[0].current.genre, "Electronic; Art Pop; Trip Hop")
        XCTAssertEqual(proposal.items[0].proposed.genre, "Art Pop")
        XCTAssertEqual(proposal.items[1].changedFields, ["genre"])
        XCTAssertTrue(assistant.journal.entries.isEmpty)            // nothing applied yet
    }

    func testNullClearsATextFieldAndAWrongTypeIsRefused() async throws {
        _ = await run(.proposeTagChanges, ["summary": "x", "changes": [["track_id": id(bjork), "genre": .null, "year": 1998]]])
        let item = try XCTUnwrap(host.presented?.items.first)
        XCTAssertNil(item.proposed.genre)
        XCTAssertEqual(item.proposed.year, 1998)
        XCTAssertEqual(item.changedFields, ["year", "genre"])

        let bad = await run(.proposeTagChanges, ["summary": "x", "changes": [["track_id": id(bjork), "year": "soon"]]])
        XCTAssertTrue(bad.isError)
        let badText = await run(.proposeTagChanges, ["summary": "x", "changes": [["track_id": id(bjork), "genre": 5]]])
        XCTAssertTrue(badText.isError)
    }

    func testAProposalTheSheetCantShowIsAnError() async {
        host.reviewRefusal = "A review is already open in CrateDigger."
        let result = await run(.proposeTagChanges, ["summary": "x", "changes": [["track_id": id(bjork), "genre": "Pop"]]])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.text, "A review is already open in CrateDigger.")
    }

    func testUndoingAppliedTagsRestoresOnlyFieldsNotChangedSince() async throws {
        let before = AssistantTagValues(bjork)
        var after = before
        after.genre = "Art Pop"
        after.year = 1998
        host.retag(bjork.track.id) { $0 = after }                   // the sheet applied it
        assistant.recordAppliedTags(summary: "Genres", edits: [.init(trackID: bjork.track.id, before: before, after: after)])
        host.retag(bjork.track.id) { $0.year = 1997 }               // then the user fixed the year by hand

        let undo = await run(.undoLastChange)
        XCTAssertFalse(undo.isError, undo.text)
        let restored = try XCTUnwrap(host.restoredTags[bjork.track.id])
        XCTAssertEqual(restored.fields, ["genre"])                  // the year is the user's now
        XCTAssertEqual(restored.values.genre, "Electronic; Art Pop; Trip Hop")
        XCTAssertTrue(undo.text.contains("Left 1 tag alone"), undo.text)
    }

    /// Found end to end: undoing a genre the assistant added to an untagged
    /// track left the genre in the file, because nil reads "leave alone" to
    /// the tag writer. A cleared text field is written as "", which deletes.
    func testUndoClearsATextTagTheChangeAddedButCantRemoveANumber() async throws {
        let before = AssistantTagValues(aphex)
        var after = before
        after.genre = "Electronic"
        after.discNumber = 1
        host.retag(aphex.track.id) { $0 = after }
        assistant.recordAppliedTags(summary: "Genres", edits: [.init(trackID: aphex.track.id, before: before, after: after)])

        let undo = await run(.undoLastChange)
        let restored = try XCTUnwrap(host.restoredTags[aphex.track.id])
        XCTAssertEqual(restored.fields, ["genre"])
        XCTAssertNil(restored.values.genre)
        XCTAssertEqual(restored.values.applied(to: aphex.metadata, fields: restored.fields).genre, "")
        XCTAssertTrue(undo.text.contains("Couldn't remove 1 number"), undo.text)
    }

    func testANumberCanBeChangedButNotRemoved() async {
        for value: JSONValue in [.null, 0] {
            let result = await run(.proposeTagChanges, ["summary": "x", "changes": [["track_id": id(bjork), "year": value]]])
            XCTAssertTrue(result.isError, "\(value)")
            XCTAssertTrue(result.text.contains("can be changed but not removed"), result.text)
        }
    }

    func testTagValuesWriteOnlyTheNamedFields() {
        var values = AssistantTagValues(loose)                      // title "untitled" is the scan's, not a tag
        values.genre = "Field Recording"
        let bare = ConversionMetadata(comment: "keep me")
        let written = values.applied(to: bare, fields: ["genre"])
        XCTAssertEqual(written.genre, "Field Recording")
        XCTAssertNil(written.title)                                 // never invented from the file name
        XCTAssertEqual(written.comment, "keep me")
    }

    // MARK: - Journal

    func testUndoIsRefusedInAnotherLibrary() async throws {
        _ = try json(await run(.fileIntoCrates, ["summary": "x", "assignments": [["crate": "New", "track_ids": [id(miles1)]]]]))
        host.folder = "/Volumes/Other/Crates"
        let undo = await run(.undoLastChange)
        XCTAssertTrue(undo.isError)
        XCTAssertEqual(assistant.journal.entries.count, 1)
    }

    func testNothingToUndo() async {
        let undo = await run(.undoLastChange)
        XCTAssertFalse(undo.isError)
        XCTAssertEqual(undo.text, "There is nothing to undo.")
    }

    func testJournalSurvivesARelaunchAndKeepsTwenty() throws {
        let journal = AssistantJournal(fileURL: journalURL)
        for n in 1...25 { try journal.append(AssistantChange(summary: "change \(n)", libraryFolder: "/f")) }
        let reopened = AssistantJournal(fileURL: journalURL)
        XCTAssertEqual(reopened.entries.count, AssistantJournal.capacity)
        XCTAssertEqual(reopened.entries.first?.summary, "change 6")
        XCTAssertEqual(reopened.last?.summary, "change 25")
    }

    func testAnUnreadableJournalStartsEmptyAndIsKept() throws {
        try Data("not json".utf8).write(to: journalURL)
        let journal = AssistantJournal(fileURL: journalURL)
        XCTAssertTrue(journal.entries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.appendingPathExtension("unreadable").path))
        try? FileManager.default.removeItem(at: journalURL.appendingPathExtension("unreadable"))
    }

    func testListChangesIsNewestFirst() async throws {
        _ = try json(await run(.fileIntoCrates, ["summary": "first", "assignments": [["crate": "A", "track_ids": [id(miles1)]]]]))
        _ = try json(await run(.fileIntoCrates, ["summary": "second", "assignments": [["crate": "B", "track_ids": [id(miles1)]]]]))
        let changes = try json(await run(.listChanges))
        XCTAssertEqual(changes["changes"]?.arrayValue?.compactMap { $0["summary"]?.stringValue }, ["second", "first"])
        XCTAssertEqual(changes["changes"]?.arrayValue?.first?["date"], "2026-10-17")
    }
}
