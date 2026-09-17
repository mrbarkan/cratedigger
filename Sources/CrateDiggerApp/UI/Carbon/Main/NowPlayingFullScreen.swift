import AppKit
import CrateDiggerCore
import SwiftUI

/// The full-screen player: the artwork viewer's dark room, with the playing
/// cover as large as the screen allows and the shelf's own controls under it.
/// One window over the app, like the artwork viewer, so the source and the
/// selection behind it are untouched. Esc, the CLOSE pill or a click on the
/// backdrop leave it; Space still plays and pauses through the app's monitor.
@MainActor
enum NowPlayingFullScreenPresenter {
    private static var window: BorderlessBookletWindow?

    static var isShowing: Bool { window != nil }

    static func toggle(theme: CarbonTheme, model: LibraryViewModel) {
        if isShowing { close() } else { show(theme: theme, model: model) }
    }

    static func show(theme: CarbonTheme, model: LibraryViewModel) {
        close()
        let view = NowPlayingFullScreenView(onClose: { close() })
            .environmentObject(model)
            .environment(\.carbon, theme)
        let w = BorderlessBookletWindow(contentView: AnyView(view))
        // A dark room whatever the app's Appearance says — see ArtworkViewerPresenter.
        w.appearance = NSAppearance(named: .darkAqua)
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    static func close() {
        window?.close()
        window = nil
    }
}

struct NowPlayingFullScreenView: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel
    let onClose: () -> Void

    @State private var cover: NSImage?
    @State private var eventMonitor: Any?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.94)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            VStack(spacing: 26) {
                artwork
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                titles
                TimeReadout(clock: model.playbackClock)
                // The shelf, verbatim: the same two pods and transport the
                // footer shows, so nothing here has to be learnt twice.
                HStack(spacing: 28) {
                    PositionDial(clock: model.playbackClock)
                        .frame(width: 300)
                    TransportCluster()
                    VolumeKnob(value: $model.playbackVolume)
                        .frame(width: 300)
                }
            }
            .padding(.horizontal, 60)
            .padding(.top, 56)
            .padding(.bottom, 40)

            Button(action: onClose) {
                Text("CLOSE")
                    .font(CarbonFont.mono(9.5, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 18)
                    .frame(height: 34)
            }
            .artworkBarButtonStyle()
            .padding(24)
        }
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
        .task(id: coverKey) { await loadCover() }
    }

    // MARK: - Artwork

    private var album: Album? {
        guard let track = model.nowPlayingTrack else { return nil }
        return model.album(containing: track.track.id)
    }

    private var artwork: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let cover {
                    Image(nsImage: cover)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    EmptyMediaCase(format: album?.mediaFormat, seed: album?.id ?? "empty")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.6), radius: 30, y: 14)
            // Taps on the cover stay on the cover; only the backdrop dismisses.
            .contentShape(Rectangle())
            .onTapGesture {}
    }

    /// Track change or a freshly committed cover (hash change).
    private var coverKey: String {
        if model.isStreamActive { return "stream-\(model.selectedStreamID ?? "none")" }
        let track = model.nowPlayingTrack?.track
        return "\(track?.id.uuidString ?? "none")-\(track?.artworkHash ?? "")"
    }

    /// The screen wants more pixels than any thumbnail the app keeps: 2000px
    /// covers a 1000pt square on a Retina display.
    private func loadCover() async {
        guard let loaded = model.nowPlayingTrack else { cover = nil; return }
        if let coverURL = album?.booklet?.frontCoverURL,
           let image = await loadThumbnail(url: coverURL, maxPixelSize: 2000) {
            cover = image
        } else if let hash = loaded.track.artworkHash,
                  let image = await model.artworkService.thumbnailAsync(artworkHash: hash, maxPixel: 2000) {
            cover = image
        } else {
            cover = nil
        }
    }

    // MARK: - Titles (same three lines as the mini player)

    private var titles: some View {
        VStack(spacing: 8) {
            Text(trackTitle)
                .font(CarbonFont.sans(26, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            HStack(spacing: 8) {
                Text(band).foregroundStyle(.white.opacity(0.7))
                if !albumLine.isEmpty {
                    Text("·").foregroundStyle(.white.opacity(0.4))
                    Text(albumLine).foregroundStyle(theme.orange)
                }
            }
            .font(CarbonFont.mono(11, weight: .bold))
            .tracking(1.4)
            .lineLimit(1)
        }
    }

    private var trackTitle: String {
        if model.isStreamActive, let stream = model.selectedStream { return stream.title }
        return model.nowPlayingTrack?.track.title ?? "Nothing Playing"
    }

    private var band: String {
        if model.isStreamActive, let stream = model.selectedStream {
            return stream.channel.isEmpty ? "LIVE" : stream.channel.uppercased()
        }
        return (model.nowPlayingTrack?.track.artist ?? "").uppercased()
    }

    private var albumLine: String {
        if model.isStreamActive { return "" }
        return (model.nowPlayingTrack?.track.album ?? "").uppercased()
    }

    // MARK: - Keys

    private func installKeyMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }   // Esc
            onClose()
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
    }
}

/// Elapsed and total, the mini player's readout at screen size. Observes the
/// clock so only this leaf re-renders on every tick.
private struct TimeReadout: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        Text(model.isStreamActive || model.playbackDuration <= 0
             ? timeString(model.displayedCurrentTime)
             : "\(timeString(model.displayedCurrentTime)) / \(timeString(model.playbackDuration))")
            .font(CarbonFont.mono(13, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(theme.orange)
            .monospacedDigit()
            .fixedSize()
    }

    private func timeString(_ seconds: Double) -> String {
        let t = Int(max(0, seconds))
        return t >= 3600
            ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
            : String(format: "%d:%02d", t / 60, t % 60)
    }
}
