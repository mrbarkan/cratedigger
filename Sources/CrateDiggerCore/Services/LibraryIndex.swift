import Foundation

/// A sort field that can be shown in a menu.
public protocol SortFieldDisplayable: Hashable {
    var displayName: String { get }
}

/// User-selectable ordering for the track list. The canonical album order used
/// when building the index is always `.trackNumber` (disc-aware); this enum lets
/// the browser re-sort what it displays without rebuilding the index.
public enum TrackSortField: String, CaseIterable, Codable, Sendable, SortFieldDisplayable {
    case trackNumber
    case title
    case artist
    case duration

    public var displayName: String {
        switch self {
        case .trackNumber: return "Track #"
        case .title:       return "Title"
        case .artist:      return "Artist"
        case .duration:    return "Duration"
        }
    }
}

/// User-selectable ordering for the artist column.
public enum ArtistSortField: String, CaseIterable, Codable, Sendable, SortFieldDisplayable {
    case name
    case albumCount

    public var displayName: String {
        switch self {
        case .name:       return "Name"
        case .albumCount: return "Albums"
        }
    }
}

/// User-selectable ordering for the album column.
public enum AlbumSortField: String, CaseIterable, Codable, Sendable, SortFieldDisplayable {
    case year
    case title
    case albumArtist

    public var displayName: String {
        switch self {
        case .year:        return "Year"
        case .title:       return "Title"
        case .albumArtist: return "Album Artist"
        }
    }
}

public struct LibraryIndex: Sendable {
    public let artists: [Artist]
    public let allTracks: [LoadedTrack]
    public let albumCount: Int
    public let totalSizeBytes: Int64

    public init(
        artists: [Artist],
        allTracks: [LoadedTrack],
        albumCount: Int,
        totalSizeBytes: Int64
    ) {
        self.artists = artists
        self.allTracks = allTracks
        self.albumCount = albumCount
        self.totalSizeBytes = totalSizeBytes
    }

    public static let empty = LibraryIndex(
        artists: [],
        allTracks: [],
        albumCount: 0,
        totalSizeBytes: 0
    )

