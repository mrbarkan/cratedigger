import CrateDiggerCore
import SwiftUI

struct BrowserPane: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                ArtistColumn()
                    .frame(maxWidth: .infinity)
                divider
                AlbumColumn()
                    .frame(maxWidth: .infinity)
                divider
                TrackColumn()
                    .frame(maxWidth: .infinity)
            }
            if shouldShowEmptyState {
                BrowserEmptyState()
                    .transition(.opacity)
            }
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
            headerAccessory: model.showSortControls ? AnyView(ArtistSortControl()) : nil
        ) {
            ForEach(model.visibleArtists) { artist in
                ArtistRow(
                    artist: artist,
                    selected: model.selectedArtistID == artist.id,
                    isPlayingHere: isPlayingArtist(artist),
                    onSelect: { selectArtist(artist) },
                    onPrimaryAction: { selectArtist(artist) }
                )
            }
        }
    }

    private func isPlayingArtist(_ artist: Artist) -> Bool {
        guard let nowID = model.nowPlayingTrack?.track.id else { return false }
        return artist.albums.contains { album in
            album.tracks.contains { $0.track.id == nowID }
        }
    }

    private func selectArtist(_ artist: Artist) {
        model.selectedArtistID = artist.id
        model.selectedAlbumID = artist.albums.first?.id
        model.selectedTrackID = artist.albums.first?.tracks.first?.track.id
    }
}

private struct AlbumColumn: View {
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        ColumnList(
            title: "Album",
            trailing: String(format: "%02d", model.selectedArtist?.albumCount ?? 0),
            headerAccessory: model.showSortControls ? AnyView(AlbumSortControl()) : nil
        ) {
            ForEach(model.visibleAlbums) { album in
                AlbumRow(
                    album: album,
                    selected: model.selectedAlbumID == album.id,
                    isPlayingHere: isPlayingAlbum(album),
                    onSelect: { selectAlbum(album) }
                )
                .contextMenu { albumContextMenu(album) }
            }
        }
    }

    @ViewBuilder
    private func albumContextMenu(_ album: Album) -> some View {
        switch model.currentSource {
        case .localCrate(let crateName):
            Button("Remove from “\(crateName)”") {
                model.removeAlbumFromCrate(album, crateName: crateName)
            }
            Divider()
            Button("Remove from Library…") {
                model.promptRemoveAlbumFromLibrary(album)
            }
        case .localAll, .prepCrate:
            Button("Remove from Library…") {
                model.promptRemoveAlbumFromLibrary(album)
            }
        default:
            EmptyView()
        }
    }

    private func isPlayingAlbum(_ album: Album) -> Bool {
        guard let nowID = model.nowPlayingTrack?.track.id else { return false }
        return album.tracks.contains { $0.track.id == nowID }
    }

    private func selectAlbum(_ album: Album) {
        model.selectedAlbumID = album.id
        model.selectedTrackID = album.tracks.first?.track.id
    }
}

