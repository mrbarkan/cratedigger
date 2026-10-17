import AssistantKit
import Foundation

/// What the assistant needs from the app. The app implements it on the view
/// model, through the same write paths the UI uses, so the disconnected-library
/// guard and every repoint apply to the assistant exactly as to a click.
@MainActor
public protocol LibraryAssistantHost: AnyObject {
    func assistantLibraryInput() -> AssistantLibraryInput
    /// nil when the library can be written; otherwise why not, in words the
    /// model can pass on.
    func assistantWriteRefusal() -> String?
    /// The crates folder now in use, to tie journal entries to their library.
    func assistantLibraryFolder() -> String
    /// Rewrites each crate's membership, creating any crate that is missing.
    func assistantWriteCrates(_ memberships: [(name: String, paths: [String])]) throws
    /// Moves crates to the Trash.
    func assistantTrashCrates(_ names: [String]) throws
    func assistantWritePlaylist(name: String, paths: [String]) throws
    func assistantTrashPlaylist(name: String) throws
    func assistantAddStreams(_ streams: [StreamSource])
    func assistantRemoveStreams(ids: [String])
    /// Shows the review sheet. nil when it is up; otherwise why it can't be.
    func assistantPresentTagReview(_ proposal: AssistantTagProposal) -> String?
    /// Writes these tags back to the tracks' files (an undo).
    func assistantRestoreTags(_ writes: [UUID: AssistantTagWrite]) throws
    /// The journal changed: refresh the Undo menu item.
    func assistantJournalDidChange()
}

/// A tool's arguments did not make sense. The message goes to the model.
struct AssistantToolError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// The library assistant's tools, run against the app through
/// `LibraryAssistantHost`. Reads work on a fresh `AssistantLibrary` each call;
/// changes are planned here, applied by the host and recorded in the journal.
@MainActor
public final class LibraryAssistant {
    public let journal: AssistantJournal
    private weak var host: LibraryAssistantHost?
    private let now: () -> Date
    private let calendar: Calendar

    public init(host: LibraryAssistantHost, journal: AssistantJournal = AssistantJournal(),
                now: @escaping () -> Date = Date.init, calendar: Calendar = .current) {
        self.host = host
        self.journal = journal
        self.now = now
        self.calendar = calendar
    }

    public func call(_ call: AssistantCall) async -> MCPToolResult {
        guard let host else { return .failure("CrateDigger is closing.") }
        guard let tool = AssistantTool(rawValue: call.tool) else {
            return .failure("Unknown tool: \(call.tool)")
        }
        let arguments = Arguments(call.arguments)
        do {
            switch tool {
            case .libraryOverview: return text(overview(library(host), host: host))
            case .searchTracks: return text(try search(arguments, in: library(host)))
            case .listAlbums: return text(try albums(arguments, in: library(host)))
            case .listeningHistory: return text(try history(arguments, in: library(host)))
            case .listStreams: return text(streams(in: library(host)))
            case .listChanges: return text(changes())
            case .fileIntoCrates: return try fileIntoCrates(arguments, host: host)
            case .createPlaylist: return try createPlaylist(arguments, host: host)
            case .addStreams: return try addStreams(arguments, host: host)
            case .undoLastChange: return undoLast()
            case .proposeTagChanges: return try proposeTags(arguments, host: host)
            }
        } catch let error as AssistantToolError {
            return .failure(error.message)
        } catch {
            return .failure("CrateDigger couldn't do that: \(error.localizedDescription)")
        }
    }

    private func library(_ host: LibraryAssistantHost) -> AssistantLibrary {
        AssistantLibrary.build(host.assistantLibraryInput())
    }

    private func text(_ value: JSONValue) -> MCPToolResult { MCPToolResult(text: value.encodedString()) }

    // MARK: - Reads

