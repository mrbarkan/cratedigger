import AppKit
import CrateDiggerCore
import SwiftUI

struct BrowserPane: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                columns
            }
            if shouldShowEmptyState {
                BrowserEmptyState()
                    .transition(.opacity)
            }
        }
    }

    /// Column composition per the selected browser layout.
    @ViewBuilder
    private var columns: some View {
        switch model.browserLayout {
        case .full:
            ArtistColumn().frame(maxWidth: .infinity)
            divider
            AlbumColumn().frame(maxWidth: .infinity)
            divider
            TrackColumn().frame(maxWidth: .infinity)
        case .albumTrack:
            AlbumColumn(flat: true).frame(maxWidth: .infinity)
            divider
            TrackColumn().frame(maxWidth: .infinity)
        case .track:
            TrackColumn(flat: true).frame(maxWidth: .infinity)
        }
    }

    private var shouldShowEmptyState: Bool {
        model.index.allTracks.isEmpty && !model.scanProgress.isRunning
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
                        .font(CarbonFont.mono(10, weight: .bold))
                        .tracking(2)
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
                .fill(.regularMaterial)
                .overlay(theme.paper.opacity(theme.isDark ? 0.70 : 0.78))
        )
    }
}

private struct ArtistColumn: View {
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        ColumnList(
            title: "Artist",
            trailing: String(format: "%02d", model.index.artists.count),
            headerAccessory: model.showSortControls
                ? AnyView(ColumnSortControl(field: $model.artistSortField,
                                            ascending: $model.artistSortAscending,
                                            allCases: Array(ArtistSortField.allCases)))
                : nil,
            scrollTarget: model.selectedArtistID.map(AnyHashable.init)
        ) {
            ForEach(model.visibleArtists) { artist in
                ArtistRow(
                    artist: artist,
                    selected: model.isArtistSelected(artist.id),
                    isPlayingHere: isPlayingArtist(artist),
                    onSelect: {
                        let m = NSEvent.modifierFlags
                        model.focusedColumn = .artist
                        model.selectArtist(artist, command: m.contains(.command), shift: m.contains(.shift),
                                           ordered: model.visibleArtists)
                    },
                    onPrimaryAction: {
                        model.selectArtist(artist, command: false, shift: false, ordered: model.visibleArtists)
                    }
                )
                .contextMenu { BrowserContextMenu.artist(artist, model: model) }
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

private struct AlbumColumn: View {
    @EnvironmentObject private var model: LibraryViewModel
    /// When true, list every album across all artists (the "Album · Track" layout).
    var flat: Bool = false
    @State private var expandedReleaseIDs: Set<String> = []

    private var albums: [Album] { flat ? model.allAlbumsSorted : model.visibleAlbums }

    var body: some View {
        ColumnList(
            title: "Album",
            trailing: String(format: "%02d", flat ? albums.count : (model.selectedArtist?.albumCount ?? 0)),
            headerAccessory: model.showSortControls
                ? AnyView(ColumnSortControl(field: $model.albumSortField,
                                            ascending: $model.albumSortAscending,
                                            allCases: Array(AlbumSortField.allCases)))
                : nil,
            scrollTarget: model.selectedAlbumID.map(AnyHashable.init)
        ) {
            ForEach(albums) { album in
                if album.isVersionGroup {
                    releaseRow(album)
                    if expandedReleaseIDs.contains(album.id) {
                        ForEach(album.versions ?? []) { version in
                            versionRow(version, in: album)
                        }
                    }
                } else {
                    plainRow(album)
                }
            }
        }
    }

    private func plainRow(_ album: Album) -> some View {
        AlbumRow(
            album: album,
            selected: model.isAlbumSelected(album.id),
            isPlayingHere: isPlayingAlbum(album),
            onSelect: {
                let m = NSEvent.modifierFlags
                model.focusedColumn = .album
                model.selectAlbum(album, command: m.contains(.command), shift: m.contains(.shift),
                                  ordered: albums, flat: flat)
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
            isPlayingHere: isPlayingAlbum(release),
            onSelect: {
                let m = NSEvent.modifierFlags
                model.focusedColumn = .album
                model.selectAlbum(release, command: m.contains(.command), shift: m.contains(.shift),
                                  ordered: albums, flat: flat)
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
            selected: model.selectedAlbumID == version.id,
            onSelect: { model.focusedColumn = .album; model.selectedAlbumID = version.id }
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

private struct TrackColumn: View {
    @EnvironmentObject private var model: LibraryViewModel
    /// When true, list every track in the source flat (the "Track" layout) — no
    /// album scoping and no disc-header separators.
    var flat: Bool = false

    private var sourceTracks: [LoadedTrack] {
        flat ? model.flatTracksSorted : model.visibleTracks
    }

    var body: some View {
        ColumnList(
            title: "Track",
            trailing: trackTrailing,
            headerAccessory: model.showSortControls
                ? AnyView(ColumnSortControl(field: $model.trackSortField,
                                            ascending: $model.trackSortAscending,
                                            allCases: Array(TrackSortField.allCases)))
                : nil,
            scrollTarget: model.selectedTrackID.map(AnyHashable.init)
        ) {
            ForEach(trackEntries) { entry in
                switch entry {
                case let .discHeader(disc, count):
                    DiscHeaderRow(disc: disc, count: count)
                case let .track(loaded):
                    TrackRow(
                        loaded: loaded,
                        selected: model.isTrackSelected(loaded.track.id),
                        isPlaying: model.nowPlayingTrack?.track.id == loaded.track.id,
                        isOffline: model.isOffline(loaded),
                        onSelect: {
                            let m = NSEvent.modifierFlags
                            model.focusedColumn = .track
                            model.selectTrack(loaded, command: m.contains(.command), shift: m.contains(.shift),
                                              ordered: sourceTracks)
                        },
                        onActivate: { model.playTrack(id: loaded.track.id) }
                    )
                    .id(loaded.track.id)
                    .contextMenu { BrowserContextMenu.track(loaded, model: model) }
                case let .recordTrack(parent, marker, number):
                    RecordSubTrackRow(
                        marker: marker,
                        number: number,
                        isCurrent: model.nowPlayingTrack?.track.id == parent.track.id
                            && model.currentRecordTrackIndex == number - 1,
                        onActivate: { model.playRecordTrack(parent: parent, markerIndex: number - 1) }
                    )
                }
            }
        }
    }

    /// Track rows, with "DISC n" separators interleaved when the album spans
    /// multiple discs, and Record Divider sub-tracks listed under a divided file.
    private var trackEntries: [TrackListEntry] {
        let tracks = sourceTracks
        let multiDisc = !flat && model.selectedAlbum?.isMultiDisc == true && model.trackSortField == .trackNumber
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
        let total = flat
            ? sourceTracks.reduce(0) { $0 + $1.track.durationSeconds }
            : (model.selectedAlbum?.totalDurationSeconds ?? 0)
        guard count > 0 else { return "—" }
        let minutes = Int(total) / 60
        let seconds = Int(total) % 60
        return String(format: "%02d / %02d:%02d", count, minutes, seconds)
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
        HStack(spacing: 6) {
            // Field name + direction caret read as one unit; the menu sits apart.
            HStack(spacing: 3) {
                Text(field.displayName.uppercased())
                    .font(CarbonFont.mono(8, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(theme.ink2)
                Image(systemName: ascending ? "chevron.up" : "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(theme.ink3)
            }
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
        }
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
