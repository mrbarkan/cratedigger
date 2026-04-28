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
            theme.paper.opacity(theme.isDark ? 0.92 : 0.96)
        )
    }
}

private struct ArtistColumn: View {
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        ColumnList(
            title: "Artist",
            trailing: String(format: "%02d", model.index.artists.count)
        ) {
            ForEach(model.index.artists) { artist in
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
            trailing: String(format: "%02d", model.selectedArtist?.albumCount ?? 0)
        ) {
            ForEach(model.selectedArtist?.albums ?? []) { album in
                AlbumRow(
                    album: album,
                    selected: model.selectedAlbumID == album.id,
                    isPlayingHere: isPlayingAlbum(album),
                    onSelect: { selectAlbum(album) }
                )
            }
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
            trailing: trackTrailing
        ) {
            ForEach(model.visibleTracks) { loaded in
                TrackRow(
                    loaded: loaded,
                    selected: model.selectedTrackID == loaded.track.id,
                    isPlaying: model.nowPlayingTrack?.track.id == loaded.track.id,
                    onSelect: { model.selectedTrackID = loaded.track.id },
                    onActivate: { model.playTrack(id: loaded.track.id) }
                )
            }
        }
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
