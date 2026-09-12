import AppKit
import CrateDiggerCore
import SwiftUI

/// Up Next — the queue behind the playing track. Drag a row onto another to
/// reorder, hover for ✕ to remove, double-click to play. Rows mirror the
/// browser's track rows so the queue reads as the same hardware, not a
/// separate list widget.
struct QueueInspectorView: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.isStreamActive {
                notice("A stream is playing.\nQueueing applies to library tracks.")
            } else if !model.hasUpNext {
                notice(model.nowPlayingTrack == nil
                       ? "Nothing playing.\nPlay a track to start a queue."
                       : "Nothing up next.\nUse Play Next or Play Last on any track.")
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("UP NEXT")
                .font(CarbonFont.mono(8.5, weight: .semibold))
                .tracking(2.2)
                .foregroundStyle(theme.ink3)
            Spacer(minLength: 8)
            Text(countLabel)
                .font(CarbonFont.mono(8.5, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(theme.ink4)
            KeyButton(style: model.hasUpNext ? .normal : .disabled,
                      action: { model.clearUpNext() }) {
                Text("CLEAR")
            }
            .frame(width: 54, height: 20)
            .disabled(!model.hasUpNext)
            .carbonTip("Remove everything after the playing track")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.isDark ? Color.black.opacity(0.4) : Color.black.opacity(0.04))
        .overlay(
            Rectangle()
                .fill(theme.isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.07))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private var countLabel: String {
        let count = model.upNextTracks.count
        guard count > 0 else { return "—" }
        let seconds = model.upNextTracks.reduce(0) { $0 + $1.track.durationSeconds }
        return seconds > 0 ? "\(count) · \(Self.durationLabel(seconds))" : "\(count)"
    }

    // MARK: - List

    /// A plain stack rather than a `List` with `onMove`: the rows are drag
    /// sources and drop targets the way playlist rows are, which is what lets a
    /// click, hold and drag pick one up and shows where it will land.
    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(Array(model.upNextTracks.enumerated()), id: \.element.track.id) { offset, loaded in
                    QueueRow(
                        loaded: loaded,
                        position: offset + 1,
                        onPlay: { model.playFromQueue(trackID: loaded.track.id) },
                        onRemove: { model.removeFromQueue(trackIDs: [loaded.track.id]) }
                    )
                    .draggable(QueueDrag.payload(for: loaded.track.id))
                    .modifier(ReorderDropTarget(onDrop: { model.dropQueuedTracks($0, before: loaded.track.id) }))
                }
                // Below the last row: a drop here sends the track to the end.
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                    .modifier(ReorderDropTarget(onDrop: { model.dropQueuedTracks($0, before: nil) }))
            }
        }
    }

    private func notice(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(CarbonFont.sans(11.5))
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.ink4)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func durationLabel(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.rounded()))
        let minutes = total / 60
        return minutes >= 60
            ? String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, total % 60)
            : String(format: "%d:%02d", minutes, total % 60)
    }
}

private struct QueueRow: View {
    @Environment(\.carbon) private var theme
    let loaded: LoadedTrack
    let position: Int
    let onPlay: () -> Void
    let onRemove: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            // Double-click plays. Read off the event rather than a
            // `TapGesture(count: 2)`: the row is a drag source and a drop
            // target, and those swallow the second mouse-down (see
            // `TrackTableRow`). The remove key sits outside this button so the
            // two never nest.
            Button(action: {
                if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { onPlay() }
            }) {
                HStack(spacing: 8) {
                    Text(String(format: "%02d", position))
                        .font(CarbonFont.mono(9.5))
                        .foregroundStyle(theme.ink4)
                        .frame(width: 20, alignment: .trailing)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(loaded.track.title)
                            .font(CarbonFont.sans(12, weight: .medium))
                            .foregroundStyle(theme.ink)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(CarbonFont.mono(8.5))
                            .foregroundStyle(theme.ink4)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // The remove key replaces the duration on hover: the row is narrow
            // and the time is the less useful of the two while editing.
            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.ink2)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.carbonHover)
                .carbonTip("Remove from queue")
            } else if loaded.track.durationSeconds > 0 {
                Text(QueueInspectorView.durationLabel(loaded.track.durationSeconds))
                    .font(CarbonFont.mono(9.5))
                    .foregroundStyle(theme.ink4)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(hovering ? theme.ink.opacity(0.05) : Color.clear)
        .overlay(
            Rectangle()
                .fill(theme.isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.05))
                .frame(height: 1),
            alignment: .bottom
        )
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Play Now", action: onPlay)
            Button("Remove from Queue", action: onRemove)
        }
    }

    private var subtitle: String {
        [loaded.track.artist, loaded.track.album]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
            .uppercased()
    }
}
