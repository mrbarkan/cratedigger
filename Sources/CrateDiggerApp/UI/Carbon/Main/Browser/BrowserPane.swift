import AppKit
import CrateDiggerCore
import SwiftUI

struct BrowserPane: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        VStack(spacing: 0) {
            // A device's own screen only: over a crate it was a bar about
            // somewhere you weren't. The orange dots carry the queue into the
            // rest of the browser instead.
            if let profile = model.browsedDeviceProfile {
                DeviceQueueBar(profile: profile)
            }
            if let cd = model.currentAudioCD {
                DiscIdentityBar(info: cd)
            }
            browserBody
        }
    }

    private var browserBody: some View {
        ZStack {
            HStack(spacing: 0) {
                columns
            }
            if shouldShowEmptyState {
                BrowserEmptyState()
                    .transition(.opacity)
            } else if shouldShowNoMatches {
                BrowserNoMatchesState()
                    .transition(.opacity)
            }
        }
    }

    /// One pane per column of the view, in order. Artist, Album and Track
    /// keep their own panes (rows with art, version groups, the table); every
    /// other facet is a `FacetPane` of plain rows.
    @ViewBuilder
    private var columns: some View {
        ForEach(Array(model.browserView.facets.enumerated()), id: \.offset) { column, facet in
            if column > 0 { divider }
            pane(for: facet, column: column).frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func pane(for facet: BrowserFacet, column: Int) -> some View {
        switch facet {
        case .artist: ArtistPane(column: column)
        case .album:  AlbumPane(column: column)
        case .track:  TrackPane(column: column)
        default:      FacetPane(column: column, facet: facet)
        }
    }

    /// Nothing scanned yet. "Nothing matched" is a different state entirely —
    /// the library is fine, so it must not offer OPEN FOLDER.
    private var shouldShowEmptyState: Bool {
        model.index.allTracks.isEmpty && !model.scanProgress.isRunning
    }

    private var shouldShowNoMatches: Bool {
        !model.index.allTracks.isEmpty && model.isSearchActive && model.browsedIndex.allTracks.isEmpty
    }

    private var divider: some View {
        Rectangle()
            .fill(theme.isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.08))
            .frame(width: 1)
    }
}

private struct BrowserEmptyState: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(theme.ink3)
            Text("No library loaded")
                .font(CarbonFont.sans(18, weight: .heavy))
                .foregroundStyle(theme.ink)
            Text("Choose a folder of audio files to scan. CrateDigger will read tags, fetch artwork, and build the artist · album · track browser.")
                .font(CarbonFont.mono(11))
                .foregroundStyle(theme.ink3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            KeyButton(style: .glowingOrange, action: { model.openFolderViaPanel() }) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill.badge.plus")
                        .font(.system(size: 12, weight: .bold))
                    Text("OPEN FOLDER…")
                }
                .padding(.horizontal, 16)
            }
            .frame(width: 220, height: 38)
            Text("Or press \u{2318}O")
                .font(CarbonFont.mono(9.5))
                .foregroundStyle(theme.ink4)
                .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Rectangle()
                .fill(theme.paper) // opaque, not Material — see ChassisLayer
                .overlay(theme.paper.opacity(theme.isDark ? 0.70 : 0.78))
        )
    }
}

/// A search that matched nothing. Deliberately quieter than the no-library
/// state: nothing is wrong, there is just nothing here under this query.
private struct BrowserNoMatchesState: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(theme.ink3)
            Text("No matches for \u{201C}\(model.searchQuery)\u{201D}")
                .font(CarbonFont.sans(15, weight: .heavy))
                .foregroundStyle(theme.ink)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            KeyButton(style: .normal, action: { model.clearSearch() }) {
                Text("CLEAR SEARCH").padding(.horizontal, 14)
            }
            .frame(width: 160, height: 30)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Rectangle()
                .fill(theme.paper)
                .overlay(theme.paper.opacity(theme.isDark ? 0.70 : 0.78))
        )
    }
}

