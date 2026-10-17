import Foundation

/// The library assistant's tools: names, what the model is told about them,
/// and their argument schemas. Lives here, not in Core, because the helper
/// that Claude Desktop launches answers `tools/list` on its own, with the app
/// closed, and links only this target.
public enum AssistantTool: String, CaseIterable, Sendable {
    case libraryOverview = "library_overview"
    case searchTracks = "search_tracks"
    case listAlbums = "list_albums"
    case listeningHistory = "listening_history"
    case listStreams = "list_streams"
    case listChanges = "list_changes"
    case fileIntoCrates = "file_into_crates"
    case createPlaylist = "create_playlist"
    case addStreams = "add_streams"
    case undoLastChange = "undo_last_change"
    case proposeTagChanges = "propose_tag_changes"

    /// Search and album pages default to this many rows and never return
    /// more than `maximumLimit`, so one call can't flood the model's context.
    public static let defaultLimit = 100
    public static let maximumLimit = 500

    /// The ten tag fields a proposal can change, as the model names them.
    /// The same ten FIX TAGS edits.
    public static let tagFields = ["title", "artist", "album_artist", "album", "year", "genre",
                                   "track_number", "track_total", "disc_number", "disc_total"]
    public static let integerTagFields: Set<String> = ["year", "track_number", "track_total",
                                                       "disc_number", "disc_total"]

    public static let serverName = "cratedigger"

    public static let instructions = """
    You are connected to the user's CrateDigger music library on their Mac.

    - Tracks are identified by IDs. Get them from search_tracks or list_albums \
    and never invent one. File paths are never shown.
    - Start with library_overview to see the crates, genres and size.
    - Before a large reorganisation, show the user the plan (for example the \
    mood crates you would make and roughly what goes in each) and let them \
    choose before calling file_into_crates.
    - Do a whole job in one call: one file_into_crates for all the crates of \
    a sort, one create_playlist per playlist. Each call is one step the user \
    can undo from CrateDigger (Edit > Undo AI Change), or you can call \
    undo_last_change.
    - Tag edits are never written directly. propose_tag_changes opens a \
    review sheet in CrateDigger where the user ticks what to apply. Tell the \
    user to look at CrateDigger.
    - Results are paged: use limit and offset, and the total in each result.
    - Knowledge about music (genres, moods, reviews, similar artists, streams) \
    is yours. CrateDigger only knows what is in the library.
    """

