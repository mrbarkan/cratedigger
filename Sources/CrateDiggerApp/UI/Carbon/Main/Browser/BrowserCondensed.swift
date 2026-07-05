import CrateDiggerCore
import SwiftUI

/// Compact "context" view of the browser shown when the Browser well is
/// collapsed — instead of a thin rotated-title rail, it keeps the user's
/// selection legible: a 2-line artist+album header and a clickable track
/// list. Useful while working the patch bay or staring at the inspector.
struct BrowserCondensed: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel
    let onExpand: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
                .background(theme.hair.opacity(0.7))
            trackList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Header (artist · album · expand chevron)

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.selectedArtist?.name ?? "—")
                        .font(CarbonFont.sans(13, weight: .heavy))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    Text(albumLine)
                        .font(CarbonFont.mono(9, weight: .semibold))
                        .tracking(1.6)
                        .foregroundStyle(theme.ink3)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                expandChevron
            }
            HStack(spacing: 6) {
                Text(stats)
                    .font(CarbonFont.mono(8.5, weight: .semibold))
                    .tracking(1.6)
                    .foregroundStyle(theme.ink4)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    private var expandChevron: some View {
        Button(action: onExpand) {
            ZStack {
                ChromeChassis(theme: theme, cornerRadius: 4)
                    .frame(width: 18, height: 14)
                Text("|‹")
                    .font(CarbonFont.mono(9, weight: .heavy))
                    .foregroundStyle(theme.ink2)
            }
        }
        .buttonStyle(.carbonHover)
        .carbonTip("Expand browser")
    }

    private var albumLine: String {
        guard let album = model.selectedAlbum else { return "Insert media" }
        if let year = album.year {
            return "\(album.title) · '\(String(format: "%02d", year % 100))"
        }
        return album.title
    }

    private var stats: String {
        let count = model.visibleTracks.count
        let total = model.selectedAlbum?.totalDurationSeconds ?? 0
        guard count > 0 else { return "—" }
        let m = Int(total) / 60
        let s = Int(total) % 60
        return String(format: "%02d TRK · %02d:%02d", count, m, s)
    }

    // MARK: - Track list

    private var trackList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(model.visibleTracks) { loaded in
                    trackRow(loaded)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func trackRow(_ loaded: LoadedTrack) -> some View {
        let track = loaded.track
        let isSelected = model.selectedTrackID == track.id
        let isPlaying = model.nowPlayingTrack?.track.id == track.id
        let textColor: Color = isSelected ? theme.selectionInk : theme.ink2
        return HStack(spacing: 6) {
            Text(String(format: "%02d", track.trackNumber ?? 0))
                .font(CarbonFont.mono(9, weight: .semibold))
                .foregroundStyle(isSelected ? theme.selectionInk.opacity(0.7) : theme.ink4)
                .frame(width: 22, alignment: .leading)
            Text(isPlaying ? "▸" : " ")
                .font(CarbonFont.mono(9, weight: .black))
                .foregroundStyle(isSelected ? theme.selectionInk : theme.orange)
                .frame(width: 8)
            Text(track.title)
                .font(CarbonFont.mono(10, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(rowBackground(isSelected: isSelected))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            model.playTrack(id: track.id)
        }
        .onTapGesture {
            model.selectedTrackID = track.id
        }
    }

    @ViewBuilder
    private func rowBackground(isSelected: Bool) -> some View {
        if isSelected {
            LinearGradient(
                colors: [theme.orange, theme.orangeLo],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            Color.clear
        }
    }
}