private struct TrackColumn: View {
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        ColumnList(
            title: "Track",
            trailing: trackTrailing,
            headerAccessory: model.showSortControls ? AnyView(TrackSortControl()) : nil
        ) {
            ForEach(trackEntries) { entry in
                switch entry {
                case let .discHeader(disc, count):
                    DiscHeaderRow(disc: disc, count: count)
                case let .track(loaded):
                    TrackRow(
                        loaded: loaded,
                        selected: model.selectedTrackID == loaded.track.id,
                        isPlaying: model.nowPlayingTrack?.track.id == loaded.track.id,
                        onSelect: { model.selectedTrackID = loaded.track.id },
                        onActivate: { model.playTrack(id: loaded.track.id) }
                    )
                    .contextMenu { trackContextMenu(loaded) }
                }
            }
        }
    }

    @ViewBuilder
    private func trackContextMenu(_ loaded: LoadedTrack) -> some View {
        let hasMarkers = !(loaded.recordMarkers ?? []).isEmpty
        Button(hasMarkers ? "Edit Record Divider…" : "Record Divider…") {
            model.beginRecordDivider(for: loaded)
        }
        .disabled(!model.canRecordDivide(loaded))
        if hasMarkers {
            Button("Clear Track Markers") {
                model.clearRecordMarkers(for: loaded)
            }
        }
    }

    /// Track rows, with "DISC n" separators interleaved when the album spans
    /// multiple discs and is shown in the natural track-number order.
    private var trackEntries: [TrackListEntry] {
        let tracks = model.visibleTracks
        guard let album = model.selectedAlbum,
              album.isMultiDisc,
              model.trackSortField == .trackNumber else {
            return tracks.map { .track($0) }
        }
        let counts = Dictionary(grouping: tracks, by: { $0.track.discNumber ?? 1 })
            .mapValues(\.count)
        var entries: [TrackListEntry] = []
        var lastDisc: Int?
        for loaded in tracks {
            let disc = loaded.track.discNumber ?? 1
            if disc != lastDisc {
                entries.append(.discHeader(disc: disc, count: counts[disc] ?? 0))
                lastDisc = disc
            }
            entries.append(.track(loaded))
        }
        return entries
    }

    private var trackTrailing: String {
        let count = model.visibleTracks.count
        let total = model.selectedAlbum?.totalDurationSeconds ?? 0
        guard count > 0 else { return "—" }
        let minutes = Int(total) / 60
        let seconds = Int(total) % 60
        return String(format: "%02d / %02d:%02d", count, minutes, seconds)
    }
}

/// A row in the track column: either a disc separator or an actual track.
private enum TrackListEntry: Identifiable {
    case discHeader(disc: Int, count: Int)
    case track(LoadedTrack)

    var id: String {
        switch self {
        case let .discHeader(disc, _): return "disc-\(disc)"
        case let .track(loaded): return "track-\(loaded.track.id.uuidString)"
        }
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
    let current: Field
    let ascending: Bool
    let allCases: [Field]
    let select: (Field) -> Void

    var body: some View {
        HStack(spacing: 3) {
            Text(current.displayName.uppercased())
                .font(CarbonFont.mono(8, weight: .semibold))
                .tracking(1)
                .foregroundStyle(theme.ink2)
            Image(systemName: ascending ? "chevron.up" : "chevron.down")
                .font(.system(size: 6, weight: .bold))
                .foregroundStyle(theme.ink3)
            Menu {
                ForEach(Array(allCases.enumerated()), id: \.offset) { _, field in
                    Button { select(field) } label: {
                        if field == current {
                            Label(
                                field.displayName,
                                systemImage: ascending ? "chevron.up" : "chevron.down"
                            )
                        } else {
                            Text(field.displayName)
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
        .help("Sort")
    }
}

private struct ArtistSortControl: View {
    @EnvironmentObject private var model: LibraryViewModel
    var body: some View {
        ColumnSortControl(
            current: model.artistSortField,
            ascending: model.artistSortAscending,
            allCases: Array(ArtistSortField.allCases)
        ) { field in
            if model.artistSortField == field {
                model.artistSortAscending.toggle()
            } else {
                model.artistSortField = field
                model.artistSortAscending = true
            }
        }
    }
}

private struct AlbumSortControl: View {
    @EnvironmentObject private var model: LibraryViewModel
    var body: some View {
        ColumnSortControl(
            current: model.albumSortField,
            ascending: model.albumSortAscending,
            allCases: Array(AlbumSortField.allCases)
        ) { field in
            if model.albumSortField == field {
                model.albumSortAscending.toggle()
            } else {
                model.albumSortField = field
                model.albumSortAscending = true
            }
        }
    }
}

private struct TrackSortControl: View {
    @EnvironmentObject private var model: LibraryViewModel
    var body: some View {
        ColumnSortControl(
            current: model.trackSortField,
            ascending: model.trackSortAscending,
            allCases: Array(TrackSortField.allCases)
        ) { field in
            if model.trackSortField == field {
                model.trackSortAscending.toggle()
            } else {
                model.trackSortField = field
                model.trackSortAscending = true
            }
        }
    }
}