    func overview(_ library: AssistantLibrary, host: LibraryAssistantHost) -> JSONValue {
        let inCrates = library.tracks.filter { !($0.crates == [AssistantLibrary.prepCrateName]) }
        let artists = Set(inCrates.map { ($0.tags.albumArtist ?? $0.tags.artist ?? "").lowercased() })
        let albums = Set(inCrates.map(\.albumKey))
        var genres: [String: Int] = [:]
        var formats: [String: Int] = [:]
        for track in inCrates {
            if let genre = track.tags.genre { genres[genre, default: 0] += 1 }
            formats[track.format ?? "unknown", default: 0] += 1
        }
        let years = inCrates.compactMap(\.tags.year).filter { $0 > 0 }
        var result: [String: JSONValue] = [
            "tracks": .number(Double(inCrates.count)),
            "albums": .number(Double(albums.count)),
            "artists": .number(Double(artists.count)),
            "crates": .array(library.crateNames.map {
                ["name": .string($0), "tracks": .number(Double(library.crates[$0]?.count ?? 0))]
            }),
            "prep_crate_tracks": .number(Double(library.prepCratePaths.count)),
            "playlists": .array(library.playlists.map {
                ["name": .string($0.name), "tracks": .number(Double($0.trackURLs.count))]
            }),
            "top_genres": .array(Self.ranked(genres, limit: 30).map {
                ["genre": .string($0.key), "tracks": .number(Double($0.value))]
            }),
            "formats": .object(formats.mapValues { .number(Double($0)) }),
            "tracks_without_genre": .number(Double(inCrates.filter { $0.tags.genre == nil }.count)),
            "tracks_without_year": .number(Double(inCrates.filter { ($0.tags.year ?? 0) <= 0 }.count)),
            "streams": .number(Double(library.streams.count)),
            "undoable_changes": .number(Double(journal.entries.count)),
        ]
        if let first = years.min(), let last = years.max() {
            result["years"] = ["from": .number(Double(first)), "to": .number(Double(last))]
        }
        if let refusal = host.assistantWriteRefusal() {
            result["read_only"] = .string(refusal)
        }
        return .object(result)
    }

    func search(_ arguments: Arguments, in library: AssistantLibrary) throws -> JSONValue {
        var tracks = try scope(arguments, in: library)
        if let query = arguments.string("query") {
            let tokens = Self.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
            tracks = tracks.filter { track in
                let haystacks = [track.tags.title, track.tags.artist, track.tags.albumArtist,
                                 track.tags.album, track.tags.genre].compactMap { $0.map(Self.fold) }
                return tokens.allSatisfy { token in haystacks.contains { $0.contains(token) } }
            }
        }
        if let artist = arguments.string("artist").map(Self.fold) {
            tracks = tracks.filter {
                [$0.tags.artist, $0.tags.albumArtist].contains { $0.map(Self.fold)?.contains(artist) ?? false }
            }
        }
        if let album = arguments.string("album").map(Self.fold) {
            tracks = tracks.filter { $0.tags.album.map(Self.fold)?.contains(album) ?? false }
        }
        if let genre = arguments.string("genre").map(Self.fold) {
            tracks = tracks.filter { $0.tags.genre.map(Self.fold)?.contains(genre) ?? false }
        }
        if let from = try arguments.int("year_from") { tracks = tracks.filter { ($0.tags.year ?? Int.min) >= from } }
        if let to = try arguments.int("year_to") { tracks = tracks.filter { ($0.tags.year ?? Int.max) <= to } }
        if let plays = try arguments.int("min_plays") { tracks = tracks.filter { $0.playCount >= plays } }
        if let missing = try arguments.choice("missing_tag", from: ["genre", "year", "artist", "album_artist", "album", "track_number"]) {
            tracks = tracks.filter { track in
                switch missing {
                case "year": return (track.tags.year ?? 0) <= 0
                case "track_number": return (track.tags.trackNumber ?? 0) <= 0
                default: return track.tags.display(missing) == nil
                }
            }
        }

        let sort = try arguments.choice("sort", from: ["artist", "album", "title", "year", "plays", "last_played", "date_added"]) ?? "artist"
        tracks.sort(by: Self.trackOrder(sort))
        if arguments.bool("descending") == true { tracks.reverse() }

        let (page, offset) = try Self.page(tracks, arguments)
        return [
            "total": .number(Double(tracks.count)),
            "offset": .number(Double(offset)),
            "tracks": .array(page.map(json)),
        ]
    }

