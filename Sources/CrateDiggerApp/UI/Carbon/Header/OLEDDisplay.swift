import SwiftUI

struct OLEDDisplay: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        ZStack {
            background

            switch model.oledView {
            case .nowPlaying: NowPlayingView()
            case .vu:         VUView()
            case .conversion: ConversionView()
            case .scan:       ScanView()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: CarbonLayout.oledCornerRadius, style: .continuous))
        .compositingGroup()
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: CarbonLayout.oledCornerRadius, style: .continuous)
            .fill(theme.oledSurface)
            .overlay(
                RoundedRectangle(cornerRadius: CarbonLayout.oledCornerRadius, style: .continuous)
                    .strokeBorder(theme.oledStrokeInner, lineWidth: 2)
            )
            .overlay(
                Canvas { context, size in
                    var y: CGFloat = 0
                    while y < size.height {
                        let line = Path(CGRect(x: 0, y: y, width: size.width, height: 1))
                        context.fill(line, with: .color(Color.white.opacity(0.018)))
                        y += 3
                    }
                }
                .allowsHitTesting(false)
            )
            .shadow(color: Color.black.opacity(0.5), radius: 6, y: 4)
    }
}

private let oledForeground = Color(red: 0.961, green: 0.945, blue: 0.902)
private let oledMuted = Color.white.opacity(0.55)

private struct NowPlayingView: View {
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.carbon) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Top status row
            HStack {
                NowPlayingTag(active: model.playbackState == .playing)
                if let positionLabel = positionLabel {
                    Text(positionLabel)
                        .font(CarbonFont.mono(10, weight: .medium))
                        .tracking(2)
                        .foregroundStyle(oledMuted)
                }
                Spacer()
                if let formatLabel = formatLabel {
                    Text(formatLabel)
                        .font(CarbonFont.mono(9, weight: .medium))
                        .tracking(2)
                        .foregroundStyle(oledMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .overlay(
                            Capsule().stroke(oledMuted.opacity(0.5), lineWidth: 1)
                        )
                }
            }

            // Headline
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayTrackTitle)
                        .font(CarbonFont.display(28))
                        .tracking(0.5)
                        .foregroundStyle(oledForeground)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(CarbonFont.mono(10, weight: .medium))
                        .tracking(2.2)
                        .textCase(.uppercase)
                        .foregroundStyle(oledMuted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                TimeCapsule(
                    elapsed: model.playbackCurrentTime,
                    total: model.playbackDuration,
                    accent: theme.orange,
                    inkColor: theme.ink
                )
                .frame(width: 220)
            }

            // Bottom stats row
            HStack(spacing: 14) {
                statText(value: "\(model.selectedAlbum?.trackCount ?? model.visibleTracks.count)", label: "TRK")
                Text("·").foregroundStyle(oledMuted.opacity(0.5))
                statText(value: durationString(model.selectedAlbum?.totalDurationSeconds ?? 0), label: "DUR")
                Text("·").foregroundStyle(oledMuted.opacity(0.5))
                statText(value: "\(model.index.albumCount)", label: "ALB")
                Text("·").foregroundStyle(oledMuted.opacity(0.5))
                statText(value: "\(model.index.artists.count)", label: "ART")
                Spacer()
            }
        }
        .padding(.horizontal, CarbonLayout.oledPaddingH)
        .padding(.vertical, CarbonLayout.oledPaddingV)
    }

    private var displayTrackTitle: String {
        let title = model.nowPlayingTrack?.track.title ?? model.selectedTrack?.track.title ?? "—"
        return title.uppercased()
    }

    private var subtitle: String {
        let track = model.nowPlayingTrack ?? model.selectedTrack
        guard let track else { return "Insert media" }
        let parts = [track.track.artist, track.track.album, track.track.year.map(String.init) ?? ""]
            .filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }

    private var positionLabel: String? {
        guard let album = model.selectedAlbum,
              let track = model.nowPlayingTrack ?? model.selectedTrack,
              let index = album.tracks.firstIndex(where: { $0.track.id == track.track.id })
        else { return nil }
        return String(format: "TRK %02d / %02d", index + 1, album.tracks.count)
    }

    private var formatLabel: String? {
        let track = model.nowPlayingTrack ?? model.selectedTrack
        guard let track else { return nil }
        var parts: [String] = []
        if let format = track.track.formatName { parts.append(format.uppercased()) }
        if let sample = track.track.sampleRateHz { parts.append("\(sample / 1000) kHz") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func statText(value: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(CarbonFont.mono(10, weight: .semibold))
                .foregroundStyle(oledForeground)
            Text(label)
                .font(CarbonFont.mono(10, weight: .medium))
                .tracking(1.8)
                .foregroundStyle(oledMuted)
        }
    }

    private func durationString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

private struct NowPlayingTag: View {
    @Environment(\.carbon) private var theme
    let active: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(theme.ink)
                .frame(width: 6, height: 6)
            Text(active ? "NOW PLAYING" : "STANDBY")
                .font(CarbonFont.mono(9, weight: .bold))
                .tracking(1.8)
                .foregroundStyle(theme.ink)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(theme.orange)
        )
    }
}

