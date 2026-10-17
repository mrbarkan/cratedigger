import Foundation

/// What the app hands the assistant to read: the local library as it stands,
/// in the shapes the app already keeps. `AssistantLibrary.build` turns it into
/// the one the tools search.
public struct AssistantLibraryInput: Sendable {
    public var crates: [(name: String, tracks: [LoadedTrack])]
    public var prepCrate: [LoadedTrack]
    /// Path-keyed, as `ListeningStore` keeps it.
    public var stats: [String: ListeningStats]
    public var playlists: [Playlist]
    public var streams: [StreamSource]

    public init(crates: [(name: String, tracks: [LoadedTrack])], prepCrate: [LoadedTrack] = [],
                stats: [String: ListeningStats] = [:], playlists: [Playlist] = [], streams: [StreamSource] = []) {
        self.crates = crates
        self.prepCrate = prepCrate
        self.stats = stats
        self.playlists = playlists
        self.streams = streams
    }
}

/// One track as the assistant sees it. `path` never leaves the Mac: it is how
/// the assistant writes crate and playlist membership back, and it is never
/// put in a tool result.
public struct AssistantTrack: Sendable, Equatable {
    public var id: UUID
    public var path: String
    public var tags: AssistantTagValues
    public var durationSeconds: Double
    public var format: String?
    public var albumKey: AlbumFolderKey
    public var crates: [String]
    public var stats: ListeningStats?

    /// What a row shows when the title tag is empty.
    public var displayTitle: String {
        if let title = tags.title, !title.isEmpty { return title }
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    public var playCount: Int { stats?.playCount ?? 0 }
}

/// The library the tools read: every track once, by ID, with the crates that
/// list it.
public struct AssistantLibrary: Sendable {
    public static let prepCrateName = "Prep Crate"

    public private(set) var tracks: [AssistantTrack]
    /// Crate name to member paths, in each crate's own order. The Prep Crate
    /// is not in here: it is not a crate the assistant may write.
    public private(set) var crates: [String: [String]]
    public private(set) var crateNames: [String]
    public private(set) var prepCratePaths: [String]
    public private(set) var playlists: [Playlist]
    public private(set) var streams: [StreamSource]

    private var indexByID: [UUID: Int]
    private var indexByPath: [String: Int]

    public static func build(_ input: AssistantLibraryInput) -> AssistantLibrary {
        var tracks: [AssistantTrack] = []
        var indexByPath: [String: Int] = [:]
        var loaded: [LoadedTrack] = []
        var crates: [String: [String]] = [:]

        func add(_ track: LoadedTrack, to crate: String) -> String {
            let path = TrackStore.key(for: track.track.fileURL)
            if let index = indexByPath[path] {
                if !tracks[index].crates.contains(crate) { tracks[index].crates.append(crate) }
            } else {
                indexByPath[path] = tracks.count
                loaded.append(track)
                tracks.append(AssistantTrack(
                    id: track.track.id,
                    path: path,
                    tags: AssistantTagValues(track),
                    durationSeconds: track.track.durationSeconds,
                    format: track.track.formatName,
                    albumKey: AlbumFolderKey(artistBucket: "", album: "", year: ""),
                    crates: [crate],
                    stats: input.stats[path]
                ))
            }
            return path
        }

        for (name, members) in input.crates {
            var paths: [String] = []
            for track in members {
                let path = add(track, to: name)
                if !paths.contains(path) { paths.append(path) }
            }
            crates[name] = paths
        }
        let prep = input.prepCrate.map { add($0, to: prepCrateName) }

        // The same album grouping as the browser and the converter, so "this
        // album" means one thing everywhere.
        let keys = OutputPathPlanner().albumFolderKeys(for: loaded)
        for index in tracks.indices {
            if let key = keys[tracks[index].id] { tracks[index].albumKey = key }
        }

        var indexByID: [UUID: Int] = [:]
        for (index, track) in tracks.enumerated() where indexByID[track.id] == nil {
            indexByID[track.id] = index
        }
        return AssistantLibrary(
            tracks: tracks, crates: crates, crateNames: input.crates.map(\.name),
            prepCratePaths: prep, playlists: input.playlists, streams: input.streams,
            indexByID: indexByID, indexByPath: indexByPath)
    }

    public func track(id: UUID) -> AssistantTrack? { indexByID[id].map { tracks[$0] } }
    public func track(path: String) -> AssistantTrack? { indexByPath[path].map { tracks[$0] } }

    /// The crate's name as the library spells it, matched without regard to
    /// case, or nil for a crate that doesn't exist.
    public func crateName(matching name: String) -> String? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return crateNames.first { $0.lowercased() == wanted }
    }

    public func isPrepCrate(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == Self.prepCrateName.lowercased()
    }

    public func playlist(matching name: String) -> Playlist? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return playlists.first { $0.name.lowercased() == wanted }
    }

    /// Member paths of a crate, or of the Prep Crate.
    public func members(ofCrate name: String) -> [String]? {
        if isPrepCrate(name) { return prepCratePaths }
        return crateName(matching: name).flatMap { crates[$0] }
    }
}

