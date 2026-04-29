import CrateDiggerCore
import SwiftUI

struct InspectorPane: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                AlbumPoster(album: model.selectedAlbum)
                    .padding(14)

                captionBlock

                SpecRows(album: model.selectedAlbum)

                TagChips(album: model.selectedAlbum)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var captionBlock: some View {
        let album = model.selectedAlbum
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(album?.title ?? "—")
                    .font(CarbonFont.sans(20, weight: .heavy))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Text(captionSubtitle(album))
                    .font(CarbonFont.mono(10, weight: .semibold))
                    .tracking(1.8)
                    .textCase(.uppercase)
                    .foregroundStyle(theme.ink2)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                trailingBadge(album: album)
                Text(serialIdentifier(album))
                    .font(CarbonFont.mono(9, weight: .medium))
                    .tracking(1.6)
                    .foregroundStyle(theme.ink3)
                    .textCase(.uppercase)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(
            Rectangle()
                .fill(theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.08))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    @ViewBuilder
    private func trailingBadge(album: Album?) -> some View {
        if let album, album.artworkHash == nil {
            fetchArtworkButton(for: album)
        } else {
            tapeLabel(text: tapeIdentifier(album))
        }
    }

    private func fetchArtworkButton(for album: Album) -> some View {
        let isLoading = model.isFetchingArtwork(for: album)
        let label = isLoading ? "FETCHING…" : "FETCH ART"
        return KeyButton(
            style: isLoading ? .disabled : .normal,
            action: { model.fetchRemoteArtwork(for: album) }
        ) {
            Text(label)
                .font(CarbonFont.mono(9, weight: .bold))
                .tracking(1.6)
        }
        .frame(width: 96, height: CarbonLayout.keyHeight)
        .help("Search iTunes for cover art for this album.")
    }

    private func captionSubtitle(_ album: Album?) -> String {
        guard let album else { return "Insert media" }
        let year = album.year.map(String.init) ?? ""
        let parts = [album.artistName, year].filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }

    private func tapeIdentifier(_ album: Album?) -> String {
        guard let album, let year = album.year else { return "REC" }
        return "LP-\(String(format: "%03d", year % 1000))"
    }

    private func serialIdentifier(_ album: Album?) -> String {
        let count = album?.trackCount ?? 0
        return "CD-LIB · \(String(format: "%07d", abs(album?.id.hashValue ?? 0) % 9_999_999))" + (count > 0 ? " · \(count) TRK" : "")
    }

    private func tapeLabel(text: String) -> some View {
        Text(text)
            .font(CarbonFont.mono(9, weight: .semibold))
            .tracking(1.8)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(theme.isDark ? theme.orange : theme.ink)
            .background(theme.isDark ? Color(hex: 0x1A1A18) : theme.chassisHi)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(theme.isDark ? theme.orange.opacity(0.3) : Color.black.opacity(0.15), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(theme.isDark ? 0.5 : 0.25), radius: 2, y: 2)
    }
}