private struct TimeCapsule: View {
    let elapsed: Double
    let total: Double
    let accent: Color
    let inkColor: Color

    var body: some View {
        ZStack {
            Capsule().fill(accent)

            HStack {
                Text(timeString(elapsed))
                    .font(CarbonFont.mono(12, weight: .semibold))
                    .foregroundStyle(inkColor)
                Spacer()
                Text("-" + timeString(max(0, total - elapsed)))
                    .font(CarbonFont.mono(12, weight: .semibold))
                    .foregroundStyle(inkColor)
            }
            .padding(.horizontal, 14)

            VStack {
                Spacer()
                ProgressDots(progress: progress, ink: inkColor)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
        }
        .frame(height: 44)
    }

    private var progress: Double {
        guard total > 0 else { return 0 }
        return min(max(elapsed / total, 0), 1)
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00" }
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct ProgressDots: View {
    let progress: Double
    let ink: Color
    let segments: Int = 60

    var body: some View {
        Canvas { context, size in
            let segWidth = size.width / CGFloat(segments)
            let nowIndex = Int(Double(segments) * progress)
            for i in 0..<segments {
                let x = CGFloat(i) * segWidth
                let isFilled = i < nowIndex
                let isNow = i == nowIndex
                let height: CGFloat = isNow ? 6 : (isFilled ? 2 : 1.5)
                let y = (size.height - height) / 2
                let rect = CGRect(x: x + 0.5, y: y, width: max(1, segWidth - 1), height: height)
                let opacity: Double = isNow ? 1 : (isFilled ? 0.95 : 0.35)
                context.fill(Path(rect), with: .color(ink.opacity(opacity)))
            }
        }
    }
}

private struct VUView: View {
    var body: some View {
        VStack(spacing: 6) {
            Text("V U")
                .font(CarbonFont.display(36))
                .tracking(4)
                .foregroundStyle(oledForeground)
            Text("METERS · LIVE")
                .font(CarbonFont.mono(10, weight: .medium))
                .tracking(2)
                .foregroundStyle(oledMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ConversionView: View {
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CONVERT")
                .font(CarbonFont.display(26))
                .tracking(2)
                .foregroundStyle(oledForeground)
            if model.conversionProgress.isRunning {
                Text("Job \(model.conversionProgress.jobsCompleted) / \(model.conversionProgress.jobsTotal)")
                    .font(CarbonFont.mono(10, weight: .medium))
                    .foregroundStyle(oledMuted)
                if let name = model.conversionProgress.currentFilename {
                    Text(name)
                        .font(CarbonFont.mono(10))
                        .foregroundStyle(oledForeground)
                        .lineLimit(1)
                }
            } else {
                Text("Idle. No queue.")
                    .font(CarbonFont.mono(10))
                    .foregroundStyle(oledMuted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, CarbonLayout.oledPaddingH)
        .padding(.vertical, CarbonLayout.oledPaddingV)
    }
}

private struct ScanView: View {
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SCAN")
                .font(CarbonFont.display(26))
                .tracking(2)
                .foregroundStyle(oledForeground)
            if model.scanProgress.isRunning {
                if let name = model.scanProgress.folderName {
                    Text(name)
                        .font(CarbonFont.mono(10))
                        .foregroundStyle(oledForeground)
                        .lineLimit(1)
                }
                Text("\(model.scanProgress.filesProbed) files probed")
                    .font(CarbonFont.mono(10, weight: .medium))
                    .foregroundStyle(oledMuted)
            } else if model.index.allTracks.isEmpty {
                Text("Library empty. ⌘O to load a folder.")
                    .font(CarbonFont.mono(10))
                    .foregroundStyle(oledMuted)
            } else {
                Text("\(model.index.allTracks.count) tracks · \(model.index.albumCount) albums")
                    .font(CarbonFont.mono(10))
                    .foregroundStyle(oledMuted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, CarbonLayout.oledPaddingH)
        .padding(.vertical, CarbonLayout.oledPaddingV)
    }
}