private struct ArtistPane: View {
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.carbon) private var theme
    let column: Int

    private var artists: [Artist] {
        if case .artists(let artists)? = model.browserColumns[safe: column] { return artists }
        return []
    }

    var body: some View {
        ColumnList(
            title: "Artist",
            trailing: String(format: "%02d", artists.count),
            titleMenu: AnyView(ColumnFacetMenu(column: column)),
            headerAccessory: model.showSortControls
                ? AnyView(ColumnSortControl(field: $model.artistSortField,
                                            ascending: $model.artistSortAscending,
                                            allCases: Array(ArtistSortField.allCases)))
                : nil,
            scrollTarget: model.selectedArtistID.map(AnyHashable.init),
            revealTick: model.revealTick,
            isFocused: model.effectiveColumn == column
        ) {
            ForEach(Array(artists.enumerated()), id: \.element.id) { row, artist in
                ArtistRow(
                    artist: artist,
                    selected: model.isArtistSelected(artist.id),
                    dragPayload: model.dragPayload(forArtist: artist),
                    isPlayingHere: isPlayingArtist(artist),
                    pendingSync: model.hasPendingSync(artist),
                    onSelect: {
                        let m = NSEvent.modifierFlags
                        model.focusedColumn = column
                        model.selectArtist(artist, command: m.contains(.command), shift: m.contains(.shift),
                                           ordered: artists)
                    },
                    onPrimaryAction: {
                        model.selectArtist(artist, command: false, shift: false, ordered: artists)
                    }
                )
                .contextMenu { BrowserContextMenu.artist(artist, model: model) }
                .browserStripe(row, theme)
            }
        }
    }

    private func isPlayingArtist(_ artist: Artist) -> Bool {
        guard let nowID = model.nowPlayingTrack?.track.id else { return false }
        return artist.albums.contains { album in
            album.tracks.contains { $0.track.id == nowID }
        }
    }
}

private struct AlbumPane: View {
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.carbon) private var theme
    let column: Int
    @State private var expandedReleaseIDs: Set<String> = []

    private var albums: [Album] {
        if case .albums(let albums)? = model.browserColumns[safe: column] { return albums }
        return []
    }

    var body: some View {
        ColumnList(
            title: "Album",
            trailing: String(format: "%02d", albums.count),
            titleMenu: AnyView(ColumnFacetMenu(column: column)),
            headerAccessory: model.showSortControls
                ? AnyView(ColumnSortControl(field: $model.albumSortField,
                                            ascending: $model.albumSortAscending,
                                            allCases: Array(AlbumSortField.allCases)))
                : nil,
            scrollTarget: model.selectedAlbumID.map(AnyHashable.init),
            revealTick: model.revealTick,
            isFocused: model.effectiveColumn == column
        ) {
            ForEach(Array(albums.enumerated()), id: \.element.id) { row, album in
                if album.isVersionGroup {
                    releaseRow(album)
                        .browserStripe(row, theme)
                    if expandedReleaseIDs.contains(album.id) {
                        ForEach(album.versions ?? []) { version in
                            versionRow(version, in: album)
                        }
                    }
                } else {
                    plainRow(album)
                        .browserStripe(row, theme)
                }
            }
        }
    }

    private func plainRow(_ album: Album) -> some View {
        AlbumRow(
            album: album,
            selected: model.isAlbumSelected(album.id),
            dragPayload: model.dragPayload(forAlbum: album),
            isPlayingHere: isPlayingAlbum(album),
            pendingSync: model.hasPendingSync(album),
            onSelect: {
                let m = NSEvent.modifierFlags
                model.focusedColumn = column
                model.selectAlbum(album, command: m.contains(.command), shift: m.contains(.shift),
                                  ordered: albums, flat: false)
            }
        )
        .contextMenu { BrowserContextMenu.album(album, model: model) }
    }

    /// Badge shown on a grouped release row, by group kind.
    private func releaseBadge(_ release: Album) -> String {
        let n = release.versions?.count ?? 0
        switch release.groupKind {
        case .boxSet:      return "\(n) disc\(n == 1 ? "" : "s")"
        case .compilation: return "V/A · \(n)"
        default:           return "\(n) ver"
        }
    }

    private func releaseRow(_ release: Album) -> some View {
        AlbumRow(
            album: release,
            selected: model.isAlbumSelected(release.id),
            dragPayload: model.dragPayload(forAlbum: release),
            isPlayingHere: isPlayingAlbum(release),
            pendingSync: model.hasPendingSync(release),
            onSelect: {
                let m = NSEvent.modifierFlags
                model.focusedColumn = column
                model.selectAlbum(release, command: m.contains(.command), shift: m.contains(.shift),
                                  ordered: albums, flat: false)
            },
            badge: releaseBadge(release),
            disclosed: expandedReleaseIDs.contains(release.id),
            onDisclose: {
                if expandedReleaseIDs.contains(release.id) {
                    expandedReleaseIDs.remove(release.id)
                } else {
                    expandedReleaseIDs.insert(release.id)
                }
            }
        )
        .contextMenu { BrowserContextMenu.release(release, model: model) }
    }

    private func versionRow(_ version: Album, in release: Album) -> some View {
        VersionSubRow(
            badge: VersionLabel.formatBadge(for: version),
            edition: version.editionLabel,
            mediaFormat: version.mediaFormat,
            selected: model.selectedAlbumID == version.id,
            onSelect: { model.focusedColumn = column; model.selectedAlbumID = version.id }
        )
        .contextMenu { BrowserContextMenu.version(version, release: release, model: model) }
    }

    private func isPlayingAlbum(_ album: Album) -> Bool {
        guard let nowID = model.nowPlayingTrack?.track.id else { return false }
        let pool = album.isVersionGroup
            ? (album.versions ?? []).flatMap { $0.tracks }
            : album.tracks
        return pool.contains { $0.track.id == nowID }
    }
}

