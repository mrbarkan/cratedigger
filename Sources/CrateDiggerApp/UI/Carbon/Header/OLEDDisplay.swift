import SwiftUI

struct OLEDDisplay: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            background

            Group {
                switch model.oledView {
                case .nowPlaying: NowPlayingView()
                case .vu:         VUView()
                case .conversion: ConversionView()
                case .scan:       ScanView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

            VStack(spacing: 5) {
                HStack {
                    Text(timeString(elapsed))
                        .font(CarbonFont.mono(12, weight: .semibold))
                        .foregroundStyle(inkColor)
                    Spacer()
                    Text("-" + timeString(max(0, total - elapsed)))
                        .font(CarbonFont.mono(12, weight: .semibold))
                        .foregroundStyle(inkColor)
                }

                ProgressDots(progress: progress, ink: inkColor)
                    .frame(height: 6)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 9)
        }
        .frame(height: 52)
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
    @Environment(\.carbon) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            topRow
            pipelineRow
            readoutCells
                .frame(maxHeight: .infinity)
            ticker
        }
        .padding(.horizontal, CarbonLayout.oledPaddingH)
        .padding(.vertical, CarbonLayout.oledPaddingV)
    }

    // MARK: - Top status row

    private var topRow: some View {
        HStack(spacing: 14) {
            armedTag

            Text(queueLabel)
                .font(CarbonFont.mono(10, weight: .medium))
                .tracking(1.8)
                .foregroundStyle(oledMuted)

            Text(estimateLabel)
                .font(CarbonFont.mono(10, weight: .medium))
                .tracking(1.8)
                .foregroundStyle(oledMuted)

            Spacer()

            Text(durationLabel)
                .font(CarbonFont.mono(10, weight: .medium))
                .tracking(1.8)
                .foregroundStyle(oledMuted)
        }
    }

    // MARK: - Pipeline row (source → target, full-width banner)

    private var pipelineRow: some View {
        HStack(spacing: 14) {
            // Source side — dim/historic
            VStack(alignment: .leading, spacing: 1) {
                Text(sourceFormatPrimary)
                    .font(CarbonFont.display(20))
                    .tracking(0.4)
                    .foregroundStyle(oledForeground.opacity(0.55))
                    .lineLimit(1)
                Text(sourceFormatSpec)
                    .font(CarbonFont.mono(8.5, weight: .semibold))
                    .tracking(2)
                    .foregroundStyle(oledForeground.opacity(0.4))
                    .lineLimit(1)
            }

            // Arrow
            Text("►")
                .font(CarbonFont.display(22))
                .foregroundStyle(theme.orange)
                .shadow(color: theme.orange.opacity(0.6), radius: 4)

            // Target side — bright/current selection
            VStack(alignment: .leading, spacing: 1) {
                Text(targetFormatPrimary)
                    .font(CarbonFont.display(20))
                    .tracking(0.4)
                    .foregroundStyle(oledForeground)
                    .lineLimit(1)
                Text(targetFormatSpec)
                    .font(CarbonFont.mono(8.5, weight: .semibold))
                    .tracking(2)
                    .foregroundStyle(oledForeground.opacity(0.6))
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.vertical, 2)
        .overlay(
            Rectangle()
                .fill(oledForeground.opacity(0.12))
                .frame(height: 1)
                .padding(.top, 2),
            alignment: .bottom
        )
    }

    private var sourceFormatPrimary: String {
        sourceFormatLabel().uppercased()
    }

    private var sourceFormatSpec: String {
        // Best-effort: median sample-rate / bit-depth across queued tracks.
        // Falls back to "—" when the queue is empty.
        let tracks = model.conversionQueueTracks
        guard !tracks.isEmpty else { return "—" }
        let rates = tracks.compactMap { $0.track.sampleRateHz }
        guard let first = rates.first else { return "" }
        let kHz = Double(first) / 1000.0
        let formatted = first % 1000 == 0 ? "\(first / 1000)" : String(format: "%.1f", kHz)
        return "16-BIT · \(formatted) kHz".uppercased()
    }

    private var targetFormatPrimary: String {
        formatValue
    }

    private var targetFormatSpec: String {
        if model.isLosslessSelectedFormat {
            return "LOSSLESS · \(sampleValue) kHz"
        }
        let bitrate = model.conversionSelection.bitrate ?? 192
        return "\(bitrate) kbps · \(sampleValue) kHz"
    }

    private var armedTag: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(armedTagInk)
                .frame(width: 6, height: 6)
            Text(armedTagText)
                .font(CarbonFont.mono(9, weight: .bold))
                .tracking(1.8)
                .foregroundStyle(armedTagInk)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(armedTagBackground))
    }

    private var armedTagText: String {
        if model.conversionProgress.isRunning {
            return "CONVERT · RUNNING"
        }
        if model.conversionQueueTracks.isEmpty {
            return "CONVERT · IDLE"
        }
        return "CONVERT · ARMED"
    }

    private var armedTagBackground: Color {
        if model.conversionProgress.isRunning { return theme.cyan }
        if model.conversionQueueTracks.isEmpty { return Color(hex: 0x3A3A37) }
        return theme.red
    }

    private var armedTagInk: Color {
        if model.conversionQueueTracks.isEmpty && !model.conversionProgress.isRunning {
            return oledMuted
        }
        return Color(hex: 0xFFF1EC)
    }

    // MARK: - Readout cells

    private var readoutCells: some View {
        HStack(alignment: .center, spacing: 0) {
            cell(key: "Scope", value: scopeValue, sub: scopeSub)
            divider
            cell(key: "Format", value: formatValue, sub: formatSub)
            divider
            cell(key: "Bitrate", value: bitrateValue, sub: "KBPS · CBR")
            divider
            cell(key: "Sample", value: sampleValue, sub: "KHZ · 16-BIT")
            divider
            cell(key: "Output", value: outputValue, sub: outputSub, small: true)
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func cell(key: String, value: String, sub: String, small: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(key.uppercased())
                .font(CarbonFont.mono(8.5, weight: .semibold))
                .tracking(2.2)
                .foregroundStyle(oledForeground.opacity(0.45))
            Text(value)
                .font(small ? CarbonFont.mono(13, weight: .semibold) : CarbonFont.display(22))
                .tracking(0.4)
                .foregroundStyle(oledForeground)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(sub.uppercased())
                .font(CarbonFont.mono(8.5, weight: .semibold))
                .tracking(1.8)
                .foregroundStyle(oledForeground.opacity(0.55))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 14)
    }

    private var divider: some View {
        Rectangle()
            .fill(oledForeground.opacity(0.12))
            .frame(width: 1)
    }

    // MARK: - Path ticker

    private var ticker: some View {
        HStack(spacing: 12) {
            Text(tickerPrefix)
                .font(CarbonFont.mono(8.5, weight: .semibold))
                .tracking(2.2)
                .foregroundStyle(oledForeground.opacity(0.5))

            Text(tickerPath)
                .font(CarbonFont.mono(10))
                .tracking(0.6)
                .foregroundStyle(theme.orange)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(tickerMeta)
                .font(CarbonFont.mono(9, weight: .semibold))
                .tracking(1.8)
                .foregroundStyle(oledForeground.opacity(0.5))
        }
        .padding(.top, 4)
        .overlay(
            Rectangle()
                .fill(oledForeground.opacity(0.12))
                .frame(height: 1)
                .padding(.top, 0),
            alignment: .top
        )
    }

    // MARK: - Computed labels

    private var queueLabel: String {
        let count = model.conversionQueueTracks.count
        return count == 0 ? "QUEUE EMPTY" : "QUEUE \(count) TRK"
    }

    private var estimateLabel: String {
        let bytes = model.conversionEstimatedOutputBytes
        if bytes <= 0 { return "EST. —" }
        let mb = Double(bytes) / 1_048_576.0
        if mb >= 1024 {
            return String(format: "EST. %.1f GB", mb / 1024.0)
        }
        return String(format: "EST. %.0f MB", mb)
    }

    private var durationLabel: String {
        let s = model.conversionQueueDurationSeconds
        guard s > 0 else { return "—" }
        let total = Int(s.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let sec = total % 60
        if h > 0 { return String(format: "~%d:%02d:%02d", h, m, sec) }
        return String(format: "~%d:%02d", m, sec)
    }

    private var scopeValue: String {
        let count = model.conversionQueueTracks.count
        return "\(count) TRK"
    }

    private var scopeSub: String {
        switch model.conversionSelection.batchScope {
        case .selectedTracks: return "Selected"
        case .currentAlbum:   return "Album"
        case .allLoadedTracks: return "All Loaded"
        }
    }

    private var formatValue: String {
        switch model.conversionSelection.outputFormat {
        case .mp3:  return "MP3"
        case .aac:  return "AAC"
        case .alac: return "ALAC"
        case .flac: return "FLAC"
        case .wav:  return "WAV"
        case .aiff: return "AIFF"
        case .ogg:  return "OGG"
        case .opus: return "OPUS"
        }
    }

    private var formatSub: String {
        switch model.conversionSelection.outputFormat {
        case .aac, .alac: return "M4A · " + (model.isLosslessSelectedFormat ? "LOSSLESS" : "LOSSY")
        case .mp3, .ogg, .opus: return model.conversionSelection.outputFormat.fileExtension.uppercased() + " · LOSSY"
        case .flac: return "FLAC · LOSSLESS"
        case .wav, .aiff: return model.conversionSelection.outputFormat.fileExtension.uppercased() + " · PCM"
        }
    }

    private var bitrateValue: String {
        if model.isLosslessSelectedFormat { return "—" }
        return "\(model.conversionSelection.bitrate ?? 192)"
    }

    private var sampleValue: String {
        let hz = model.conversionSelection.sampleRate ?? 44_100
        if hz % 1000 == 0 { return "\(hz / 1000)" }
        return String(format: "%.1f", Double(hz) / 1000.0)
    }

    private var outputValue: String {
        let bytes = model.conversionEstimatedOutputBytes
        if bytes <= 0 { return "—" }
        let mb = Double(bytes) / 1_048_576.0
        if mb >= 1024 {
            return String(format: "~%.1f GB", mb / 1024.0)
        }
        return String(format: "~%.1f MB", mb)
    }

    private var outputSub: String {
        let count = model.conversionQueueTracks.count
        if count == 0 { return "NO QUEUE" }
        return "\(count) TRACKS"
    }

    private func sourceFormatLabel() -> String {
        let formats = Set(model.conversionQueueTracks.compactMap { $0.track.formatName?.uppercased() })
        if formats.isEmpty { return "—" }
        if formats.count == 1, let only = formats.first { return only }
        return "MIX (\(formats.count))"
    }

    // MARK: - Ticker

    private var tickerPrefix: String {
        let count = model.conversionQueueTracks.count
        if count == 0 { return "PREVIEW · —" }
        return String(format: "PREVIEW · 01 / %02d", count)
    }

    private var tickerPath: AttributedString {
        var out = AttributedString("")
        let head = "~/Music/CrateDigger Library/"
        var headSeg = AttributedString(head)
        headSeg.foregroundColor = theme.orange
        out.append(headSeg)

        if let preview = model.conversionQueueTracks.first {
            let albumPart = "\(preview.track.artist)/\(preview.track.year.map(String.init) ?? "—") \(preview.track.album)/"
            var albumSeg = AttributedString(albumPart)
            albumSeg.foregroundColor = Color(hex: 0xFFD1BD)
            out.append(albumSeg)

            let ext = model.conversionSelection.outputFormat.fileExtension
            let trackNum = String(format: "%02d", preview.track.trackNumber ?? 1)
            let titlePart = "\(trackNum) \(preview.track.title).\(ext)"
            var titleSeg = AttributedString(titlePart)
            titleSeg.foregroundColor = theme.orange
            out.append(titleSeg)
        }
        return out
    }

    private var tickerMeta: String {
        switch model.conversionSelection.folderStructureMode {
        case .sourceRelative:  return "LAYOUT · SOURCE"
        case .flat:            return "LAYOUT · FLAT"
        case .metadataTemplate: return "TEMPLATE · {ARTIST}/{YEAR} {ALBUM}"
        }
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