    func albums(_ arguments: Arguments, in library: AssistantLibrary) throws -> JSONValue {
        let tracks = try scope(arguments, in: library)
        var grouped: [AlbumFolderKey: [AssistantTrack]] = [:]
        var order: [AlbumFolderKey] = []
        for track in tracks {
            if grouped[track.albumKey] == nil { order.append(track.albumKey) }
            grouped[track.albumKey, default: []].append(track)
        }
        struct Album { var key: AlbumFolderKey; var tracks: [AssistantTrack]; var genres: [String]; var plays: Int }
        var albums: [Album] = order.map { key in
            let members = grouped[key]!.sorted(by: Self.trackOrder("album"))
            var genreCounts: [String: Int] = [:]
            for track in members { if let genre = track.tags.genre { genreCounts[genre, default: 0] += 1 } }
            return Album(key: key, tracks: members, genres: Self.ranked(genreCounts, limit: 10).map(\.key),
                         plays: members.reduce(0) { $0 + $1.playCount })
        }
        if let query = arguments.string("query") {
            let tokens = Self.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
            albums = albums.filter { album in
                let haystacks = ([album.key.album, album.key.artistBucket] + album.genres).map(Self.fold)
                return tokens.allSatisfy { token in haystacks.contains { $0.contains(token) } }
            }
        }
        switch try arguments.choice("sort", from: ["artist", "title", "year", "plays"]) ?? "artist" {
        case "title": albums.sort { Self.less($0.key.album, $1.key.album) }
        case "year": albums.sort { ($0.key.year, $0.key.album) < ($1.key.year, $1.key.album) }
        case "plays": albums.sort { $0.plays > $1.plays }
        default:
            albums.sort {
                $0.key.artistBucket.caseInsensitiveCompare($1.key.artistBucket) == .orderedSame
                    ? $0.key.year < $1.key.year
                    : Self.less($0.key.artistBucket, $1.key.artistBucket)
            }
        }
        let (page, offset) = try Self.page(albums, arguments)
        return [
            "total": .number(Double(albums.count)),
            "offset": .number(Double(offset)),
            "albums": .array(page.map { album in
                var object: [String: JSONValue] = [
                    "title": .string(album.key.album),
                    "album_artist": .string(album.key.artistBucket),
                    "tracks": .number(Double(album.tracks.count)),
                    "track_ids": .array(album.tracks.map { .string($0.id.uuidString) }),
                    "crates": .array(Self.orderedUnion(album.tracks.map(\.crates)).map(JSONValue.string)),
                ]
                if let year = Int(album.key.year), year > 0 { object["year"] = .number(Double(year)) }
                if !album.genres.isEmpty { object["genres"] = .array(album.genres.map(JSONValue.string)) }
                if album.plays > 0 { object["plays"] = .number(Double(album.plays)) }
                return .object(object)
            }),
        ]
    }

    /// The tracks a read works on: one crate's when `crate` names one, else
    /// the library, which is every crate and not the Prep Crate. Staged files
    /// aren't in the library yet, so they only show when asked for by name,
    /// the same way `library_overview` counts them apart.
    func scope(_ arguments: Arguments, in library: AssistantLibrary) throws -> [AssistantTrack] {
        guard let crate = arguments.string("crate") else {
            return library.tracks.filter { $0.crates != [AssistantLibrary.prepCrateName] }
        }
        guard let members = library.members(ofCrate: crate) else {
            throw AssistantToolError("There is no crate called \"\(crate)\". Crates: \(library.crateNames.joined(separator: ", ")).")
        }
        let set = Set(members)
        return library.tracks.filter { set.contains($0.path) }
    }

    func history(_ arguments: Arguments, in library: AssistantLibrary) throws -> JSONValue {
        let window = try arguments.choice("window", from: ["all_time", "this_year", "this_month"]) ?? "all_time"
        let limit = min(max(try arguments.int("limit") ?? 25, 1), 100)
        let parts = calendar.dateComponents([.year, .month], from: now())
        let year = String(format: "%04d", parts.year ?? 0)
        let month = String(format: "%@-%02d", year, parts.month ?? 0)

        func plays(_ track: AssistantTrack) -> Int {
            guard let stats = track.stats else { return 0 }
            switch window {
            case "this_year": return stats.playsByMonth.filter { $0.key.hasPrefix(year + "-") }.values.reduce(0, +)
            case "this_month": return stats.playsByMonth[month] ?? 0
            default: return stats.playCount
            }
        }

        var trackPlays: [(AssistantTrack, Int)] = []
        var artistPlays: [String: Int] = [:]
        var albumPlays: [AlbumFolderKey: Int] = [:]
        for track in library.tracks {
            let count = plays(track)
            guard count > 0 else { continue }
            trackPlays.append((track, count))
            artistPlays[track.tags.albumArtist ?? track.tags.artist ?? "Unknown Artist", default: 0] += count
            albumPlays[track.albumKey, default: 0] += count
        }
        trackPlays.sort { $0.1 == $1.1 ? Self.less($0.0.displayTitle, $1.0.displayTitle) : $0.1 > $1.1 }
        let topAlbums = albumPlays.sorted { $0.value == $1.value ? Self.less($0.key.album, $1.key.album) : $0.value > $1.value }

        return [
            "window": .string(window),
            "total_plays": .number(Double(trackPlays.reduce(0) { $0 + $1.1 })),
            "top_tracks": .array(trackPlays.prefix(limit).map { track, count in
                var object = json(track).objectValue ?? [:]
                object["plays"] = .number(Double(count))
                return .object(object)
            }),
            "top_artists": .array(Self.ranked(artistPlays, limit: limit).map {
                ["artist": .string($0.key), "plays": .number(Double($0.value))]
            }),
            "top_albums": .array(topAlbums.prefix(limit).map {
                ["title": .string($0.key.album), "album_artist": .string($0.key.artistBucket),
                 "plays": .number(Double($0.value))]
            }),
        ]
    }