private struct TrackPane: View {
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.carbon) private var theme
    let column: Int

    /// The sole column is the table: every track in the source, the user's
    /// chosen columns, sortable headers. Beside other columns it is the narrow
    /// list, the panes to its left having already said which artist and album.
    private var flat: Bool { model.browserView == .table }

    /// The table reads `flatTracks` so an unsorted playlist keeps its own
    /// order; every other Track column is the cascade's.
    private var sourceTracks: [LoadedTrack] {
        if flat { return model.flatTracks }
        if case .tracks(let tracks)? = model.browserColumns[safe: column] { return tracks }
        return []
    }

    /// Disc separators belong to an album: only under an Album column
    /// directly to the left, where the list is one record.
    private var followsAlbumColumn: Bool {
        column > 0 && model.browserView.facets[column - 1] == .album
    }

    /// A playlist shown in its own order can be rearranged by dragging; a sorted
    /// view of it can't, because the order on screen isn't the playlist's.
    private var isReorderable: Bool {
        flat && model.isPlaylistSource && !model.playlistSorted
    }

    var body: some View {
        ColumnList(
            title: "Track",
            trailing: trackTrailing,
            titleMenu: AnyView(ColumnFacetMenu(column: column)),
            headerAccessory: (model.showSortControls && !flat)
                ? AnyView(ColumnSortControl(field: $model.trackSortField,
                                            ascending: $model.trackSortAscending,
                                            allCases: Array(TrackSortField.allCases)))
                : nil,
            // Sortable column headers replace the pane's sort control in the
            // flat layout — clicking the header you want is the whole point.
            subheader: flat
                ? AnyView(TrackTableHeader(columns: model.trackColumns, widths: [:]))
                : nil,
            scrollTarget: model.selectedTrackID.map(AnyHashable.init),
            revealTick: model.revealTick,
            isFocused: model.effectiveColumn == column
        ) {
            ForEach(Array(trackEntries.enumerated()), id: \.element.id) { row, entry in
                switch entry {
                case let .discHeader(disc, count):
                    DiscHeaderRow(disc: disc, count: count)
                        .browserStripe(row, theme)
                case let .track(loaded):
                    // The flat list is a table you scan across the whole library,
                    // so it renders the columns the user chose. The hierarchical
                    // layouts keep the compact row — the panes to their left
                    // already say which artist and album this is.
                    if flat {
                        TrackTableRow(
                            loaded: loaded,
                            columns: model.trackColumns,
                            widths: [:],
                            selected: model.isTrackSelected(loaded.track.id),
                            dragPayload: model.dragPayload(forTrack: loaded),
                            isPlaying: model.nowPlayingTrack?.track.id == loaded.track.id,
                            isOffline: model.isOffline(loaded),
                            isMissing: model.isMissing(loaded),
                            positionNumber: isReorderable
                                ? (sourceTracks.firstIndex { $0.track.id == loaded.track.id }.map { $0 + 1 })
                                : nil,
                            onReorderDrop: isReorderable
                                ? { items in model.movePlaylistTracks(dragItems: items, before: loaded) }
                                : nil,
                            onSelect: {
                                let m = NSEvent.modifierFlags
                                model.focusedColumn = column
                                model.selectTrack(loaded, command: m.contains(.command), shift: m.contains(.shift),
                                                  ordered: sourceTracks)
                            },
                            onActivate: { model.playTrack(id: loaded.track.id) }
                        )
                        .id(loaded.track.id)
                        .contextMenu { BrowserContextMenu.track(loaded, model: model) }
                        .browserStripe(row, theme)
                    } else {
                    TrackRow(
                        loaded: loaded,
                        selected: model.isTrackSelected(loaded.track.id),
                        dragPayload: model.dragPayload(forTrack: loaded),
                        isPlaying: model.nowPlayingTrack?.track.id == loaded.track.id,
                        isOffline: model.isOffline(loaded),
                        isMissing: model.isMissing(loaded),
                        isPendingSync: model.isPendingSync(loaded),
                        onSelect: {
                            let m = NSEvent.modifierFlags
                            model.focusedColumn = column
                            model.selectTrack(loaded, command: m.contains(.command), shift: m.contains(.shift),
                                              ordered: sourceTracks)
                        },
                        onActivate: { model.playTrack(id: loaded.track.id) }
                    )
                    .id(loaded.track.id)
                    .contextMenu { BrowserContextMenu.track(loaded, model: model) }
                    .browserStripe(row, theme)
                    }
                case let .recordTrack(parent, marker, number):
                    RecordSubTrackRow(
                        marker: marker,
                        number: number,
                        isCurrent: model.nowPlayingTrack?.track.id == parent.track.id
                            && model.currentRecordTrackIndex == number - 1,
                        onActivate: { model.playRecordTrack(parent: parent, markerIndex: number - 1) }
                    )
                    .browserStripe(row, theme)
                }
            }
        }
    }

    /// Track rows, with "DISC n" separators interleaved when the album spans
    /// multiple discs, and Record Divider sub-tracks listed under a divided file.
    private var trackEntries: [TrackListEntry] {
        let tracks = sourceTracks
        let multiDisc = followsAlbumColumn && model.selectedAlbum?.isMultiDisc == true && model.trackSortField == .trackNumber
        let counts = multiDisc
            ? Dictionary(grouping: tracks, by: { $0.track.discNumber ?? 1 }).mapValues(\.count)
            : [:]

        var entries: [TrackListEntry] = []
        var lastDisc: Int?
        for loaded in tracks {
            if multiDisc {
                let disc = loaded.track.discNumber ?? 1
                if disc != lastDisc {
                    entries.append(.discHeader(disc: disc, count: counts[disc] ?? 0))
                    lastDisc = disc
                }
            }
            entries.append(.track(loaded))
            // A divided record lists its discovered tracks as indented sub-rows.
            for (i, marker) in (loaded.recordMarkers ?? []).enumerated() {
                entries.append(.recordTrack(parent: loaded, marker: marker, number: i + 1))
            }
        }
        return entries
    }

    private var trackTrailing: String {
        let count = sourceTracks.count
        // What is listed, not the album's whole: under a Genre column the
        // list is the record's rock tracks, and the header should say so.
        let total = sourceTracks.reduce(0) { $0 + $1.track.durationSeconds }
        guard count > 0 else { return "—" }
        let minutes = Int(total) / 60
        let seconds = Int(total) % 60
        return String(format: "%02d / %02d:%02d", count, minutes, seconds)
    }
}

