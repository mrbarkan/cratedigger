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
    /// When true, list every album across all artists (the "Album · Track" layout).
    var flat: Bool = false

    private var albums: [Album] { flat ? model.allAlbumsSorted : model.visibleAlbums }

    var body: some View {
        ColumnList(
            title: "Album",
            trailing: String(format: "%02d", flat ? albums.count : (model.selectedArtist?.albumCount ?? 0)),
            headerAccessory: model.showSortControls ? AnyView(AlbumSortControl()) : nil
        ) {
            ForEach(albums) { album in
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
        if flat {
            model.selectAlbumFlat(album)
        } else {
            model.selectedAlbumID = album.id
            model.selectedTrackID = album.tracks.first?.track.id
        }
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

    @ViewBuilder
    private func trackContextMenu(_ loaded: LoadedTrack) -> some View {
        Button("Refresh Tags") {
            model.refreshTrackTags(loaded)
        }
        if !model.availableCrates.isEmpty {
            Menu("Add to Crate") {
                ForEach(model.availableCrates, id: \.self) { crate in
                    Button(crate) {
                        model.addItemsToCrate(["track::" + loaded.track.id.uuidString], crateName: crate)
                    }
                }
            }
        }
        Divider()
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

        switch model.currentSource {
        case .localCrate(let crateName):
            Divider()
            Button("Remove from “\(crateName)”") {
                model.removeTrackFromCrate(loaded, crateName: crateName)
            }
            Button("Remove from Library…") {
                model.promptRemoveTrackFromLibrary(loaded)
            }
        case .localAll, .prepCrate:
            Divider()
            Button("Remove from Library…") {
                model.promptRemoveTrackFromLibrary(loaded)
            }
        default:
            EmptyView()
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
        .help("Double-click to play from here")
    }

    private func durationString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
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