    /// Build an `Artist → Album → Track` index from a flat array of loaded tracks.
    /// Grouping keys reuse `OutputPathPlanner.albumFolderKey(for:)` so the inspector,
    /// conversion folder review, and library browser all agree on what an album is.
    /// Pass `groups` to fold member albums into a single synthesised release album.
    public static func build(from loaded: [LoadedTrack],
                             groups: [AlbumGroup] = [],
                             diskCache: LibraryIndexDiskCache? = nil) -> LibraryIndex {
        guard !loaded.isEmpty else { return .empty }

        let planner = OutputPathPlanner()

        // Group by tag identity AND source folder: two same-tagged rips in
        // different folders are different pressings, not one album. Disc-like
        // subfolders (CD1, Disc 2) normalize to their parent so a multi-disc
        // album stored as subfolders never splits into fake versions.
        struct BuildKey: Hashable {
            let tagKey: AlbumFolderKey
            let folder: String
        }
        var groupsByKey: [BuildKey: [LoadedTrack]] = [:]
        var buildOrder: [BuildKey] = []
        for track in loaded {
            let key = BuildKey(
                tagKey: planner.albumFolderKey(for: track),
                folder: versionSourceFolder(for: track)
            )
            if groupsByKey[key] == nil {
                buildOrder.append(key)
            }
            groupsByKey[key, default: []].append(track)
        }

        // Same tag identity across several folders → assign each folder a
        // discriminator so every pressing is a distinct album. The first folder
        // (sorted, for determinism across rescans) keeps discriminator nil, so
        // single-copy libraries — and every AlbumFolderKey persisted before this
        // existed — keep their classic identity.
        var foldersByTagKey: [AlbumFolderKey: [String]] = [:]
        for key in buildOrder {
            foldersByTagKey[key.tagKey, default: []].append(key.folder)
        }
        var discriminatorByBuildKey: [BuildKey: String?] = [:]
        for (tagKey, folders) in foldersByTagKey {
            let sorted = folders.sorted()
            for (position, folder) in sorted.enumerated() {
                let label: String?
                if position == 0 {
                    label = nil
                } else {
                    let name = URL(fileURLWithPath: folder).lastPathComponent
                    label = name.isEmpty ? "v\(position + 1)" : "\(name) · v\(position + 1)"
                }
                discriminatorByBuildKey[BuildKey(tagKey: tagKey, folder: folder)] = label
            }
        }

        var insertionOrder: [AlbumFolderKey] = []
        var tracksByFullKey: [AlbumFolderKey: [LoadedTrack]] = [:]
        for buildKey in buildOrder {
            let fullKey = buildKey.tagKey.discriminated(discriminatorByBuildKey[buildKey] ?? nil)
            insertionOrder.append(fullKey)
            tracksByFullKey[fullKey] = groupsByKey[buildKey]
        }

        var albumsByArtistID: [String: [Album]] = [:]
        var artistDisplayName: [String: String] = [:]
        var albumByKey: [AlbumFolderKey: Album] = [:]
        var albumIDUses: [String: Int] = [:]

        for key in insertionOrder {
            guard let tracks = tracksByFullKey[key], let representative = tracks.first else { continue }

            let artistName = key.artistBucket
            let artistID = normalizedID(artistName)
            artistDisplayName[artistID] = artistName

            let albumTitle = key.album
            let year = parseYear(key.year)
            var albumID = "\(artistID)::\(normalizedID(albumTitle))::\(key.year)"
            if let discriminator = key.discriminator {
                albumID += "::\(normalizedID(discriminator))"
            }
            // Two distinct albums must never share an id — titles differing only
            // by case normalize identically, and SwiftUI ForEach renders a
            // duplicated id as one real row plus a blank ghost row (and matches
            // selection against both). Suffix any repeat to keep ids unique.
            let uses = (albumIDUses[albumID] ?? 0) + 1
            albumIDUses[albumID] = uses
            if uses > 1 { albumID += "::\(uses)" }

            let sortedTracks = sortTracks(tracks)
            let artworkHash = sortedTracks
                .compactMap { $0.track.artworkHash }
                .first ?? representative.track.artworkHash

            let booklet: AlbumBooklet?
            let mediaFormat: MediaFormat?
            if representative.track.fileURL.isFileURL {
                let albumFolder = representative.track.fileURL.deletingLastPathComponent()
                if let cached = diskCache?.albumInfo[albumFolder.path] {
                    booklet = cached.booklet
                    mediaFormat = cached.mediaFormat
                } else {
                    let manifest = ArtworkManifest.load(from: albumFolder)
                    booklet = AlbumBooklet.scan(in: albumFolder, manifest: manifest)
                    mediaFormat = manifest?.mediaFormat
                    diskCache?.albumInfo[albumFolder.path] = AlbumDiskInfo(booklet: booklet, mediaFormat: mediaFormat)
                }
            } else {
                booklet = nil
                mediaFormat = nil
            }

            let album = Album(
                id: albumID,
                artistID: artistID,
                artistName: artistName,
                title: albumTitle,
                year: year,
                artworkHash: artworkHash,
                tracks: sortedTracks,
                booklet: booklet,
                mediaFormat: mediaFormat,
                folderKey: key
            )

            albumByKey[key] = album
            albumsByArtistID[artistID, default: []].append(album)
        }

        // Fold user-defined version groups: replace member pressings with one
        // synthesised "release" album that carries them in `versions`.
        if !groups.isEmpty {
            var consumed = Set<String>()
            var releasesByArtist: [String: [Album]] = [:]
            let variousArtistsID = normalizedID("Various Artists")
            for group in groups {
                let liveMembers: [Album] = group.members.compactMap { member in
                    albumByKey[member.key]?.with(editionLabel: member.editionLabel)
                }
                guard liveMembers.count >= 2 else { continue }
                let primary = albumByKey[group.primaryKey] ?? albumByKey[group.members.first!.key]
                guard let primary else { continue }
                for member in group.members {
                    if let a = albumByKey[member.key] { consumed.insert(a.id) }
                }

                // Track list + owning artist depend on the kind.
                let releaseTracks: [LoadedTrack]
                let releaseArtistID: String
                let releaseArtistName: String
                switch group.kind {
                case .versionGroup:
                    releaseTracks = primary.tracks                    // primary pressing only
                    releaseArtistID = primary.artistID
                    releaseArtistName = primary.artistName
                case .boxSet:
                    releaseTracks = liveMembers.flatMap { $0.tracks }  // all discs as one whole
                    releaseArtistID = primary.artistID
                    releaseArtistName = primary.artistName
                case .compilation:
                    releaseTracks = liveMembers.flatMap { $0.tracks }  // reunite under Various Artists
                    releaseArtistID = variousArtistsID
                    releaseArtistName = "Various Artists"
                    artistDisplayName[variousArtistsID] = "Various Artists"
                }

                let release = Album(
                    id: "group::\(group.id)",
                    artistID: releaseArtistID,
                    artistName: releaseArtistName,
                    title: group.name,
                    year: primary.year,
                    artworkHash: primary.artworkHash,
                    tracks: releaseTracks,
                    booklet: primary.booklet,
                    mediaFormat: primary.mediaFormat,
                    versions: liveMembers,
                    originalYear: group.originalYear,
                    groupKind: group.kind
                )
                releasesByArtist[releaseArtistID, default: []].append(release)
            }
            // Remove consumed member albums from EVERY artist (a compilation's members
            // can live under many different artists), then add the synthesised releases.
            if !consumed.isEmpty {
                for artistID in albumsByArtistID.keys {
                    albumsByArtistID[artistID] = albumsByArtistID[artistID]?.filter { !consumed.contains($0.id) }
                }
            }
            for (artistID, releases) in releasesByArtist {
                albumsByArtistID[artistID, default: []].append(contentsOf: releases)
            }
        }

        // Auto-detect box sets: 2+ album folders that share a box-named PARENT
        // folder (e.g. ".../Foo [10-CD Box Set]/Disc 1", ".../Disc 2") fold into one
        // box-set release. Ephemeral — recomputed each build so it mirrors the
        // folders; manual groups win (their members are already consumed above).
        // ponytail: single-artist assumption (uses the first member's artist); a
        // Various-Artists box would file under the first disc's artist.
        var albumsByParent: [String: [(name: String, album: Album)]] = [:]
        for (_, albums) in albumsByArtistID {
            for album in albums where album.versions == nil {
                guard let f = album.tracks.first?.track.fileURL, f.isFileURL else { continue }
                let parent = f.deletingLastPathComponent().deletingLastPathComponent()
                albumsByParent[parent.path, default: []].append((parent.lastPathComponent, album))
            }
        }
        var boxConsumed = Set<String>()
        var boxByArtist: [String: [Album]] = [:]
        for (parentPath, entries) in albumsByParent {
            guard entries.count >= 2, looksLikeBoxFolder(entries[0].name) else { continue }
            let members = entries.map(\.album)
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            let primary = members[0]
            members.forEach { boxConsumed.insert($0.id) }
            let year = members.compactMap(\.year).min()
            let release = Album(
                id: "boxauto::\(parentPath)",
                artistID: primary.artistID,
                artistName: primary.artistName,
                title: cleanedBoxName(entries[0].name),
                year: year,
                artworkHash: primary.artworkHash,
                tracks: members.flatMap { $0.tracks },          // all discs as one whole
                booklet: primary.booklet,
                mediaFormat: primary.mediaFormat,
                versions: members.map { $0.with(editionLabel: $0.title) },  // disc = its album title
                originalYear: year,
                groupKind: .boxSet
            )
            boxByArtist[primary.artistID, default: []].append(release)
        }
        if !boxConsumed.isEmpty {
            for artistID in albumsByArtistID.keys {
                albumsByArtistID[artistID] = albumsByArtistID[artistID]?.filter { !boxConsumed.contains($0.id) }
            }
            for (artistID, releases) in boxByArtist {
                albumsByArtistID[artistID, default: []].append(contentsOf: releases)
            }
        }

        let artists = albumsByArtistID
            .filter { !$0.value.isEmpty }   // artists fully consumed by a compilation/box vanish
            .map { (artistID, albums) -> Artist in
                Artist(
                    id: artistID,
                    name: artistDisplayName[artistID] ?? artistID,
                    albums: sortAlbums(albums)
                )
            }
            .sorted(by: artistOrdering)

        let albumCount = artists.reduce(0) { $0 + $1.albums.count }

        let totalBytes = computeTotalSizeBytes(loaded, cache: diskCache)

        return LibraryIndex(
            artists: artists,
            allTracks: loaded,
            albumCount: albumCount,
            totalSizeBytes: totalBytes
        )
    }

