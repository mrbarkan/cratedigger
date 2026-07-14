import CrateDiggerCore
import SwiftUI

/// Mini player art treatment, cycled by the top-bar art button. Disc follows
/// the album's marked media format (Art tab dropdown) — vinyl shows only when
/// the album is explicitly marked Vinyl; Auto reads as CD.
enum MiniPlayerArtMode: String, CaseIterable {
    // Raw value stays "cd" so pre-existing saved prefs restore; an old saved
    // "vinyl" fails the rawValue init and falls back to the default (.disc).
    case disc = "cd"
    case cover

    var next: MiniPlayerArtMode {
        self == .disc ? .cover : .disc
    }

    var iconName: String {
        switch self {
        case .disc:  return "opticaldisc"
        case .cover: return "photo"
        }
    }

    var label: String {
        switch self {
        case .disc:  return "Disc"
        case .cover: return "Album Cover"
        }
    }
}

/// The floating mini player — a compact Carbon glass strip that mirrors the full
/// app's playback (shares the same `LibraryViewModel`). Always dark glass.
struct MiniPlayerView: View {
    @ObservedObject var model: LibraryViewModel
    let onExpand: () -> Void

    var body: some View {
        MiniPlayerBody(model: model, clock: model.playbackClock, onExpand: onExpand)
            .carbonThemed(mode: .dark)
    }
}

private struct MiniPlayerBody: View {
    @ObservedObject var model: LibraryViewModel
    /// Observed so the OLED time/seek rail keep ticking — playback time lives
    /// on the isolated clock, not the view model.
    @ObservedObject var clock: PlaybackClock
    let onExpand: () -> Void
    @Environment(\.carbon) private var theme

    /// Warm phosphor white for the OLED text (design `--oled-fg`).
    private let oledFG = Color(red: 245 / 255, green: 241 / 255, blue: 230 / 255)