/// A column of plain value rows — genre, year, decade, format, album artist,
/// rating. One row per distinct value among the tracks surviving the columns
/// to its left, with how many of them sit under it.
private struct FacetPane: View {
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.carbon) private var theme
    let column: Int
    let facet: BrowserFacet

    private var values: [FacetValue] {
        if case .values(let values)? = model.browserColumns[safe: column] { return values }
        return []
    }

    var body: some View {
        ColumnList(
            title: facet.title,
            trailing: String(format: "%02d", values.count),
            titleMenu: AnyView(ColumnFacetMenu(column: column)),
            headerAccessory: model.showSortControls
                ? AnyView(ColumnSortControl(field: $model.valueSortField,
                                            ascending: $model.valueSortAscending,
                                            allCases: Array(ValueSortField.allCases)))
                : nil,
            scrollTarget: model.browser.selection.anchor(column).map(AnyHashable.init),
            revealTick: model.revealTick,
            isFocused: model.effectiveColumn == column
        ) {
            ForEach(Array(values.enumerated()), id: \.element.id) { row, value in
                FacetRow(
                    value: value,
                    selected: model.browser.isSelected(column: column, id: value.id),
                    dragPayload: "facet::\(column)::" + value.id,
                    onSelect: {
                        let m = NSEvent.modifierFlags
                        model.focusedColumn = column
                        model.browser.select(column: column, id: value.id,
                                             command: m.contains(.command), shift: m.contains(.shift),
                                             ordered: values.map(\.id))
                    },
                    onActivate: {
                        model.browser.select(column: column, id: value.id, command: false, shift: false,
                                             ordered: values.map(\.id))
                        model.playBrowsingTracks()
                    }
                )
                .id(value.id)
                .contextMenu {
                    // Resolved on open, not per row: a genre can hold thousands.
                    let tracks = model.tracks(under: column, id: value.id)
                    BrowserContextMenu.queueButtons(for: tracks, model: model)
                    BrowserContextMenu.moveToCrateMenu(for: tracks, model: model)
                    BrowserContextMenu.transferToDeviceMenu(for: tracks, model: model)
                    BrowserContextMenu.showInFinderButton(for: tracks)
                }
                .browserStripe(row, theme)
            }
        }
    }
}