    private static func sortTracks(_ tracks: [LoadedTrack]) -> [LoadedTrack] {
        sortedTracks(tracks, by: .trackNumber, ascending: true)
    }

    /// Sort tracks by the given field. Every field falls back to the natural
    /// disc → track → title order to break ties, so the result is deterministic.
    /// Passing `ascending: false` reverses the whole comparison.
    public static func sortedTracks(
        _ tracks: [LoadedTrack],
        by field: TrackSortField,
        ascending: Bool = true
    ) -> [LoadedTrack] {
        let comparator = ascendingComparator(for: field)
        return tracks.sorted { lhs, rhs in
            ascending ? comparator(lhs, rhs) : comparator(rhs, lhs)
        }
    }

    /// The natural ordering used when building albums: disc, then track number,
    /// then title. Tracks missing a number sort to the end of their disc.
    private static func naturalOrder(_ lhs: LoadedTrack, _ rhs: LoadedTrack) -> Bool {
        let lDisc = lhs.track.discNumber ?? 1
        let rDisc = rhs.track.discNumber ?? 1
        if lDisc != rDisc { return lDisc < rDisc }

        let lTrack = lhs.track.trackNumber ?? Int.max
        let rTrack = rhs.track.trackNumber ?? Int.max
        if lTrack != rTrack { return lTrack < rTrack }

        return lhs.track.title.localizedCaseInsensitiveCompare(rhs.track.title) == .orderedAscending
    }

