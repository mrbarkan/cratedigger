import AppKit
import CrateDiggerCore
import SwiftUI

/// The picture of whatever is playing: a stream's thumbnail, else the album's
/// cover — the cover file on disk, then cached bytes by hash, then the audio
/// file's own art (same order as AlbumPoster). Shared by the Mini Player and
/// the compact player so the two can never disagree about which picture is on.
struct NowPlayingCover<Placeholder: View>: View {
    @ObservedObject var model: LibraryViewModel
    var maxPixel: Int = 480
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var coverImage: NSImage?

    var body: some View {
        Group {
            if model.isStreamActive, let stream = model.selectedStream {
                StreamThumbnail(stream: stream)
            } else if let image = coverImage {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                placeholder()
            }
        }
        .task(id: coverKey) { await loadCoverImage() }
    }

    /// Reload key: track change or a freshly committed cover (hash change).
    private var coverKey: String {
        if model.isStreamActive { return "stream-\(model.selectedStreamID ?? "none")" }
        let track = model.nowPlayingTrack?.track
        return "\(track?.id.uuidString ?? "none")-\(track?.artworkHash ?? "")"
    }

    private func loadCoverImage() async {
        guard let loaded = model.nowPlayingTrack else {
            coverImage = nil
            return
        }
        if let album = model.album(containing: loaded.track.id),
           let coverURL = album.booklet?.frontCoverURL,
           let image = await loadThumbnail(url: coverURL, maxPixelSize: maxPixel) {
            coverImage = image
            return
        }
        if let hash = loaded.track.artworkHash,
           let image = await model.artworkService.thumbnailAsync(artworkHash: hash, maxPixel: maxPixel) {
            coverImage = image
            return
        }
        if loaded.track.fileURL.isFileURL,
           let asset = await model.artworkService.resolveArtwork(trackURL: loaded.track.fileURL) {
            coverImage = await model.artworkService.thumbnailAsync(artworkHash: asset.hash, maxPixel: maxPixel)
            return
        }
        coverImage = nil
    }
}
