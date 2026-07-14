import AppKit
import CrateDiggerCore
import SwiftUI

struct AlbumPoster: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel
    let album: Album?
    @State private var localThumbnail: NSImage?

    var body: some View {
        Group {
            if let nsImage = localThumbnail {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    )
            } else {
                // Sizes itself: square vinyl sleeve, or a jewel case slightly
                // wider than square (the spine lives outside the 1×1 lid).
                EmptyMediaCase(format: album?.mediaFormat, seed: album?.id ?? "empty")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(Color.black.opacity(theme.isDark ? 0.6 : 0.18), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(theme.isDark ? 0.5 : 0.35), radius: 8, y: 6)
        // Decode off the main thread (folder cover via ImageIO, embedded art via
        // ArtworkService.thumbnailAsync) so switching albums never blocks the
        // inspector on a synchronous full-res render. Keys on the live art so it
        // also reloads when a freshly-committed cover changes the album's hash.
        .task(id: loadKey) { await loadThumbnailImage() }
    }

    private var loadKey: String {
        album?.booklet?.frontCoverURL?.path ?? album?.artworkHash ?? album?.id ?? "empty"
    }

    private func loadThumbnailImage() async {
        if let coverURL = album?.booklet?.frontCoverURL {
            localThumbnail = await loadThumbnail(url: coverURL, maxPixelSize: 480)
        } else if let hash = album?.artworkHash {
            localThumbnail = await model.artworkService.thumbnailAsync(artworkHash: hash, maxPixel: 480)
        } else {
            localThumbnail = nil
        }
    }
}