    /// Cover for the COVER art mode, resolved off-main like AlbumPoster.
    @State private var coverImage: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            artFrame
            oledDisplay.padding(.top, 13)
            seekRail.padding(.top, 11).padding(.horizontal, 2)
            transport
        }
        .padding(13)
        .frame(width: 272)
        .background(panel)
        .task(id: coverKey) { await loadCoverImage() }
    }

    // MARK: - Glass panel

    private var panel: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return shape
            .fill(theme.chassis) // opaque, not Material — see ChassisLayer
            .overlay(
                shape.fill(LinearGradient(
                    colors: [theme.chassisHi.opacity(0.5), theme.chassis.opacity(0.55), theme.chassisLo.opacity(0.62)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(theme.orange).frame(width: 6, height: 6)
                    .shadow(color: theme.orange.opacity(0.8), radius: 3)
                Text("NOW PLAYING")
                    .font(CarbonFont.mono(9, weight: .bold)).tracking(2)
                    .foregroundStyle(theme.ink3)
            }
            Spacer(minLength: 0)
            artModeButton
            iconButton(system: "arrow.up.left.and.arrow.down.right", help: "Open the full app") {
                onExpand()
            }
        }
        .frame(height: 22)
        .padding(.bottom, 11)
        .padding(.horizontal, 2)
    }

    private var artModeButton: some View {
        Button(action: {
            ClickPlayer.shared.play(.key)
            model.miniPlayerArtMode = model.miniPlayerArtMode.next
        }) {
            Image(systemName: model.miniPlayerArtMode.iconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(model.isRadioMode ? theme.ink4.opacity(0.5) : theme.ink3)
                .frame(width: 24, height: 24)
                .background(ChromeChassis(theme: theme, cornerRadius: 7))
        }
        .buttonStyle(.carbonHover)
        .disabled(model.isRadioMode)
        .carbonTip("Art: \(model.miniPlayerArtMode.label) — tap to cycle")
        .padding(.leading, 6)
    }

    private func iconButton(system: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: { ClickPlayer.shared.play(.key); action() }) {
            Image(systemName: system)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.ink3)
                .frame(width: 24, height: 24)
                .background(ChromeChassis(theme: theme, cornerRadius: 7))
        }
        .buttonStyle(.carbonHover)
        .carbonTip(help)
        .padding(.leading, 6)
    }

    // MARK: - Art

    private var artFrame: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return ZStack {
            shape.fill(theme.wellDeep)
            artContent
            shape
                .fill(LinearGradient(colors: [Color.white.opacity(0.16), .clear],
                                     startPoint: .topLeading, endPoint: .center))
                .allowsHitTesting(false)
        }
        .frame(width: 246, height: 246)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.black.opacity(0.6), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
    }

    @ViewBuilder
    private var artContent: some View {
        switch model.miniPlayerArtMode {
        case .cover:
            if let image = coverImage {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color(hex: 0xD97757), Color(hex: 0xC14A2E)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        case .disc:
            SpinningRecordView(model: model).padding(10)
        }
    }

    /// Reload key: track change or a freshly committed cover (hash change).
    private var coverKey: String {
        let track = model.nowPlayingTrack?.track
        return "\(track?.id.uuidString ?? "none")-\(track?.artworkHash ?? "")"
    }

    /// Same resolution order as AlbumPoster — album cover file on disk first,
    /// then cached bytes by hash. A hash-only lookup (the original code here)
    /// came back empty for crate-loaded tracks whose artwork bytes weren't in
    /// the session cache/store, leaving the cover mode on the placeholder
    /// gradient. Last resort: re-extract from the audio file itself, which also
    /// re-primes the hash cache.
    private func loadCoverImage() async {
        guard let loaded = model.nowPlayingTrack else {
            coverImage = nil
            return
        }
        if let album = model.album(containing: loaded.track.id),
           let coverURL = album.booklet?.frontCoverURL,
           let image = await loadThumbnail(url: coverURL, maxPixelSize: 480) {
            coverImage = image
            return
        }
        if let hash = loaded.track.artworkHash,
           let image = await model.artworkService.thumbnailAsync(artworkHash: hash, maxPixel: 480) {
            coverImage = image
            return
        }
        if loaded.track.fileURL.isFileURL,
           let asset = await model.artworkService.resolveArtwork(trackURL: loaded.track.fileURL) {
            coverImage = await model.artworkService.thumbnailAsync(artworkHash: asset.hash, maxPixel: 480)
            return
        }
        coverImage = nil
    }

    // MARK: - OLED display (title · band · time)

    private var oledDisplay: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return shape
            .fill(theme.oledSurface)
            .overlay(Scanlines(opacity: 0.02).clipShape(shape))
            .overlay(shape.strokeBorder(theme.oledStrokeInner, lineWidth: 1.5))
            .overlay(
                VStack(alignment: .leading, spacing: 5) {
                    Text(trackTitle)
                        .font(CarbonFont.sans(15, weight: .bold))
                        .foregroundStyle(oledFG)
                        .lineLimit(1)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(band)
                            .font(CarbonFont.mono(9, weight: .semibold)).tracking(0.6)
                            .foregroundStyle(oledFG.opacity(0.52))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text("\(timeString(model.displayedCurrentTime)) / \(timeString(model.playbackDuration))")
                            .font(CarbonFont.mono(9, weight: .semibold))
                            .foregroundStyle(theme.orange)
                            .fixedSize()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            )
            .frame(height: 58)
            .compositingGroup()
    }

    private var trackTitle: String {
        model.nowPlayingTrack?.track.title ?? "Nothing Playing"
    }

    private var band: String {
        guard let t = model.nowPlayingTrack?.track else { return "—" }
        var parts: [String] = []
        if !t.artist.isEmpty { parts.append(t.artist) }
        if !t.album.isEmpty { parts.append(t.album) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ").uppercased()
    }

    // MARK: - Seek

    private var seekRail: some View {
        GeometryReader { proxy in
            let w = max(proxy.size.width, 1)
            let p = model.playbackDuration > 0
                ? min(max(model.displayedCurrentTime / model.playbackDuration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.42)).frame(height: 6)
                    .overlay(Capsule().stroke(Color.white.opacity(0.07), lineWidth: 0.6))
                // Full-width cyan→orange ramp revealed by the lit mask — the
                // gradient's endpoints stay fixed (like the OLED/footer bars)
                // instead of stretching with playback progress.
                Capsule()
                    .fill(LinearGradient(colors: [theme.cyan, theme.orange], startPoint: .leading, endPoint: .trailing))
                    .frame(height: 6)
                    .mask(
                        Capsule()
                            .frame(width: max(6, w * p))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    )
                    .shadow(color: theme.cyan.opacity(0.4), radius: 5)
                Circle()
                    .fill(RadialGradient(colors: [.white, Color(white: 0.82)],
                                         center: .init(x: 0.4, y: 0.3), startRadius: 0, endRadius: 7))
                    .frame(width: 13, height: 13)
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .offset(x: min(max(w * p - 6.5, 0), w - 13))
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .background(WindowDragGuard())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in model.scrubbingFraction = min(max(g.location.x / w, 0), 1) }
                    .onEnded { g in
                        ClickPlayer.shared.play(.tick)
                        model.commitScrubSeek(toFraction: min(max(g.location.x / w, 0), 1))
                    }
            )
        }
        .frame(height: 13)
    }

    // MARK: - Transport

    private var transport: some View {
        HStack(spacing: 9) {
            toggleButton(system: "shuffle", on: model.shuffleEnabled) { model.toggleShuffle() }
            transportButton(system: "backward.fill", size: 13) { model.previous() }
            dome
            transportButton(system: "forward.fill", size: 13) { model.next() }
            toggleButton(system: repeatIcon, on: model.repeatMode != .off) { model.cycleRepeatMode() }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
    }

    private var repeatIcon: String {
        model.repeatMode == .one ? "repeat.1" : "repeat"
    }

    private var dome: some View {
        Button(action: { ClickPlayer.shared.play(.key); model.togglePlayPause() }) {
            Image(systemName: model.playbackState == .playing ? "pause.fill" : "play.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(
                    Circle().fill(LinearGradient(colors: [theme.orangeHi, theme.orange, theme.orangeLo],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                )
                .overlay(Circle().strokeBorder(Color.white.opacity(0.42), lineWidth: 0.8))
                .shadow(color: theme.orange.opacity(0.55), radius: 12)
        }
        .buttonStyle(.carbonHover)
        .carbonTip("Play / Pause")
    }

    private func transportButton(system: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: { ClickPlayer.shared.play(.key); action() }) {
            Image(systemName: system)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(theme.ink2)
                .frame(width: 36, height: 36)
                .background(ChromeChassis(theme: theme, cornerRadius: 10))
        }
        .buttonStyle(.carbonHover)
    }

    private func toggleButton(system: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: { ClickPlayer.shared.play(.key); action() }) {
            Image(systemName: system)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(on ? theme.orange : theme.ink4)
                .frame(width: 36, height: 36)
                .background(ChromeChassis(theme: theme, cornerRadius: 10))
                .overlay(on
                    ? RoundedRectangle(cornerRadius: 10).strokeBorder(theme.orange.opacity(0.5), lineWidth: 0.7)
                    : nil)
        }
        .buttonStyle(.carbonHover)
    }

    // MARK: - Formatting

    private func timeString(_ seconds: Double) -> String {
        let t = Int(max(0, seconds))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}