/// A column header that is also the menu for what the column shows. Every
/// facet is listed; choices that would break a rule — a facet already in
/// another column, Track anywhere but last — are greyed, not hidden, so the
/// list reads the same in every column.
private struct ColumnFacetMenu: View {
    @EnvironmentObject private var model: LibraryViewModel
    let column: Int

    var body: some View {
        Menu {
            ForEach(BrowserFacet.allCases, id: \.self) { facet in
                Button {
                    model.setFacet(facet, column: column)
                } label: {
                    if model.browserView.facets[safe: column] == facet {
                        Label(facet.title, systemImage: "checkmark")
                    } else {
                        Text(facet.title)
                    }
                }
                .disabled(!model.browserView.canReplace(column: column, with: facet))
            }
        } label: {
            HStack(spacing: 4) {
                // Set here, not inherited: a Menu's label on macOS ignores the
                // font its row applies, and came out in 13pt system type next
                // to the header's 8.5pt mono.
                Text((model.browserView.facets[safe: column]?.title ?? "").uppercased())
                    .font(CarbonFont.mono(8.5, weight: .semibold))
                    .tracking(2.2)
                Image(systemName: "chevron.down")
                    .font(.system(size: 6, weight: .bold))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .carbonTip("What this column shows")
    }
}

/// A row in the track column: a disc separator, an actual track, or a Record
/// Divider sub-track listed beneath its (divided) parent file.
private enum TrackListEntry: Identifiable {
    case discHeader(disc: Int, count: Int)
    case track(LoadedTrack)
    case recordTrack(parent: LoadedTrack, marker: RecordMarker, number: Int)

    var id: String {
        switch self {
        case let .discHeader(disc, _): return "disc-\(disc)"
        case let .track(loaded): return "track-\(loaded.track.id.uuidString)"
        case let .recordTrack(parent, _, number): return "rtrack-\(parent.track.id.uuidString)-\(number)"
        }
    }
}

/// An indented Record Divider sub-track under a divided file. Double-click plays
/// the file from this track's start; the currently-playing one is highlighted.
private struct RecordSubTrackRow: View {
    @Environment(\.carbon) private var theme
    let marker: RecordMarker
    let number: Int
    let isCurrent: Bool
    let onActivate: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isCurrent ? "play.fill" : "music.note")
                .font(.system(size: 8))
                .foregroundStyle(isCurrent ? theme.orange : theme.ink4)
                .frame(width: 14)
            Text(String(format: "%02d", number))
                .font(CarbonFont.mono(8.5))
                .foregroundStyle(theme.ink4)
            Text(marker.title)
                .font(CarbonFont.sans(11, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? theme.orange : theme.ink2)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(durationString(marker.durationSeconds))
                .font(CarbonFont.mono(8.5))
                .foregroundStyle(theme.ink4)
        }
        .padding(.leading, 30)
        .padding(.trailing, 12)
        .padding(.vertical, 3)
        .background(isCurrent ? theme.orange.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onActivate)
        .carbonTip("Double-click to play from here")
    }

