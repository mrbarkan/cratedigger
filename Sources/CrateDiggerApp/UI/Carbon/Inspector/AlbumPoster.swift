import AppKit
import CrateDiggerCore
import SwiftUI

struct AlbumPoster: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel
    let album: Album?

    var body: some View {
        ZStack {
            if let album, let nsImage = thumbnail(for: album) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                GeneratedPoster(seed: album?.id ?? "empty")
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(Color.black.opacity(theme.isDark ? 0.6 : 0.18), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(theme.isDark ? 0.5 : 0.35), radius: 8, y: 6)
    }

    private func thumbnail(for album: Album) -> NSImage? {
        guard let hash = album.artworkHash else { return nil }
        return model.artworkService.generateThumbnail(artworkHash: hash, size: CGSize(width: 480, height: 480))
    }
}
