import AppKit
import CrateDiggerCore
import SwiftUI

struct AlbumPoster: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel
    let album: Album?
    @State private var localThumbnail: NSImage?

    var body: some View {
        ZStack {
            if let nsImage = localThumbnail ?? thumbnail(for: album) {
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
        .task(id: album?.booklet?.frontCoverURL) {
            guard let coverURL = album?.booklet?.frontCoverURL else {
                localThumbnail = nil
                return
            }
            localThumbnail = await loadLocalThumbnail(from: coverURL)
        }
    }
    
    private func loadLocalThumbnail(from url: URL) async -> NSImage? {
        let cgImage = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 480
            ]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                return nil
            }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
        
        guard let cgImage = cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }

    private func thumbnail(for album: Album?) -> NSImage? {
        guard let album = album, let hash = album.artworkHash else { return nil }
        return model.artworkService.generateThumbnail(artworkHash: hash, size: CGSize(width: 480, height: 480))
    }
}
