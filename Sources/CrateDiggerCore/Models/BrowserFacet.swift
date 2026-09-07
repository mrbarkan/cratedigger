import Foundation

/// A category a browser column can show.
///
/// A column is a grouping of the tracks that survive the columns to its left;
/// the facet is what it groups by. Artist, Album and Track resolve to the
/// index's own objects (rows keep their art and version groups); the rest
/// are plain value rows. The index itself stays Artist → Album → Track and
/// is used as a lookup, never as the shape of the browser.
public enum BrowserFacet: String, Codable, CaseIterable, Sendable {
    case artist
    case albumArtist
    case album
    case genre
    case year
    case decade
    case format
    case rating
    case track

    /// The column header.
    public var title: String {
        switch self {
        case .artist:      return "Artist"
        case .albumArtist: return "Album Artist"
        case .album:       return "Album"
        case .genre:       return "Genre"
        case .year:        return "Year"
        case .decade:      return "Decade"
        case .format:      return "Format"
        case .rating:      return "Rating"
        case .track:       return "Track"
        }
    }

    /// What this facet makes of one track: the key selection stores and the
    /// title the row draws. Keys for text facets are folded, so "rock" and
    /// "Rock" are one row; the title is whichever spelling the track has.
    public func value(of loaded: LoadedTrack, context: FacetContext) -> FacetValue {
        let track = loaded.track
        switch self {
        case .artist:
            let id = context.artistID(of: track.id) ?? ""
            return FacetValue(id: id, title: context.artistName(id) ?? track.artist)
        case .album:
            let id = context.albumID(of: track.id) ?? ""
            return FacetValue(id: id, title: context.albumTitle(id) ?? track.album)
        case .track:
            return FacetValue(id: track.id.uuidString, title: track.title)
        case .albumArtist:
            let name = loaded.metadata.albumArtist.flatMap(Self.nonBlank) ?? Self.nonBlank(track.artist)
            return Self.text(name, missing: "Unknown Album Artist")
        case .genre:
            // Decode first, then judge blankness: "17" is Rock, and so is the
            // two-byte MP4 atom that would otherwise read as nothing at all.
            return Self.text(loaded.metadata.genre.map(ID3Genre.name(for:)).flatMap(Self.nonBlank), missing: "No Genre")
        case .year:
            guard let year = track.year else { return FacetValue(id: "", title: "Unknown Year") }
            return FacetValue(id: String(year), title: String(year))
        case .decade:
            guard let year = track.year else { return FacetValue(id: "", title: "Unknown Decade") }
            let decade = year / 10 * 10
            return FacetValue(id: String(decade), title: "\(decade)s")
        case .format:
            let name = track.formatName.flatMap(Self.nonBlank) ?? track.fileURL.pathExtension.uppercased()
            return Self.text(Self.nonBlank(name), missing: "Unknown Format")
        case .rating:
            let stars = context.rating(of: track)
            guard stars > 0 else { return FacetValue(id: "0", title: "Unrated") }
            let filled = String(repeating: "★", count: min(stars, 5))
            let empty = String(repeating: "☆", count: max(0, 5 - stars))
            return FacetValue(id: String(stars), title: filled + empty)
        }
    }

    /// The key alone, for narrowing: what `value` computes without the title.
    public func key(of loaded: LoadedTrack, context: FacetContext) -> String {
        value(of: loaded, context: context).id
    }

    /// Nil for a tag that would draw as nothing: blank, a stray newline, a
    /// control character, a byte-order mark. Such a tag is a missing tag with
    /// extra steps, and must not become a row with a count and no name.
    private static func nonBlank(_ text: String) -> String? {
        let visible = text.unicodeScalars.contains { scalar in
            !(CharacterSet.whitespacesAndNewlines.contains(scalar)
              || CharacterSet.controlCharacters.contains(scalar)
              || scalar.properties.isDefaultIgnorableCodePoint)
        }
        return visible ? text : nil
    }

    private static func text(_ text: String?, missing: String) -> FacetValue {
        guard let text else { return FacetValue(id: "", title: missing) }
        return FacetValue(id: BrowserFilter.fold(text), title: text)
    }
}

/// One row of a value column: a facet key, what to call it, and how many
/// tracks sit under it after the cascade.
public struct FacetValue: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public var count: Int

    public init(id: String, title: String, count: Int = 0) {
        self.id = id
        self.title = title
        self.count = count
    }
}

/// What a facet needs beyond the track itself: where the index files it, and
/// what the listening store says about it. Built once per index and handed
/// to every facet call, so resolving a track to its album is a dictionary
/// lookup rather than a walk of the tree.
public struct FacetContext: Sendable {
    private let artistIDByTrack: [UUID: String]
    private let albumIDByTrack: [UUID: String]
    private let artistNames: [String: String]
    private let albumTitles: [String: String]
    private let topLevelAlbumByAlbum: [String: String]
    private let ratingByPath: [String: Int]

    /// - Parameter ratingByPath: `ListeningStats.rating` keyed by the track's
    ///   standardized path, the key the listening store uses. Missing means
    ///   unrated.
    public init(index: LibraryIndex, ratingByPath: [String: Int] = [:]) {
        var artistIDByTrack: [UUID: String] = [:]
        var albumIDByTrack: [UUID: String] = [:]
        var artistNames: [String: String] = [:]
        var albumTitles: [String: String] = [:]
        var topLevelAlbumByAlbum: [String: String] = [:]
        for artist in index.artists {
            artistNames[artist.id] = artist.name
            for album in artist.albums {
                albumTitles[album.id] = album.title
                topLevelAlbumByAlbum[album.id] = album.id
                // A track's album is its top-level album: a version member's
                // tracks file under the release, which is the row the browser
                // shows. Member ids stay meaningful for narrowing (see
                // BrowserCascade), just not as a track's own key.
                for loaded in album.tracks {
                    artistIDByTrack[loaded.track.id] = artist.id
                    albumIDByTrack[loaded.track.id] = album.id
                }
                for version in album.versions ?? [] {
                    albumTitles[version.id] = version.title
                    topLevelAlbumByAlbum[version.id] = album.id
                    for loaded in version.tracks {
                        artistIDByTrack[loaded.track.id] = artist.id
                        albumIDByTrack[loaded.track.id] = album.id
                    }
                }
            }
        }
        self.artistIDByTrack = artistIDByTrack
        self.albumIDByTrack = albumIDByTrack
        self.artistNames = artistNames
        self.albumTitles = albumTitles
        self.topLevelAlbumByAlbum = topLevelAlbumByAlbum
        self.ratingByPath = ratingByPath
    }

    public func artistID(of trackID: UUID) -> String? { artistIDByTrack[trackID] }
    public func albumID(of trackID: UUID) -> String? { albumIDByTrack[trackID] }
    func artistName(_ id: String) -> String? { artistNames[id] }
    func albumTitle(_ id: String) -> String? { albumTitles[id] }

    /// The row an album id lives under: itself for a top-level album, the
    /// release for a version member. Nil for an id the index does not know.
    public func topLevelAlbumID(forAlbumID id: String) -> String? { topLevelAlbumByAlbum[id] }

    func rating(of track: AudioTrack) -> Int {
        ratingByPath[track.fileURL.standardizedFileURL.path] ?? 0
    }
}