    func streams(in library: AssistantLibrary) -> JSONValue {
        ["streams": .array(library.streams.map {
            ["id": .string($0.id), "title": .string($0.title), "channel": .string($0.channel),
             "kind": .string($0.kind.rawValue), "url": .string($0.url)]
        })]
    }

    func changes() -> JSONValue {
        ["changes": .array(journal.entries.reversed().map {
            ["summary": .string($0.summary), "date": .string(Self.dateText($0.date))]
        })]
    }

    // MARK: - Changes

    func fileIntoCrates(_ arguments: Arguments, host: LibraryAssistantHost) throws -> MCPToolResult {
        if let refusal = host.assistantWriteRefusal() { throw AssistantToolError(refusal) }
        let summary = try arguments.requiredString("summary")
        let library = library(host)
        guard let assignments = arguments.raw("assignments")?.arrayValue, !assignments.isEmpty else {
            throw AssistantToolError("assignments must list at least one crate.")
        }

        // Resolve every crate name and track first; nothing is written unless
        // the whole call makes sense.
        var targets: [String: [String]] = [:]      // crate name → paths to add, in order
        var targetOrder: [String] = []
        var created: Set<String> = []
        var unknown: [String] = []
        var prepOnly = 0
        for assignment in assignments {
            guard let rawName = assignment["crate"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawName.isEmpty else {
                throw AssistantToolError("Every assignment needs a crate name.")
            }
            guard !library.isPrepCrate(rawName) else {
                throw AssistantToolError("Tracks can't be filed into the Prep Crate. It is the staging area for new imports.")
            }
            let name: String
            if let existing = library.crateName(matching: rawName) {
                name = existing
            } else if let pending = targetOrder.first(where: { $0.lowercased() == rawName.lowercased() }) {
                name = pending
            } else {
                switch CrateNameValidator.validate(rawName, existing: library.crateNames + targetOrder) {
                case .invalid(let reason): throw AssistantToolError("Can't make a crate called \"\(rawName)\": \(reason)")
                case .ok(let safe): name = safe
                }
                created.insert(name)
            }
            if targets[name] == nil { targetOrder.append(name); targets[name] = [] }
            for raw in assignment["track_ids"]?.arrayValue ?? [] {
                guard let text = raw.stringValue, let id = UUID(uuidString: text), let track = library.track(id: id) else {
                    unknown.append(raw.stringValue ?? raw.encodedString())
                    continue
                }
                if track.crates == [AssistantLibrary.prepCrateName] { prepOnly += 1; continue }
                if !targets[name]!.contains(track.path) { targets[name]!.append(track.path) }
            }
        }
        if !unknown.isEmpty {
            throw AssistantToolError("\(unknown.count) track ID\(unknown.count == 1 ? " isn't" : "s aren't") in the library, so nothing was filed: \(unknown.prefix(10).joined(separator: ", "))\(unknown.count > 10 ? ", …" : ""). Get IDs from search_tracks or list_albums.")
        }
        if prepOnly > 0 {
            throw AssistantToolError("\(prepOnly) of those tracks are only in the Prep Crate, so nothing was filed. Ask the user to file them from the Prep Crate in CrateDigger first, then try again.")
        }

        var source: String?
        if let raw = arguments.string("remove_from_crate") {
            guard !library.isPrepCrate(raw) else {
                throw AssistantToolError("Tracks can't be removed from the Prep Crate this way.")
            }
            guard let name = library.crateName(matching: raw) else {
                throw AssistantToolError("There is no crate called \"\(raw)\" to remove from.")
            }
            source = name
        }

        var edits: [AssistantChange.CrateEdit] = []
        var memberships: [(name: String, paths: [String])] = []
        for name in targetOrder {
            let current = library.crates[name] ?? []
            let present = Set(current)
            let added = targets[name]!.filter { !present.contains($0) }
            guard !added.isEmpty || created.contains(name) else { continue }
            edits.append(.init(name: name, created: created.contains(name), added: added, removed: []))
            memberships.append((name, current + added))
        }
        if let source {
            let current = library.crates[source] ?? []
            let filed = Set(targetOrder.filter { $0 != source }.flatMap { targets[$0]! })
            let removed = current.filter(filed.contains)
            if !removed.isEmpty {
                let kept = current.filter { !filed.contains($0) }
                if let index = memberships.firstIndex(where: { $0.name == source }) {
                    let added = edits[index].added
                    memberships[index].paths = kept + added.filter { !kept.contains($0) }
                    edits[index].removed = removed
                } else {
                    edits.append(.init(name: source, created: false, added: [], removed: removed))
                    memberships.append((source, kept))
                }
            }
        }
        guard !edits.isEmpty else {
            return MCPToolResult(text: "Nothing changed: every track was already in its crate.")
        }

        try host.assistantWriteCrates(memberships)
        let change = AssistantChange(date: now(), summary: summary, libraryFolder: host.assistantLibraryFolder(), crates: edits)
        let saved = record(change, host: host)

        let report: [JSONValue] = edits.map { edit in
            var object: [String: JSONValue] = ["crate": .string(edit.name)]
            if edit.created { object["created"] = true }
            if !edit.added.isEmpty { object["added"] = .number(Double(edit.added.count)) }
            if !edit.removed.isEmpty { object["removed"] = .number(Double(edit.removed.count)) }
            object["tracks_now"] = .number(Double(memberships.first { $0.name == edit.name }?.paths.count ?? 0))
            return .object(object)
        }
        return text([
            "done": .string(summary),
            "crates": .array(report),
            "undo": .string(saved ? "The user can undo this with Edit > Undo AI Change, or call undo_last_change."
                                  : "Applied, but the undo history couldn't be saved, so this can't be undone from CrateDigger."),
        ])
    }

    func createPlaylist(_ arguments: Arguments, host: LibraryAssistantHost) throws -> MCPToolResult {
        if let refusal = host.assistantWriteRefusal() { throw AssistantToolError(refusal) }
        let summary = try arguments.requiredString("summary")
        let rawName = try arguments.requiredString("name")
        let library = library(host)
        let ids = arguments.raw("track_ids")?.arrayValue ?? []
        guard !ids.isEmpty else { throw AssistantToolError("track_ids must list at least one track.") }

        var paths: [String] = []
        var unknown: [String] = []
        for raw in ids {
            guard let text = raw.stringValue, let id = UUID(uuidString: text), let track = library.track(id: id) else {
                unknown.append(raw.stringValue ?? raw.encodedString())
                continue
            }
            paths.append(track.path)
        }
        if !unknown.isEmpty {
            throw AssistantToolError("\(unknown.count) track ID\(unknown.count == 1 ? " isn't" : "s aren't") in the library, so no playlist was made: \(unknown.prefix(10).joined(separator: ", ")).")
        }

        let existing = library.playlist(matching: rawName)
        let name: String
        if let existing {
            guard arguments.bool("replace") == true else {
                throw AssistantToolError("There is already a playlist called \"\(existing.name)\". Pass replace: true to replace it, or pick another name.")
            }
            name = existing.name
        } else {
            switch CrateNameValidator.validate(rawName, existing: library.playlists.map(\.name)) {
            case .invalid(let reason): throw AssistantToolError("Can't make a playlist called \"\(rawName)\": \(reason)")
            case .ok(let safe): name = safe
            }
        }

        try host.assistantWritePlaylist(name: name, paths: paths)
        let before = existing.map { $0.trackURLs.map { TrackStore.key(for: $0) } }
        let change = AssistantChange(date: now(), summary: summary, libraryFolder: host.assistantLibraryFolder(),
                                     playlist: .init(name: name, before: before, after: paths))
        let saved = record(change, host: host)
        return text([
            "done": .string(summary),
            "playlist": .string(name),
            "replaced": .bool(existing != nil),
            "tracks": .number(Double(paths.count)),
            "undo": .string(saved ? "Undo with Edit > Undo AI Change, or undo_last_change."
                                  : "Made, but the undo history couldn't be saved."),
        ])
    }

    func addStreams(_ arguments: Arguments, host: LibraryAssistantHost) throws -> MCPToolResult {
        let summary = try arguments.requiredString("summary")
        let urls = (arguments.raw("urls")?.arrayValue ?? []).compactMap(\.stringValue)
        guard !urls.isEmpty else { throw AssistantToolError("urls must list at least one link.") }
        let library = library(host)
        var known = Set(library.streams.map(\.url))
        var added: [StreamSource] = []
        var skipped: [JSONValue] = []
        for raw in urls {
            guard let parsed = StreamURLParser.parse(raw) else {
                skipped.append(["url": .string(raw), "reason": "not a link CrateDigger can stream"])
                continue
            }
            guard parsed.isValidHost else {
                skipped.append(["url": .string(raw), "reason": "only YouTube links are supported"])
                continue
            }
            guard !known.contains(parsed.normalizedURL) else {
                skipped.append(["url": .string(raw), "reason": "already saved"])
                continue
            }
            known.insert(parsed.normalizedURL)
            added.append(StreamSource(
                id: "u" + UUID().uuidString, url: parsed.normalizedURL, title: parsed.suggestedTitle,
                channel: parsed.channel, kind: parsed.kind, hue: Int.random(in: 0...359),
                addedAt: now(), viewers: parsed.kind == .live ? "0" : nil))
        }
        var result: [String: JSONValue] = [
            "added": .array(added.map { ["title": .string($0.title), "kind": .string($0.kind.rawValue), "url": .string($0.url)] }),
        ]
        if !skipped.isEmpty { result["skipped"] = .array(skipped) }
        guard !added.isEmpty else { return text(.object(result)) }

        host.assistantAddStreams(added)
        let change = AssistantChange(date: now(), summary: summary, libraryFolder: host.assistantLibraryFolder(),
                                     addedStreamIDs: added.map(\.id))
        let saved = record(change, host: host)
        result["done"] = .string(summary)
        result["undo"] = .string(saved ? "Undo with Edit > Undo AI Change, or undo_last_change."
                                       : "Added, but the undo history couldn't be saved.")
        return text(.object(result))
    }

    /// Undoes the newest journal entry. Also what Edit ▸ Undo AI Change runs.
    public func undoLast() -> MCPToolResult {
        guard let host else { return .failure("CrateDigger is closing.") }
        guard let change = journal.last else { return MCPToolResult(text: "There is nothing to undo.") }
        guard change.libraryFolder == host.assistantLibraryFolder() else {
            return .failure("The last change (\(change.summary)) was made in a different library folder. Switch back to that library to undo it.")
        }
        if let refusal = host.assistantWriteRefusal() { return .failure(refusal) }

        let plan = AssistantUndoPlan.plan(undoing: change, in: library(host))
        do {
            if !plan.crateMemberships.isEmpty { try host.assistantWriteCrates(plan.crateMemberships) }
            if !plan.cratesToTrash.isEmpty { try host.assistantTrashCrates(plan.cratesToTrash) }
            if let playlist = plan.playlistToWrite { try host.assistantWritePlaylist(name: playlist.name, paths: playlist.paths) }
            if let playlist = plan.playlistToTrash { try host.assistantTrashPlaylist(name: playlist) }
            if !plan.streamIDsToRemove.isEmpty { host.assistantRemoveStreams(ids: plan.streamIDsToRemove) }
            if !plan.tagRestores.isEmpty { try host.assistantRestoreTags(plan.tagRestores) }
        } catch {
            return .failure("Couldn't undo \"\(change.summary)\": \(error.localizedDescription)")
        }
        var notes = plan.notes
        do {
            try journal.removeLast()
        } catch {
            // Undoing the same entry again is harmless (what it added is
            // already gone), so this is a note, not a failure.
            notes.append("The undo history couldn't be updated, so this change may still be listed.")
        }
        host.assistantJournalDidChange()
        let noteText = notes.isEmpty ? "" : " " + notes.joined(separator: " ")
        return MCPToolResult(text: "Undid \"\(change.summary)\".\(noteText)")
    }

    func proposeTags(_ arguments: Arguments, host: LibraryAssistantHost) throws -> MCPToolResult {
        if let refusal = host.assistantWriteRefusal() { throw AssistantToolError(refusal) }
        let summary = try arguments.requiredString("summary")
        guard let changes = arguments.raw("changes")?.arrayValue, !changes.isEmpty else {
            throw AssistantToolError("changes must list at least one track.")
        }
        let library = library(host)
        var proposed: [UUID: AssistantTagValues] = [:]
        var order: [UUID] = []
        var unknown: [String] = []
        var ignored: Set<String> = []
        for change in changes {
            guard let object = change.objectValue else { continue }
            guard let text = object["track_id"]?.stringValue, let id = UUID(uuidString: text),
                  let track = library.track(id: id) else {
                unknown.append(object["track_id"]?.stringValue ?? "(missing track_id)")
                continue
            }
            if proposed[id] == nil { order.append(id) }
            var values = proposed[id] ?? track.tags
            for (key, value) in object where key != "track_id" {
                guard AssistantTagValues.fieldNames.contains(key) else { ignored.insert(key); continue }
                try Self.set(key, to: value, in: &values)
            }
            proposed[id] = values
        }

        var items: [AssistantTagProposal.Item] = []
        for id in order {
            guard let track = library.track(id: id), let values = proposed[id] else { continue }
            let fields = values.changedFields(from: track.tags)
            guard !fields.isEmpty else { continue }
            items.append(.init(trackID: id, displayTitle: track.displayTitle, current: track.tags,
                               proposed: values, changedFields: fields))
        }

        var notes: [String] = []
        if !unknown.isEmpty {
            notes.append("\(unknown.count) track ID\(unknown.count == 1 ? " wasn't" : "s weren't") found and left out: \(unknown.prefix(10).joined(separator: ", ")).")
        }
        if !ignored.isEmpty {
            notes.append("Ignored fields that can't be changed: \(ignored.sorted().joined(separator: ", ")).")
        }
        guard !items.isEmpty else {
            return MCPToolResult(text: (["Nothing to review: every proposed value matches what the tracks already carry."] + notes).joined(separator: " "))
        }
        let proposal = AssistantTagProposal(summary: summary, items: items)
        if let refusal = host.assistantPresentTagReview(proposal) { throw AssistantToolError(refusal) }
        let fieldCount = items.reduce(0) { $0 + $1.changedFields.count }
        return MCPToolResult(text: ([
            "Sent \(items.count) track\(items.count == 1 ? "" : "s") (\(fieldCount) tag change\(fieldCount == 1 ? "" : "s")) to CrateDigger for review. Nothing is written until the user ticks what to keep and presses Apply there; ask them to look at CrateDigger.",
        ] + notes).joined(separator: " "))
    }

    /// Called by the review sheet once the user applied a proposal, with what
    /// each written track carried before and after.
    public func recordAppliedTags(summary: String, edits: [AssistantChange.TagEdit]) {
        guard let host, !edits.isEmpty else { return }
        _ = record(AssistantChange(date: now(), summary: summary, libraryFolder: host.assistantLibraryFolder(), tags: edits),
                   host: host)
    }

    /// Appends to the journal. A change has already been applied by the time
    /// this runs, so a failed save is reported, not thrown.
    private func record(_ change: AssistantChange, host: LibraryAssistantHost) -> Bool {
        defer { host.assistantJournalDidChange() }
        do {
            try journal.append(change)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Helpers

    static func set(_ field: String, to value: JSONValue, in values: inout AssistantTagValues) throws {
        if AssistantTool.integerTagFields.contains(field) {
            let number: Int?
            // The tag writer can change a number but not delete one, so a
            // proposal can't either: refused here rather than shown as a
            // removal that would never reach the file.
            guard value != .null, value.intValue != 0 else {
                throw AssistantToolError("\(field) can be changed but not removed; leave it out to keep it.")
            }
            guard let parsed = value.intValue else {
                throw AssistantToolError("\(field) must be a whole number, not \(value.encodedString()).")
            }
            let range = field == "year" ? 1...9999 : 1...999
            guard range.contains(parsed) else {
                throw AssistantToolError("\(field) \(parsed) is out of range.")
            }
            number = parsed
            var source = AssistantTagValues()
            switch field {
            case "year": source.year = number
            case "track_number": source.trackNumber = number
            case "track_total": source.trackTotal = number
            case "disc_number": source.discNumber = number
            default: source.discTotal = number
            }
            values.copy(field, from: source)
        } else {
            let text: String?
            switch value {
            case .null: text = nil
            case .string(let string): text = AssistantTagValues.nonEmpty(string)
            default: throw AssistantToolError("\(field) must be text or null, not \(value.encodedString()).")
            }
            var source = AssistantTagValues()
            switch field {
            case "title": source.title = text
            case "artist": source.artist = text
            case "album_artist": source.albumArtist = text
            case "album": source.album = text
            default: source.genre = text
            }
            values.copy(field, from: source)
        }
    }

    func json(_ track: AssistantTrack) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(track.id.uuidString),
            "title": .string(track.displayTitle),
            "duration": .number(track.durationSeconds.rounded()),
        ]
        let tags = track.tags
        if let value = tags.artist { object["artist"] = .string(value) }
        if let value = tags.albumArtist { object["album_artist"] = .string(value) }
        if let value = tags.album { object["album"] = .string(value) }
        if let value = tags.genre { object["genre"] = .string(value) }
        if let value = tags.year, value > 0 { object["year"] = .number(Double(value)) }
        if let value = tags.trackNumber, value > 0 { object["track_number"] = .number(Double(value)) }
        if let value = tags.discNumber, value > 0 { object["disc_number"] = .number(Double(value)) }
        if let value = track.format { object["format"] = .string(value) }
        object["crates"] = .array(track.crates.map(JSONValue.string))
        if let stats = track.stats {
            if stats.playCount > 0 { object["plays"] = .number(Double(stats.playCount)) }
            if stats.rating > 0 { object["rating"] = .number(Double(stats.rating)) }
            if let last = stats.lastPlayed { object["last_played"] = .string(Self.dateText(last)) }
            object["added"] = .string(Self.dateText(stats.dateAdded))
        }
        return .object(object)
    }

    static func page<T>(_ items: [T], _ arguments: Arguments) throws -> ([T], Int) {
        let limit = min(max(try arguments.int("limit") ?? AssistantTool.defaultLimit, 1), AssistantTool.maximumLimit)
        let offset = max(try arguments.int("offset") ?? 0, 0)
        guard offset < items.count else { return ([], offset) }
        return (Array(items[offset..<min(offset + limit, items.count)]), offset)
    }

    static func trackOrder(_ sort: String) -> (AssistantTrack, AssistantTrack) -> Bool {
        func albumOrder(_ a: AssistantTrack, _ b: AssistantTrack) -> Bool {
            let ka = (a.tags.discNumber ?? 0, a.tags.trackNumber ?? 0)
            let kb = (b.tags.discNumber ?? 0, b.tags.trackNumber ?? 0)
            return ka == kb ? less(a.displayTitle, b.displayTitle) : ka < kb
        }
        func byArtist(_ a: AssistantTrack, _ b: AssistantTrack) -> Bool {
            let artistA = a.tags.albumArtist ?? a.tags.artist ?? ""
            let artistB = b.tags.albumArtist ?? b.tags.artist ?? ""
            if artistA.caseInsensitiveCompare(artistB) != .orderedSame { return less(artistA, artistB) }
            if a.albumKey != b.albumKey {
                return a.albumKey.year == b.albumKey.year ? less(a.albumKey.album, b.albumKey.album)
                                                          : a.albumKey.year < b.albumKey.year
            }
            return albumOrder(a, b)
        }
        switch sort {
        case "album":
            return { a, b in
                a.albumKey.album.caseInsensitiveCompare(b.albumKey.album) == .orderedSame
                    ? albumOrder(a, b) : less(a.albumKey.album, b.albumKey.album)
            }
        case "title": return { less($0.displayTitle, $1.displayTitle) }
        case "year": return { a, b in (a.tags.year ?? 0) == (b.tags.year ?? 0) ? byArtist(a, b) : (a.tags.year ?? 0) < (b.tags.year ?? 0) }
        case "plays": return { a, b in a.playCount == b.playCount ? byArtist(a, b) : a.playCount > b.playCount }
        case "last_played":
            return { a, b in
                let da = a.stats?.lastPlayed ?? .distantPast, db = b.stats?.lastPlayed ?? .distantPast
                return da == db ? byArtist(a, b) : da > db
            }
        case "date_added":
            return { a, b in
                let da = a.stats?.dateAdded ?? .distantPast, db = b.stats?.dateAdded ?? .distantPast
                return da == db ? byArtist(a, b) : da > db
            }
        default: return byArtist
        }
    }

    static func less(_ a: String, _ b: String) -> Bool { a.localizedStandardCompare(b) == .orderedAscending }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func ranked(_ counts: [String: Int], limit: Int) -> [(key: String, value: Int)] {
        Array(counts.sorted { $0.value == $1.value ? less($0.key, $1.key) : $0.value > $1.value }.prefix(limit))
    }

    static func orderedUnion(_ lists: [[String]]) -> [String] {
        var seen: Set<String> = []
        return lists.flatMap { $0 }.filter { seen.insert($0).inserted }
    }

    static func dateText(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}

/// A tool's arguments, read leniently where that costs nothing (a number sent
/// as text) and strictly where a wrong guess would change what happens.
struct Arguments {
    let values: [String: JSONValue]
    init(_ values: [String: JSONValue]) { self.values = values }

    func raw(_ key: String) -> JSONValue? {
        guard let value = values[key], value != .null else { return nil }
        return value
    }

    /// Trimmed text, or nil when absent or blank.
    func string(_ key: String) -> String? {
        raw(key)?.stringValue.flatMap(AssistantTagValues.nonEmpty)
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = string(key) else { throw AssistantToolError("\(key) is required.") }
        return value
    }

    func int(_ key: String) throws -> Int? {
        guard let value = raw(key) else { return nil }
        guard let number = value.intValue else {
            throw AssistantToolError("\(key) must be a whole number, not \(value.encodedString()).")
        }
        return number
    }

    func bool(_ key: String) -> Bool? { raw(key)?.boolValue }

    func choice(_ key: String, from allowed: [String]) throws -> String? {
        guard let value = string(key) else { return nil }
        guard allowed.contains(value) else {
            throw AssistantToolError("\(key) must be one of \(allowed.joined(separator: ", ")), not \"\(value)\".")
        }
        return value
    }
}
