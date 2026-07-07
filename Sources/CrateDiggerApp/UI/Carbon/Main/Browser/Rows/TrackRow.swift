import CrateDiggerCore
import SwiftUI

struct TrackRow: View {
    @Environment(\.carbon) private var theme
    let loaded: LoadedTrack
    let selected: Bool
    let isPlaying: Bool
    var isOffline: Bool = false
    var isMissing: Bool = false
    let onSelect: () -> Void
    let onActivate: () -> Void

    var body: some View {
        ColumnRow(
            selected: selected,
            onSelect: onSelect,
            onActivate: onActivate
        ) {
            Text(numberLabel)
                .font(CarbonFont.mono(9.5))
                .foregroundStyle(numberColor)
        } title: {
            Text(loaded.track.title)
                .font(CarbonFont.sans(12.5, weight: isPlaying ? .semibold : .medium))
                .foregroundStyle(titleColor)
        } trail: {
            HStack(spacing: 5) {
                if isOffline {
                    Image(systemName: "externaldrive.badge.xmark")
                        .font(.system(size: 9))
                        .foregroundStyle(metaColor)
                        .help("On a disconnected drive")
                } else if isMissing {
                    Image(systemName: "questionmark.folder")
                        .font(.system(size: 9))
                        .foregroundStyle(theme.orange)
                        .help("File is missing — locate it in Library Maintenance")
                }
                Text(durationString(loaded.track.durationSeconds))
                    .font(CarbonFont.mono(10))
                    .foregroundStyle(metaColor)
            }
        }
        // Dim tracks that aren't playable right now — offline drive or missing file.
        .opacity((isOffline || isMissing) && !selected ? 0.55 : 1)
        .draggable("track::" + loaded.track.id.uuidString)
    }

    private var numberLabel: String {
        if let number = loaded.track.trackNumber {
            return String(format: "%02d", number)
        }
        return "—"
    }

    private var numberColor: Color {
        if selected { return theme.slotInk }
        if isPlaying { return theme.orange }
        return theme.ink3
    }

    private var titleColor: Color {
        if selected { return theme.slotInk }
        if isPlaying { return theme.orange }
        return theme.ink
    }

    private var metaColor: Color {
        if selected { return theme.slotInk.opacity(0.72) }
        return theme.ink3
    }

    private func durationString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        return seconds.asClock
    }
}
