import SwiftUI
import AppKit
import CrateDiggerCore

/// One picture in Artwork Search: a remote scan through `AsyncImage`, or a
/// file off the user's disk decoded at the size it is drawn.
///
/// Files from disk used to go through `AsyncImage` too, which decodes the
/// whole file: a folder of 3000 px booklet scans became a grid of full-size
/// bitmaps to draw 130 pt tiles. Here a local file is downsampled off the
/// main thread by ImageIO, like every other thumbnail in the app.
struct ArtworkSearchImage<Placeholder: View, Failure: View>: View {
    let image: RemoteArtworkImage
    let url: URL
    /// Longest edge, in pixels, a local file is decoded at.
    let maxPixelSize: Int
    @ViewBuilder let placeholder: () -> Placeholder
    @ViewBuilder let failure: () -> Failure

    @State private var local: NSImage?
    @State private var localFailed = false

    var body: some View {
        if image.source == .localFile {
            Group {
                if let local {
                    Image(nsImage: local).resizable()
                } else if localFailed {
                    failure()
                } else {
                    placeholder()
                }
            }
            .task(id: url) {
                let loaded = await loadThumbnail(url: url, maxPixelSize: maxPixelSize)
                guard !Task.isCancelled else { return }
                local = loaded
                localFailed = loaded == nil
            }
        } else {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let picture):
                    picture.resizable()
                case .failure:
                    failure()
                default:
                    placeholder()
                }
            }
        }
    }
}
