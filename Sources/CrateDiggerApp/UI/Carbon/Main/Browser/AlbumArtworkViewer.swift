import AppKit
import CrateDiggerCore
import SwiftUI

/// Presents the "View Artwork" cover lightbox in a floating, borderless window
/// over the app — the same window class the booklet viewer uses, so it sits
/// above CrateDigger without disturbing the current source or selection. Albums
/// that have a booklet skip this and open the richer `AlbumBookletView` instead
/// (see the `showArtwork` wiring in `MainShell`).
@MainActor
enum ArtworkViewerPresenter {
    private static var window: BorderlessBookletWindow?

    static func show(album: Album, theme: CarbonTheme, model: LibraryViewModel) {
        window?.close()
        let view = AlbumArtworkViewer(album: album, onClose: { close() })
            .environmentObject(model)
            .environment(\.carbon, theme)
        let w = BorderlessBookletWindow(contentView: AnyView(view))
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    static func close() {
        window?.close()
        window = nil
    }
}

/// The cover-only lightbox: the album's artwork shown large over a dimmed
/// backdrop. Click outside or press Esc to close.
struct AlbumArtworkViewer: View {
    @Environment(\.carbon) private var theme
    let album: Album
    let onClose: () -> Void

    @State private var eventMonitor: Any?

    var body: some View {
        ZStack {
            Color.black.opacity(0.62)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            VStack(spacing: 18) {
                AlbumPoster(album: album)
                    .frame(width: 460, height: 460)

                VStack(spacing: 5) {
                    Text(album.title)
                        .font(CarbonFont.sans(20, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text(caption)
                        .font(CarbonFont.mono(11, weight: .medium))
                        .tracking(1.4)
                        .foregroundStyle(.white.opacity(0.7))
                }

                Button(action: onClose) {
                    Text("CLOSE")
                        .font(CarbonFont.mono(9.5, weight: .bold))
                        .tracking(2)
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: 520)
        }
        .onAppear {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 { onClose(); return nil }   // Esc
                return event
            }
        }
        .onDisappear {
            if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
        }
    }

    private var caption: String {
        var parts = [album.artistName.uppercased()]
        if let year = album.year { parts.append(String(year)) }
        return parts.joined(separator: " · ")
    }
}
