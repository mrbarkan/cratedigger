import CrateDiggerCore
import SwiftUI

/// Up Next — the queue behind the playing track, with reordering and removal.
/// Rows mirror the browser's track rows so the queue reads as the same hardware,
/// not a separate list widget.
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

    private var list: some View {
        // Offset into the full queue: Up Next starts after the playing track.
        let base = (model.playbackCurrentIndex ?? -1) + 1
        return List {
            ForEach(Array(model.upNextTracks.enumerated()), id: \.element.track.id) { offset, loaded in
                QueueRow(
                    loaded: loaded,
                    position: offset + 1,
                    onPlay: { model.playFromQueue(trackID: loaded.track.id) },
                    onRemove: { model.removeFromQueue(trackIDs: [loaded.track.id]) },
                    onMoveUp: offset > 0
                        ? { model.moveInQueue(from: base + offset, to: base + offset - 1) }
                        : nil,
                    onMoveDown: offset < model.upNextTracks.count - 1
                        ? { model.moveInQueue(from: base + offset, to: base + offset + 2) }
                        : nil
                )
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            .onMove { offsets, destination in
                // `destination` is List's insertion index in the pre-move
                // array, the convention `moveInQueue` already implements.
                guard let source = offsets.first else { return }
                model.moveInQueue(from: base + source, to: base + destination)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?

    @State private var hovering = false

    var body: some View {
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

            // Controls replace the duration on hover — the row is narrow and the
            // time is the less useful of the two while you're editing the queue.
            if hovering {
                controls
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
        .onTapGesture(count: 2, perform: onPlay)
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

    private var controls: some View {
        HStack(spacing: 2) {
            iconButton("chevron.up", help: "Move up", action: onMoveUp)
            iconButton("chevron.down", help: "Move down", action: onMoveDown)
            iconButton("xmark", help: "Remove from queue", action: onRemove)
        }
    }

    @ViewBuilder
    private func iconButton(_ symbol: String, help: String, action: (() -> Void)?) -> some View {
        Button(action: { action?() }) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(action == nil ? theme.ink4.opacity(0.35) : theme.ink2)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.carbonHover)
        .disabled(action == nil)
        .carbonTip(help)
    }
}
