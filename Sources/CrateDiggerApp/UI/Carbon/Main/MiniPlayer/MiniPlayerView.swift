import CrateDiggerCore
import SwiftUI

/// The floating mini player — a compact Carbon glass strip that mirrors the full
/// app's playback (shares the same `LibraryViewModel`). Lifted from the v7
/// "CrateDigger Mini Player" design. Always dark glass, regardless of app theme.
struct MiniPlayerView: View {
    @ObservedObject var model: LibraryViewModel
    let onExpand: () -> Void

    var body: some View {
        MiniPlayerBody(model: model, onExpand: onExpand)
            .carbonThemed(mode: .dark)
    }
}

private struct MiniPlayerBody: View {
    @ObservedObject var model: LibraryViewModel
    let onExpand: () -> Void
    @Environment(\.carbon) private var theme

    /// Warm phosphor white for the track title (design `--oled-fg`).
    private let oledFG = Color(red: 245 / 255, green: 241 / 255, blue: 230 / 255)

    var body: some View {
        VStack(spacing: 0) {
            topBar
            artFrame
            titleBlock
            seekBlock
            transport
        }
        .padding(13)
        .frame(width: 272)
        .background(panel)
    }

    // MARK: - Glass panel

    private var panel: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return shape
            .fill(.ultraThinMaterial)
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
            iconButton(system: "opticaldisc", active: model.miniPlayerVinyl, disabled: model.isRadioMode,
                       help: model.miniPlayerVinyl ? "Vinyl — switch to CD" : "CD — switch to vinyl") {
                model.miniPlayerVinyl.toggle()
            }
            iconButton(system: "arrow.up.left.and.arrow.down.right", active: false, disabled: false,
                       help: "Open the full app") {
                onExpand()
            }
        }
        .frame(height: 22)
        .padding(.bottom, 11)
        .padding(.horizontal, 2)
    }

    private func iconButton(system: String, active: Bool, disabled: Bool, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: { ClickPlayer.shared.play(.key); action() }) {
            Image(systemName: system)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(disabled ? theme.ink4.opacity(0.5) : (active ? theme.orange : theme.ink3))
                .frame(width: 24, height: 24)
                .background(ChromeChassis(theme: theme, cornerRadius: 7))
                .overlay(active
                    ? RoundedRectangle(cornerRadius: 7).strokeBorder(theme.orange.opacity(0.5), lineWidth: 0.7)
                    : nil)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .padding(.leading, 6)
    }

    // MARK: - Art

    private var artFrame: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return ZStack {
            shape.fill(theme.wellDeep)
            SpinningRecordView(model: model, forcedVinyl: model.isRadioMode ? nil : model.miniPlayerVinyl)
                .padding(10)
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

    // MARK: - Title

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(trackTitle)
                .font(CarbonFont.sans(15, weight: .bold))
                .foregroundStyle(oledFG)
                .lineLimit(1)
            Text(subtitle)
                .font(CarbonFont.mono(9.5, weight: .semibold)).tracking(0.6)
                .foregroundStyle(theme.ink3)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 13)
        .padding(.horizontal, 2)
    }

    private var trackTitle: String {
        model.nowPlayingTrack?.track.title ?? "Nothing Playing"
    }

    private var subtitle: String {
        guard let t = model.nowPlayingTrack?.track else { return "—" }
        var parts: [String] = []
        if !t.artist.isEmpty { parts.append(t.artist) }
        if !t.album.isEmpty { parts.append(t.album) }
        if let year = t.year { parts.append(String(year)) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ").uppercased()
    }

    // MARK: - Seek

    private var seekBlock: some View {
        VStack(spacing: 7) {
            seekRail
            HStack {
                Text(timeString(model.displayedCurrentTime))
                    .font(CarbonFont.mono(9.5, weight: .semibold)).foregroundStyle(theme.ink3)
                Spacer()
                Text(timeString(model.playbackDuration))
                    .font(CarbonFont.mono(9.5, weight: .semibold)).foregroundStyle(theme.ink4)
            }
        }
        .padding(.top, 13)
        .padding(.horizontal, 2)
    }

    private var seekRail: some View {
        GeometryReader { proxy in
            let w = max(proxy.size.width, 1)
            let p = model.playbackDuration > 0
                ? min(max(model.displayedCurrentTime / model.playbackDuration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.42)).frame(height: 6)
                    .overlay(Capsule().stroke(Color.white.opacity(0.07), lineWidth: 0.6))
                Capsule()
                    .fill(LinearGradient(colors: [theme.cyan, theme.orange], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, w * p), height: 6)
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
        .buttonStyle(.plain)
        .help("Play / Pause")
    }

    private func transportButton(system: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: { ClickPlayer.shared.play(.key); action() }) {
            Image(systemName: system)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(theme.ink2)
                .frame(width: 36, height: 36)
                .background(ChromeChassis(theme: theme, cornerRadius: 10))
        }
        .buttonStyle(.plain)
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
        .buttonStyle(.plain)
    }

    // MARK: - Formatting

    private func timeString(_ seconds: Double) -> String {
        let t = Int(max(0, seconds))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Stops a drag inside the seek rail from moving the borderless window
/// (the rest of the panel stays draggable via `isMovableByWindowBackground`).
private struct WindowDragGuard: NSViewRepresentable {
    final class GuardView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
    func makeNSView(context: Context) -> NSView { GuardView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
