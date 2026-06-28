import AppKit
import SwiftUI

/// Footer POSITION seek dial — same panel chrome as the volume control.
/// Reflects playback progress and scrubs to seek (CrateDigger v6 `.f-seek`).
struct PositionDial: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    private var progress: Double {
        if let fraction = model.scrubbingFraction { return fraction }
        guard model.playbackDuration > 0 else { return 0 }
        return min(max(model.playbackCurrentTime / model.playbackDuration, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "slider.horizontal.below.rectangle")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.ink3)
                Text("POSITION")
                    .font(CarbonFont.mono(8, weight: .bold))
                    .tracking(1.8)
                    .foregroundStyle(theme.ink3)
                Spacer(minLength: 0)
                Button {
                    ClickPlayer.shared.play(.key)
                    model.scrubLockEnabled.toggle()
                } label: {
                    Image(systemName: model.scrubLockEnabled ? "lock.fill" : "lock.open")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(model.scrubLockEnabled ? theme.cyan : theme.ink3)
                }
                .buttonStyle(.plain)
                .carbonTip(model.scrubLockEnabled
                    ? "Scroll-to-seek on — scroll the dial to search"
                    : "Lock to scroll the dial to search")
            }

            Spacer(minLength: 0)

            track
                .frame(height: 22)
                .background(WindowDragGuard())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: 184, height: 64)
        .background(ChromeChassis(theme: theme, cornerRadius: 12))
        .overlay(
            ScrollSeekCatcher(enabled: model.scrubLockEnabled) { delta in
                model.scrollSeek(byFraction: delta)
            }
        )
        .accessibilityLabel("Playback position")
    }

    private var track: some View {
        GeometryReader { proxy in
            let w = max(proxy.size.width, 1)
            let p = progress
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(theme.isDark ? 0.36 : 0.10))
                    .overlay(Capsule().stroke(Color.white.opacity(theme.isDark ? 0.08 : 0.50), lineWidth: 0.6))
                    .frame(height: 6)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [theme.cyan.opacity(0.92), theme.orange.opacity(0.90)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(6, w * p), height: 6)
                    .shadow(color: theme.cyan.opacity(theme.isDark ? 0.26 : 0.18), radius: 5)
                Circle()
                    .fill(theme.chassisHi)
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(Color.white.opacity(0.70), lineWidth: 0.6))
                    .shadow(color: Color.black.opacity(theme.isDark ? 0.46 : 0.20), radius: 4, y: 2)
                    .offset(x: min(max(w * p - 8, 0), w - 16))
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in model.scrubbingFraction = min(max(g.location.x / w, 0), 1) }
                    .onEnded { g in
                        let f = min(max(g.location.x / w, 0), 1)
                        ClickPlayer.shared.play(.tick)
                        model.commitScrubSeek(toFraction: f)
                    }
            )
        }
    }
}

/// Transparent overlay that, while `enabled`, turns scroll-wheel / trackpad
/// scrolling over the POSITION dial into seek steps. Uses a local event monitor
/// (not `scrollWheel` on a hit-testing view) so it never blocks the drag gesture
/// — `hitTest` returns nil, so clicks pass straight through to the dial below.
private struct ScrollSeekCatcher: NSViewRepresentable {
    let enabled: Bool
    let onSeekDelta: (Double) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = MonitorView()
        view.enabled = enabled
        view.onSeekDelta = onSeekDelta
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? MonitorView else { return }
        view.onSeekDelta = onSeekDelta
        view.enabled = enabled
    }

    final class MonitorView: NSView {
        var onSeekDelta: ((Double) -> Void)?
        var enabled = false { didSet { refreshMonitor() } }
        private var monitor: Any?

        // Pass mouse events through to the dial's drag gesture below.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            refreshMonitor()
        }

        private func refreshMonitor() {
            if enabled, window != nil, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    guard let self, let window = self.window, event.window == window else { return event }
                    let frameInWindow = self.convert(self.bounds, to: nil)
                    guard frameInWindow.contains(event.locationInWindow) else { return event }
                    let raw = event.scrollingDeltaY
                    guard raw != 0 else { return event }
                    // ~1% of the track per wheel notch; finer for precise trackpad deltas.
                    let factor = event.hasPreciseScrollingDeltas ? 0.0009 : 0.012
                    self.onSeekDelta?(-raw * factor)
                    return nil
                }
            } else if (!enabled || window == nil), let existing = monitor {
                NSEvent.removeMonitor(existing)
                monitor = nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