    public var definition: MCPTool {
        switch self {
        case .libraryOverview:
            return MCPTool(
                name: rawValue, title: "Library overview",
                description: "Totals for the library, every crate and playlist with its track count, the most common genres, the year range and the file formats. Call this first.",
                inputSchema: Self.schema([:]), readOnly: true)
        case .searchTracks:
            return MCPTool(
                name: rawValue, title: "Search tracks",
                description: "Find tracks. Every filter is optional and they combine. Returns each track's ID, tags, crates, play count, rating and dates, plus the total number of matches.",
                inputSchema: Self.schema([
                    "query": Self.string("Words to match in title, artist, album artist, album or genre. Every word must match somewhere."),
                    "artist": Self.string("Artist or album artist contains this (case-insensitive)."),
                    "album": Self.string("Album contains this (case-insensitive)."),
                    "genre": Self.string("Genre contains this (case-insensitive)."),
                    "year_from": Self.integer("Earliest year, inclusive."),
                    "year_to": Self.integer("Latest year, inclusive."),
                    "crate": Self.string("Only tracks in this crate. \"Prep Crate\" is the staging area."),
                    "min_plays": Self.integer("Only tracks played at least this many times."),
                    "missing_tag": Self.enumeration(["genre", "year", "artist", "album_artist", "album", "track_number"],
                                                     "Only tracks where this tag is empty."),
                    "sort": Self.enumeration(["artist", "album", "title", "year", "plays", "last_played", "date_added"],
                                             "Order of the results. Default: artist, then album, then disc and track."),
                    "descending": Self.boolean("Reverse the sort."),
                    "limit": Self.integer("How many to return (default \(Self.defaultLimit), at most \(Self.maximumLimit))."),
                    "offset": Self.integer("How many matches to skip, for paging."),
                ]),
                readOnly: true)
        case .listAlbums:
            return MCPTool(
                name: rawValue, title: "List albums",
                description: "Albums as CrateDigger groups them, with album artist, year, every genre their tracks carry, play count and the IDs of their tracks. The quickest way to sort a crate by album.",
                inputSchema: Self.schema([
                    "crate": Self.string("Only albums with tracks in this crate."),
                    "query": Self.string("Words to match in the album title, album artist or genre."),
                    "sort": Self.enumeration(["artist", "title", "year", "plays"], "Default: album artist, then year."),
                    "limit": Self.integer("How many to return (default \(Self.defaultLimit), at most \(Self.maximumLimit))."),
                    "offset": Self.integer("How many to skip, for paging."),
                ]),
                readOnly: true)
        case .listeningHistory:
            return MCPTool(
                name: rawValue, title: "Listening history",
                description: "What the user plays most: top tracks, artists and albums with play counts.",
                inputSchema: Self.schema([
                    "window": Self.enumeration(["all_time", "this_year", "this_month"], "Default: all_time."),
                    "limit": Self.integer("How many of each (default 25, at most 100)."),
                ]),
                readOnly: true)
        case .listStreams:
            return MCPTool(
                name: rawValue, title: "List radio streams",
                description: "The YouTube streams saved in CrateDigger's Radio, with their kind (live, video, mix, playlist) and URL.",
                inputSchema: Self.schema([:]), readOnly: true)
        case .listChanges:
            return MCPTool(
                name: rawValue, title: "List changes",
                description: "The changes made through this assistant that can still be undone, newest first.",
                inputSchema: Self.schema([:]), readOnly: true)
        case .fileIntoCrates:
            return MCPTool(
                name: rawValue, title: "File into crates",
                description: "Add tracks to crates, creating any crate that does not exist. Only changes which crates list a track; audio files are not touched. With remove_from_crate, the filed tracks also leave that crate (a move). The whole call is one undoable step.",
                inputSchema: Self.schema([
                    "summary": Self.string("A few words for the undo menu, such as \"5 mood crates\"."),
                    "assignments": [
                        "type": "array",
                        "description": "One entry per crate.",
                        "items": Self.schema([
                            "crate": Self.string("Crate name. Created if missing. No / or :."),
                            "track_ids": Self.stringArray("Track IDs to add."),
                        ], required: ["crate", "track_ids"]),
                    ],
                    "remove_from_crate": Self.string("Optional. A crate the filed tracks should leave."),
                ], required: ["summary", "assignments"]),
                readOnly: false)
        case .createPlaylist:
            return MCPTool(
                name: rawValue, title: "Create playlist",
                description: "Make a playlist from track IDs, in the order given. Refuses an existing name unless replace is true. Undoable.",
                inputSchema: Self.schema([
                    "summary": Self.string("A few words for the undo menu."),
                    "name": Self.string("Playlist name. No / or :."),
                    "track_ids": Self.stringArray("Track IDs, in play order."),
                    "replace": Self.boolean("Replace a playlist with this name if there is one."),
                ], required: ["summary", "name", "track_ids"]),
                readOnly: false, destructive: true)
        case .addStreams:
            return MCPTool(
                name: rawValue, title: "Add radio streams",
                description: "Save YouTube links (live streams, videos, mixes, playlists, channels) to CrateDigger's Radio. Undoable.",
                inputSchema: Self.schema([
                    "summary": Self.string("A few words for the undo menu."),
                    "urls": Self.stringArray("YouTube URLs."),
                ], required: ["summary", "urls"]),
                readOnly: false)
        case .undoLastChange:
            return MCPTool(
                name: rawValue, title: "Undo last change",
                description: "Undo the newest change made through this assistant: crates, a playlist, streams, or tags the user applied from a proposal.",
                inputSchema: Self.schema([:]),
                readOnly: false, destructive: true)
        case .proposeTagChanges:
            var change: [String: JSONValue] = ["track_id": Self.string("The track to change.")]
            for field in Self.tagFields {
                change[field] = Self.integerTagFields.contains(field)
                    ? ["type": ["integer", "null"], "description": "New value, or null to clear it. Leave out to keep."]
                    : ["type": ["string", "null"], "description": "New value, or null to clear it. Leave out to keep."]
            }
            return MCPTool(
                name: rawValue, title: "Propose tag changes",
                description: "Propose tag edits. Nothing is written: CrateDigger opens a review sheet showing each track's tags before and after, and the user applies what they tick. Include only the fields that change. Fields: \(Self.tagFields.joined(separator: ", ")).",
                inputSchema: Self.schema([
                    "summary": Self.string("What this does, for the review sheet and the undo menu, such as \"One genre per album, in iTunes style\"."),
                    "changes": ["type": "array", "items": Self.schema(change, required: ["track_id"])],
                ], required: ["summary", "changes"]),
                readOnly: false)
        }
    }

    public static var catalog: [MCPTool] { allCases.map(\.definition) }

    // MARK: - Schema helpers

    static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "object", "properties": .object(properties)]
        if !required.isEmpty { schema["required"] = .array(required.map(JSONValue.string)) }
        return .object(schema)
    }

    static func string(_ description: String) -> JSONValue { ["type": "string", "description": .string(description)] }
    static func integer(_ description: String) -> JSONValue { ["type": "integer", "description": .string(description)] }
    static func boolean(_ description: String) -> JSONValue { ["type": "boolean", "description": .string(description)] }
    static func stringArray(_ description: String) -> JSONValue {
        ["type": "array", "items": ["type": "string"], "description": .string(description)]
    }
    static func enumeration(_ values: [String], _ description: String) -> JSONValue {
        ["type": "string", "enum": .array(values.map(JSONValue.string)), "description": .string(description)]
    }
}
