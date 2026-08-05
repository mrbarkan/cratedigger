import CrateDiggerCore
import SwiftUI

/// What the current settings will actually convert, and where each file lands.
///
/// The patch bay could tell you the settings and the count, but not *which*
/// tracks were in scope or what they'd be called on the other side — so the
/// first real feedback was the output folder. This resolves the destination
/// through the same `OutputPathPlanner` the conversion uses, so what's listed
/// here is what gets written.
struct ConversionQueueView: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.conversionProgress.isRunning {
                progressStrip
            }
            if model.conversionQueueTracks.isEmpty {
                empty
            } else {
                list
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("QUEUE")
                .font(CarbonFont.mono(8.5, weight: .semibold))
                .tracking(2.2)
                .foregroundStyle(theme.ink3)
            Spacer(minLength: 8)
            Text(summary)
                .font(CarbonFont.mono(8.5, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(theme.ink4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .overlay(
            Rectangle()
                .fill(theme.isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.07))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private var summary: String {
        let tracks = model.conversionQueueTracks
        guard !tracks.isEmpty else { return "—" }
        let noun = tracks.count == 1 ? "TRACK" : "TRACKS"
        let seconds = model.conversionQueueDurationSeconds
        return seconds > 0
            ? "\(tracks.count) \(noun) · \(SleepMode.clockLabel(Int(seconds)))"
            : "\(tracks.count) \(noun)"
    }

    // MARK: - Live progress

    private var progressStrip: some View {
        let progress = model.conversionProgress
        let fraction = progress.jobsTotal > 0
            ? Double(progress.jobsCompleted) / Double(progress.jobsTotal) : 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(progress.currentFilename ?? "Converting…")
                    .font(CarbonFont.mono(9))
                    .foregroundStyle(theme.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Text("\(progress.jobsCompleted)/\(progress.jobsTotal)")
                    .font(CarbonFont.mono(9, weight: .bold))
                    .foregroundStyle(theme.cyan)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.35)).frame(height: 4)
                    Capsule()
                        .fill(LinearGradient(colors: [theme.cyan, theme.orange],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, geo.size.width * fraction), height: 4)
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.isDark ? Color.black.opacity(0.25) : Color.black.opacity(0.03))
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(model.conversionQueueTracks.enumerated()), id: \.element.track.id) { index, loaded in
                    ConversionQueueRow(
                        loaded: loaded,
                        position: index + 1,
                        destination: model.plannedOutputName(for: loaded)
                    )
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("Nothing in scope")
                .font(CarbonFont.sans(12, weight: .semibold))
                .foregroundStyle(theme.ink3)
            Text("Pick a scope in Settings, or select an album in the browser.")
                .font(CarbonFont.sans(11))
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.ink4)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ConversionQueueRow: View {
    @Environment(\.carbon) private var theme
    let loaded: LoadedTrack
    let position: Int
    /// Filename the planner will write, or nil if it can't be resolved yet.
    let destination: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(String(format: "%02d", position))
                .font(CarbonFont.mono(9))
                .foregroundStyle(theme.ink4)
                .frame(width: 20, alignment: .trailing)

            VStack(alignment: .leading, spacing: 1) {
                Text(loaded.track.title)
                    .font(CarbonFont.sans(11.5, weight: .medium))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 7))
                        .foregroundStyle(theme.ink4)
                    Text(destination ?? loaded.track.fileURL.lastPathComponent)
                        .font(CarbonFont.mono(8.5))
                        .foregroundStyle(destination == nil ? theme.ink4.opacity(0.6) : theme.cyan)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(loaded.track.formatName ?? "—")
                .font(CarbonFont.mono(8))
                .tracking(0.8)
                .foregroundStyle(theme.ink4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .overlay(
            Rectangle()
                .fill(theme.isDark ? Color.white.opacity(0.035) : Color.black.opacity(0.045))
                .frame(height: 1),
            alignment: .bottom
        )
    }
}