/// The ten tags a proposal can change, the same ten FIX TAGS edits. Kept apart
/// from `ConversionMetadata` so a proposal, the journal and an undo never
/// carry (or overwrite) artwork, comments or custom tags.
public struct AssistantTagValues: Codable, Sendable, Equatable {
    public var title: String?
    public var artist: String?
    public var albumArtist: String?
    public var album: String?
    public var year: Int?
    public var genre: String?
    public var trackNumber: Int?
    public var trackTotal: Int?
    public var discNumber: Int?
    public var discTotal: Int?

    public init(title: String? = nil, artist: String? = nil, albumArtist: String? = nil, album: String? = nil,
                year: Int? = nil, genre: String? = nil, trackNumber: Int? = nil, trackTotal: Int? = nil,
                discNumber: Int? = nil, discTotal: Int? = nil) {
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.year = year
        self.genre = genre
        self.trackNumber = trackNumber
        self.trackTotal = trackTotal
        self.discNumber = discNumber
        self.discTotal = discTotal
    }

    /// The tags a track carries now. `ConversionMetadata` is the editable set;
    /// a field it leaves empty falls back to what the scan read into the
    /// track, which is what the browser shows.
    public init(_ loaded: LoadedTrack) {
        let m = loaded.metadata
        let t = loaded.track
        self.init(
            title: Self.nonEmpty(m.title) ?? Self.nonEmpty(t.title),
            artist: Self.nonEmpty(m.artist) ?? Self.nonEmpty(t.artist),
            albumArtist: Self.nonEmpty(m.albumArtist),
            album: Self.nonEmpty(m.album) ?? Self.nonEmpty(t.album),
            year: m.year ?? t.year,
            genre: Self.nonEmpty(m.genre),
            trackNumber: m.trackNumber ?? t.trackNumber,
            trackTotal: m.trackTotal ?? t.trackTotal,
            discNumber: m.discNumber ?? t.discNumber,
            discTotal: m.discTotal ?? t.discTotal)
    }

    /// `metadata` with `fields` set from these values; every other field, and
    /// everything that isn't one of the ten (artwork, comment, custom tags,
    /// compilation), is left exactly as it was.
    ///
    /// Only the named fields, because `init(_:)` fills an empty tag from what
    /// the scan read (a title from the file name): writing all ten would put
    /// those into files that never carried them.
    ///
    /// The tag writer leaves a nil field alone and deletes an empty one, so a
    /// cleared text field is written as "". A number has no empty form there
    /// and can't be removed this way; `removableFields` is the test for that.
    public func applied(to metadata: ConversionMetadata, fields: [String]) -> ConversionMetadata {
        var m = metadata
        for field in fields {
            switch field {
            case "title": m.title = title ?? ""
            case "artist": m.artist = artist ?? ""
            case "album_artist": m.albumArtist = albumArtist ?? ""
            case "album": m.album = album ?? ""
            case "genre": m.genre = genre ?? ""
            case "year": if let year { m.year = year }
            case "track_number": if let trackNumber { m.trackNumber = trackNumber }
            case "track_total": if let trackTotal { m.trackTotal = trackTotal }
            case "disc_number": if let discNumber { m.discNumber = discNumber }
            case "disc_total": if let discTotal { m.discTotal = discTotal }
            default: break
            }
        }
        return m
    }

    /// Text fields can be emptied; numbers can only be changed (see `applied`).
    public static let removableFields: Set<String> = ["title", "artist", "album_artist", "album", "genre"]

    /// Tool field names, in `AssistantTool.tagFields` order.
    public static let fieldNames = ["title", "artist", "album_artist", "album", "year", "genre",
                                    "track_number", "track_total", "disc_number", "disc_total"]

    /// The field's value as text, for the review sheet; nil when empty.
    public func display(_ field: String) -> String? {
        switch field {
        case "title": return title
        case "artist": return artist
        case "album_artist": return albumArtist
        case "album": return album
        case "genre": return genre
        case "year": return year.map(String.init)
        case "track_number": return trackNumber.map(String.init)
        case "track_total": return trackTotal.map(String.init)
        case "disc_number": return discNumber.map(String.init)
        case "disc_total": return discTotal.map(String.init)
        default: return nil
        }
    }

    /// The fields whose value differs from `other`'s.
    public func changedFields(from other: AssistantTagValues) -> [String] {
        Self.fieldNames.filter { display($0) != other.display($0) }
    }

    /// Copies one field's value from `source`.
    public mutating func copy(_ field: String, from source: AssistantTagValues) {
        switch field {
        case "title": title = source.title
        case "artist": artist = source.artist
        case "album_artist": albumArtist = source.albumArtist
        case "album": album = source.album
        case "genre": genre = source.genre
        case "year": year = source.year
        case "track_number": trackNumber = source.trackNumber
        case "track_total": trackTotal = source.trackTotal
        case "disc_number": discNumber = source.discNumber
        case "disc_total": discTotal = source.discTotal
        default: break
        }
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

/// Tag edits the assistant proposed, waiting for the user in the review sheet.
public struct AssistantTagProposal: Identifiable, Sendable, Equatable {
    public struct Item: Identifiable, Sendable, Equatable {
        public var id: UUID { trackID }
        public var trackID: UUID
        public var displayTitle: String
        public var current: AssistantTagValues
        public var proposed: AssistantTagValues
        public var changedFields: [String]
    }

    public let id: UUID
    public var summary: String
    public var items: [Item]

    public init(id: UUID = UUID(), summary: String, items: [Item]) {
        self.id = id
        self.summary = summary
        self.items = items
    }
}