    private func durationString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        return seconds.asClock
    }
}

/// Thin "DISC n" separator shown between discs of a multi-disc album.
private struct DiscHeaderRow: View {
    @Environment(\.carbon) private var theme
    let disc: Int
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "opticaldisc")
                .font(.system(size: 9))
            Text("DISC \(disc)")
                .font(CarbonFont.mono(8.5, weight: .bold))
                .tracking(2)
            Spacer()
            Text(String(format: "%02d", count))
                .font(CarbonFont.mono(8.5, weight: .semibold))
        }
        .foregroundStyle(theme.ink3)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.06))
        .overlay(
            Rectangle()
                .fill(theme.isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.06))
                .frame(height: 1),
            alignment: .bottom
        )
    }
}

/// Compact, reusable sort control for a column header: a small mono field-name
/// label (so it matches the header type exactly) plus an icon-only menu. The
/// field name lives OUTSIDE the menu so its font is never overridden by the
/// menu's button styling.
private struct ColumnSortControl<Field: SortFieldDisplayable>: View {
    @Environment(\.carbon) private var theme
    @Binding var field: Field
    @Binding var ascending: Bool
    let allCases: [Field]

    var body: some View {
        // The current field + direction now read out in the OLED lower zone; the
        // header keeps only this toggle so the column stays uncluttered.
        Menu {
            ForEach(Array(allCases.enumerated()), id: \.offset) { _, option in
                Button { select(option) } label: {
                    if option == field {
                        Label(
                            option.displayName,
                            systemImage: ascending ? "chevron.up" : "chevron.down"
                        )
                    } else {
                        Text(option.displayName)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(theme.ink3)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .controlSize(.small)
        .fixedSize()
        .carbonTip("Sort")
    }

    /// Tapping the current field flips direction; tapping another switches to it
    /// ascending. Mirrors the per-column behaviour the wrappers used to inline.
    private func select(_ option: Field) {
        if field == option {
            ascending.toggle()
        } else {
            field = option
            ascending = true
        }
    }
}