    private static func ascendingComparator(
        for field: TrackSortField
    ) -> (LoadedTrack, LoadedTrack) -> Bool {
        switch field {
        case .trackNumber:
            return naturalOrder
        case .title:
            return { lhs, rhs in
                let result = lhs.track.title.localizedCaseInsensitiveCompare(rhs.track.title)
                if result != .orderedSame { return result == .orderedAscending }
                return naturalOrder(lhs, rhs)
            }
        case .artist:
            return { lhs, rhs in
                let result = lhs.track.artist.localizedCaseInsensitiveCompare(rhs.track.artist)
                if result != .orderedSame { return result == .orderedAscending }
                return naturalOrder(lhs, rhs)
            }
        case .duration:
            return { lhs, rhs in
                if lhs.track.durationSeconds != rhs.track.durationSeconds {
                    return lhs.track.durationSeconds < rhs.track.durationSeconds
                }
                return naturalOrder(lhs, rhs)
            }
        }
    }

    private static func sortAlbums(_ albums: [Album]) -> [Album] {
        sortedAlbums(albums, by: .year, ascending: true)
    }

    /// Sort albums by year (nil last) or title; the other field breaks ties.
    public static func sortedAlbums(
        _ albums: [Album],
        by field: AlbumSortField,
        ascending: Bool = true
    ) -> [Album] {
        let comparator: (Album, Album) -> Bool
        switch field {
        case .year:
            comparator = { lhs, rhs in
                let l = lhs.originalYear ?? lhs.year
                let r = rhs.originalYear ?? rhs.year
                switch (l, r) {
                case let (lv?, rv?) where lv != rv: return lv < rv
                case (nil, _?): return false   // unknown year sorts last
                case (_?, nil): return true
                default: return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
            }
        case .title:
            comparator = { lhs, rhs in
                let result = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                if result != .orderedSame { return result == .orderedAscending }
                return (lhs.year ?? Int.max) < (rhs.year ?? Int.max)
            }
        case .albumArtist:
            comparator = { lhs, rhs in
                let result = lhs.artistName.localizedCaseInsensitiveCompare(rhs.artistName)
                if result != .orderedSame { return result == .orderedAscending }
                // Within one artist, group chronologically then by title.
                return (lhs.originalYear ?? lhs.year ?? Int.max) < (rhs.originalYear ?? rhs.year ?? Int.max)
            }
        }
        return albums.sorted { ascending ? comparator($0, $1) : comparator($1, $0) }
    }

    /// Sort artists by name (unknown last) or album count; name breaks ties.
    public static func sortedArtists(
        _ artists: [Artist],
        by field: ArtistSortField,
        ascending: Bool = true
    ) -> [Artist] {
        let comparator: (Artist, Artist) -> Bool
        switch field {
        case .name:
            comparator = artistOrdering
        case .albumCount:
            comparator = { lhs, rhs in
                if lhs.albums.count != rhs.albums.count { return lhs.albums.count < rhs.albums.count }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
        return artists.sorted { ascending ? comparator($0, $1) : comparator($1, $0) }
    }

    private static func artistOrdering(_ lhs: Artist, _ rhs: Artist) -> Bool {
        let lUnknown = isUnknownArtist(lhs.name)
        let rUnknown = isUnknownArtist(rhs.name)
        if lUnknown != rUnknown { return !lUnknown }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private static func isUnknownArtist(_ name: String) -> Bool {
        name.localizedCaseInsensitiveCompare("Unknown Artist") == .orderedSame
    }

    /// The source folder that defines which *pressing* a track belongs to: its
    /// parent directory, with disc-like folder names (CD1, Disc 2, DISK03, D1)
    /// normalized up to THEIR parent so a multi-disc album stored as subfolders
    /// stays one album. Empty for non-file URLs (remote/streaming tracks are
    /// never folder-split).
    static func versionSourceFolder(for track: LoadedTrack) -> String {
        guard track.track.fileURL.isFileURL else { return "" }
        var folder = track.track.fileURL.deletingLastPathComponent()
        if isDiscFolderName(folder.lastPathComponent) {
            folder = folder.deletingLastPathComponent()
        }
        return folder.standardizedFileURL.path
    }

    /// "CD1", "cd 2", "Disc 3", "DISK-04", "D2" — with or without separator.
    private static let discFolderPattern = try! NSRegularExpression(
        pattern: #"^(cd|disc|disk|d)[ ._-]*\d{1,3}$"#, options: [.caseInsensitive]
    )

    private static func isDiscFolderName(_ name: String) -> Bool {
        let range = NSRange(name.startIndex..., in: name)
        return discFolderPattern.firstMatch(in: name, options: [], range: range) != nil
    }

    private static func parseYear(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 4, let value = Int(trimmed) else { return nil }
        return value
    }

    private static func normalizedID(_ s: String) -> String {
        let stripped = s.applyingTransform(.stripDiacritics, reverse: false) ?? s
        return stripped
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a folder name signals a box set: "box set"/"boxset", or a disc/CD
    /// count paired with "box" (e.g. "[10-CD Box Set]", "5-Disc Box"), or "anthology".
    /// Deliberately conservative to avoid boxing ordinary artist/download folders.
    static func looksLikeBoxFolder(_ name: String) -> Bool {
        let n = name.lowercased()
        if n.contains("box set") || n.contains("boxset") || n.contains("anthology") { return true }
        let hasCount = n.range(of: #"\d+\s*[- ]?\s*(cd|disc)"#, options: .regularExpression) != nil
        return hasCount && n.contains("box")
    }

    /// A box-set display name from its folder name: drop a trailing "[…]" tag.
    static func cleanedBoxName(_ name: String) -> String {
        var s = name
        if let r = s.range(of: #"\s*\[[^\]]*\]\s*$"#, options: .regularExpression) {
            s.removeSubrange(r)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func computeTotalSizeBytes(_ tracks: [LoadedTrack], cache: LibraryIndexDiskCache?) -> Int64 {
        var total: Int64 = 0
        for track in tracks {
            let path = track.track.fileURL.path
            if let cached = cache?.sizeByPath[path] {
                total += cached
            } else if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                      let size = (attrs[.size] as? NSNumber)?.int64Value {
                // ponytail: a tag edit rewrites the file in place and shifts its
                // size by a few bytes; the cached value then goes slightly stale.
                // Fine for a header GB readout — invalidate via clear() if exact.
                cache?.sizeByPath[path] = size
                total += size
            }
        }
        return total
    }
}

/// Internal memo of `LibraryIndex.build`'s disk reads.
fileprivate struct AlbumDiskInfo {
    let booklet: AlbumBooklet?
    let mediaFormat: MediaFormat?
}

/// Process-local cache for the disk-derived parts of `LibraryIndex.build` —
/// per-folder album booklet/media-format and per-path file size. `build` runs
/// on every edit and source switch; without this each rebuild re-issued tens of
/// thousands of filesystem syscalls. Owned by `LibraryViewModel` (main actor)
/// and passed into `build`. Folder/path keys self-invalidate when files move or
/// are added, so the only explicit reset needed is `clear()` after an in-place
/// artwork/manifest edit (same folder, changed contents).
public final class LibraryIndexDiskCache {
    fileprivate var albumInfo: [String: AlbumDiskInfo] = [:]
    fileprivate var sizeByPath: [String: Int64] = [:]
    public init() {}
    public func clear() {
        albumInfo.removeAll()
        sizeByPath.removeAll()
    }

    /// Invalidate just one album's cached disk info (its booklet / media-format)
    /// and the sizes of the given files — for an in-place artwork/manifest edit
    /// that changed a folder's contents without moving paths. Lets the next
    /// rebuild reuse the warm cache for every other folder instead of the
    /// whole-library cold rebuild `clear()` forces.
    public func invalidate(albumFolderPath: String, filePaths: [String]) {
        albumInfo[albumFolderPath] = nil
        for path in filePaths { sizeByPath[path] = nil }
    }
}

public extension LibraryIndex {
    /// Every album across all artists, in artist order. Used by the browser's
    /// "Album · Track" layout, which lists albums regardless of artist.
    var allAlbums: [Album] { artists.flatMap { $0.albums } }

    func artist(id: String) -> Artist? { artists.first { $0.id == id } }
    func album(id: String) -> Album? {
        for artist in artists {
            if let match = artist.albums.first(where: { $0.id == id }) { return match }
        }
        return nil
    }

    /// Find a top-level album by id, or a member pressing nested inside a grouped
    /// release. Used so selecting a version sub-row resolves to that pressing.
    func albumOrVersion(id: String) -> Album? {
        for artist in artists {
            for album in artist.albums {
                if album.id == id { return album }
                if let v = album.versions?.first(where: { $0.id == id }) { return v }
            }
        }
        return nil
    }
}
