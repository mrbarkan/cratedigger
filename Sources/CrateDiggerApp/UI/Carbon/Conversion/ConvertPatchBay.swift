import CrateDiggerCore
import SwiftUI

/// Right-column "Conversion · Patch Bay" replacement for the inspector.
/// Renders the design from `CrateDigger v4 Convert.html` — all selection
/// state lives on `LibraryViewModel.conversionSelection` so the legacy
/// sheet path and the patch bay stay in sync. Switch primitives live in
/// `PatchBayControls.swift`.
struct ConvertPatchBay: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    @State private var keepTags: Bool = true
    @State private var replayGain: Bool = true
    @State private var overwriteExisting: Bool = false
    @State private var ejectAfter: Bool = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: CarbonLayout.patchBayRowGap) {
                scopeRow
                formatRow
                bitrateRow
                sampleRow
                layoutRow
                patternRow
                destRow
                optsRow
                Spacer(minLength: 4)
                armBlock
            }
            .padding(EdgeInsets(top: 14, leading: 14, bottom: 16, trailing: 14))
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(panelBackground)
    }

    // MARK: - Background glass with horizontal scan lines

    private var panelBackground: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            theme.paper.opacity(theme.isDark ? 0.70 : 0.78),
                            theme.paper2.opacity(theme.isDark ? 0.58 : 0.66)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            // Horizontal scan-line texture (1px every 28px)
            Scanlines(opacity: theme.isDark ? 0.012 : 0.04, spacing: 28)
        }
    }

    // MARK: - Rows

    private var scopeRow: some View {
        cvRow("Scope") {
            PatchBayBank(
                label: "Scope",
                options: ConversionBatchScope.allCases,
                selection: $model.conversionSelection.batchScope,
                size: .medium,
                displayText: scopeLabel,
                subText: scopeSub
            )
        }
    }

    private var formatRow: some View {
        cvRow("Format") {
            PatchBayBank(
                label: "Format",
                options: formatOptions,
                selection: $model.conversionSelection.outputFormat,
                size: .small,
                displayText: formatLabel
            )
        }
    }

    private var bitrateRow: some View {
        cvRow("Bitrate") {
            PatchBayBank(
                label: "Bitrate",
                options: bitrateOptions,
                selection: bitrateBinding,
                size: .small,
                isDisabled: { _ in model.isLosslessSelectedFormat },
                displayText: { "\($0)" }
            )
        }
    }

    private var sampleRow: some View {
        cvRow("Sample") {
            PatchBayBank(
                label: "Sample",
                options: sampleRateOptions,
                selection: sampleBinding,
                size: .small,
                displayText: sampleLabel
            )
        }
    }

    private var layoutRow: some View {
        cvRow("Layout") {
            PatchBayBank(
                label: "Layout",
                options: FolderStructureMode.allCases,
                selection: $model.conversionSelection.folderStructureMode,
                size: .medium,
                displayText: layoutLabel
            )
        }
    }

    private var patternRow: some View {
        cvRow("Pattern") {
            TemplateStrip(text: templateString)
                .opacity(model.conversionSelection.folderStructureMode == .metadataTemplate ? 1 : 0.55)
        }
    }

    private var destRow: some View {
        cvRow("Dest") {
            DestStrip(
                path: model.conversionDestinationDisplayPath,
                onChoose: { model.chooseConversionDestinationViaPanel() }
            )
        }
    }

    private var optsRow: some View {
        cvRow("Opts") {
            // Paddles are visual stubs — the conversion pipeline doesn't
            // consume these flags yet. Wired here so the panel matches the
            // design without introducing dead model state. Promote to
            // backing prefs as the pipeline grows to honor them.
            let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                paddleOption(label: "Keep tags", sub: "ID3 + ART", isOn: $keepTags)
                paddleOption(label: "Replay-Gain", sub: "ALBUM", isOn: $replayGain)
                paddleOption(label: "Overwrite", sub: "SKIP DUPES", isOn: $overwriteExisting)
                paddleOption(label: "Eject after", sub: "UNMOUNT", isOn: $ejectAfter)
            }
        }
    }

    // MARK: - Arm block

    private var armBlock: some View {
        VStack(spacing: 8) {
            HStack {
                Text(armMetaLeft)
                    .font(CarbonFont.mono(9, weight: .bold))
                    .tracking(2.2)
                    .foregroundStyle(theme.ink3)
                    .lineLimit(1)
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Circle().fill(armReadyColor).frame(width: 6, height: 6)
                    Text(armReadyLabel)
                        .font(CarbonFont.mono(9, weight: .bold))
                        .tracking(2.2)
                        .foregroundStyle(armReadyColor)
                }
            }
            .padding(.horizontal, 4)

            HStack(spacing: 10) {
                ArmCancelButton {
                    if model.conversionProgress.isRunning {
                        model.cancelConversion()
                    } else {
                        // No active job — Cancel exits convert mode back to
                        // the inspector so the user has an obvious way out.
                        model.oledView = .nowPlaying
                    }
                }
                .frame(maxWidth: .infinity)

                ArmGoButton(
                    enabled: armEnabled
                ) {
                    if armEnabled {
                        model.triggerConversionFromPatchBay()
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 56)
        }
    }

    private var armEnabled: Bool {
        !model.conversionProgress.isRunning && !model.conversionQueueTracks.isEmpty
    }

    private var armReadyColor: Color {
        if model.conversionProgress.isRunning { return theme.cyan }
        if model.conversionQueueTracks.isEmpty { return theme.ink4 }
        return theme.orange
    }

    private var armReadyLabel: String {
        if model.conversionProgress.isRunning { return "● RUNNING" }
        if model.conversionQueueTracks.isEmpty { return "● EMPTY" }
        return "● READY"
    }

    private var armMetaLeft: String {
        let count = model.conversionQueueTracks.count
        let bytes = formatBytes(model.conversionEstimatedOutputBytes)
        let dur = formatHHMMSS(model.conversionQueueDurationSeconds)
        return "QUEUE · \(count) TRK · \(bytes) · \(dur)"
    }

    // MARK: - Row scaffolding

    @ViewBuilder
    private func cvRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label.uppercased())
                .font(CarbonFont.mono(8.5, weight: .bold))
                .tracking(1.9)
                .foregroundStyle(theme.ink3)
                .frame(width: 56, alignment: .trailing)
                .padding(.trailing, 8)
                .overlay(
                    Rectangle()
                        .fill(theme.hair.opacity(0.7))
                        .frame(width: 1)
                        .padding(.vertical, 2),
                    alignment: .trailing
                )
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func paddleOption(label: String, sub: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            PatchBayPaddle(isOn: isOn)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(CarbonFont.mono(10, weight: .medium))
                    .foregroundStyle(theme.ink)
                Text(sub.uppercased())
                    .font(CarbonFont.mono(8.5, weight: .semibold))
                    .tracking(1.6)
                    .foregroundStyle(theme.ink3)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Bindings (Optional → required for binding)

    private var bitrateBinding: Binding<Int> {
        Binding(
            get: { model.conversionSelection.bitrate ?? 192 },
            set: { model.conversionSelection.bitrate = $0 }
        )
    }

    private var sampleBinding: Binding<Int> {
        Binding(
            get: { model.conversionSelection.sampleRate ?? 44_100 },
            set: { model.conversionSelection.sampleRate = $0 }
        )
    }

    // MARK: - Selection options

    private let formatOptions: [OutputFormat] = [.mp3, .aac, .alac, .flac, .wav, .opus]
    private let bitrateOptions: [Int] = [96, 128, 160, 192, 256, 320]
    private let sampleRateOptions: [Int] = [32_000, 44_100, 48_000, 96_000]

    // MARK: - Display strings

    private func scopeLabel(_ scope: ConversionBatchScope) -> String {
        switch scope {
        case .selectedTracks:  return "SEL"
        case .currentAlbum:    return "ALBUM"
        case .allLoadedTracks: return "ALL"
        }
    }

    private func scopeSub(_ scope: ConversionBatchScope) -> String? {
        switch scope {
        case .selectedTracks:  return shortCount(model.visibleTracks.count)
        case .currentAlbum:    return shortCount(model.selectedAlbum?.trackCount ?? 0)
        case .allLoadedTracks: return shortCount(model.index.allTracks.count)
        }
    }

    private func formatLabel(_ format: OutputFormat) -> String {
        switch format {
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

    private func sampleLabel(_ hz: Int) -> String {
        if hz % 1000 == 0 { return "\(hz / 1000)K" }
        return String(format: "%.1fK", Double(hz) / 1000.0)
    }

    private func layoutLabel(_ mode: FolderStructureMode) -> String {
        switch mode {
        case .sourceRelative:   return "SOURCE"
        case .flat:             return "FLAT"
        case .metadataTemplate: return "TEMPLATE"
        }
    }

    private var templateString: String {
        // Visual readout for the user's selected preset. Matches the strip
        // in the design: tokens are colored, separators ink-1.
        switch model.conversionSelection.templatePreset {
        case .artistYearAlbum:
            return "{albumartist}/{year} {album}/{track} {title}"
        case .yearArtistAlbum:
            return "{year}/{albumartist}/{album}/{track} {title}"
        case .artistAlbumYear:
            return "{albumartist}/{album} {year}/{track} {title}"
        case .custom:
            return "(custom token order)"
        }
    }

    private func shortCount(_ n: Int) -> String {
        if n == 0 { return "—" }
        if n >= 1000 { return String(format: "%.1fK", Double(n) / 1000.0) }
        return "\(n)"
    }

    private func formatBytes(_ b: Int64) -> String {
        if b <= 0 { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: b)
    }

    private func formatHHMMSS(_ s: Double) -> String {
        guard s.isFinite, s > 0 else { return "—" }
        return s.asClockHMS
    }
}

// MARK: - Yellow label-maker template strip
//
// Stays sun-yellow in both themes — it's a labelmaker tape, theme-agnostic.

private struct TemplateStrip: View {
    let text: String
    var body: some View {
        Text(formatted)
            .font(CarbonFont.mono(10.5, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: 0xF5CB5C), Color(hex: 0xC9A23A)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(Color.white.opacity(0.4), lineWidth: 1)
                    .blendMode(.plusLighter)
                    .padding(0.5)
            )
            .shadow(color: Color.black.opacity(0.5), radius: 1, y: 1)
    }

    /// Color-tint variables (the {token} parts) like the design. Tokens
    /// render in deep red-orange; separators stay near-black on yellow.
    private var formatted: AttributedString {
        var out = AttributedString("")
        let baseColor = Color(hex: 0x1A1209)
        let varColor = Color(hex: 0xD65428)
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "{" {
                if let close = text[i...].firstIndex(of: "}") {
                    let token = String(text[i...close])
                    var seg = AttributedString(token)
                    seg.foregroundColor = varColor
                    out.append(seg)
                    i = text.index(after: close)
                    continue
                }
            }
            var seg = AttributedString(String(text[i]))
            seg.foregroundColor = baseColor
            out.append(seg)
            i = text.index(after: i)
        }
        return out
    }
}

// MARK: - OLED-style "tape strip" destination

private struct DestStrip: View {
    @Environment(\.carbon) private var theme
    let path: String
    let onChoose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(formattedPath)
                .font(CarbonFont.mono(10.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onChoose) {
                Text("CHOOSE…")
                    .font(CarbonFont.mono(9, weight: .bold))
                    .tracking(1.8)
                    .foregroundStyle(theme.isDark ? theme.cyanGlow : theme.ink)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [theme.metalHi, theme.metal, theme.metalLo],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .stroke(Color.white.opacity(theme.isDark ? 0.10 : 0.45), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.4), radius: 1, y: 1)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [theme.wellDeep, theme.metalDeep],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Color.black.opacity(theme.isDark ? 0.9 : 0.5), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(theme.isDark ? 0.6 : 0.2), radius: 1, y: 1)
    }

    private var formattedPath: AttributedString {
        // Split on the first "/" group ending so "~/Music/" reads dim and the
        // rest is luminous cyan, matching the design's `.seg` highlight.
        let homePart: String
        let rest: String
        if path.hasPrefix("~/") {
            if let slash = path.dropFirst(2).firstIndex(of: "/") {
                let head = String(path[..<path.index(slash, offsetBy: 1)])
                homePart = head
                rest = String(path[path.index(slash, offsetBy: 1)...])
            } else {
                homePart = path
                rest = ""
            }
        } else {
            homePart = ""
            rest = path
        }
        var out = AttributedString("")
        if !homePart.isEmpty {
            var seg = AttributedString(homePart)
            // Recess is dark in both themes, so dim head reads as dim cyan/ink.
            seg.foregroundColor = Color.white.opacity(0.45)
            out.append(seg)
        }
        if !rest.isEmpty {
            var seg = AttributedString(rest)
            seg.foregroundColor = theme.cyan
            out.append(seg)
        }
        return out
    }
}

// MARK: - Cancel button

private struct ArmCancelButton: View {
    @Environment(\.carbon) private var theme
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text("CANCEL")
                .font(CarbonFont.mono(10, weight: .bold))
                .tracking(2.2)
                .foregroundStyle(theme.ink2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: theme.isDark
                                    ? [theme.metalHi, theme.metalLo]
                                    : [theme.chassisHi, theme.chassisLo],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(theme.isDark ? 0.08 : 0.45), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(theme.isDark ? 0.5 : 0.2), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Cancel"))
    }
}

// MARK: - Illuminated CONVERT button (press & hold)

private struct ArmGoButton: View {
    @Environment(\.carbon) private var theme
    let enabled: Bool
    let action: () -> Void

    @State private var holdProgress: Double = 0
    @State private var holdTimer: Timer?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: enabled
                            ? [theme.orangeHi, theme.orange, theme.orangeLo]
                            : [theme.metalHi.opacity(0.6), theme.metalLo.opacity(0.6)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.black.opacity(0.15), lineWidth: 1)
                .padding(4)

            // Hazard fill that grows with hold progress so the user gets
            // feedback that they're arming the convert.
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.black.opacity(0.18))
                    .frame(width: geo.size.width * holdProgress)
                    .animation(.linear(duration: 0.05), value: holdProgress)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .blendMode(.multiply)

            // At narrow widths, drop the PRESS & HOLD subtitle and the right
            // ARM cluster — the press-and-hold gesture itself stays alive.
            ViewThatFits(in: .horizontal) {
                wideContent
                compactContent
            }
            .padding(.horizontal, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .shadow(color: enabled ? theme.orange.opacity(0.45) : .clear, radius: 14, y: 0)
        .shadow(color: Color.black.opacity(0.5), radius: 4, y: 2)
        .opacity(enabled ? 1 : 0.55)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard enabled, holdTimer == nil else { return }
                    holdProgress = 0
                    let duration: Double = 0.7
                    let tickInterval: Double = 0.03
                    holdTimer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { timer in
                        DispatchQueue.main.async {
                            holdProgress += tickInterval / duration
                            if holdProgress >= 1 {
                                timer.invalidate()
                                holdTimer = nil
                                holdProgress = 0
                                action()
                            }
                        }
                    }
                }
                .onEnded { _ in
                    holdProgress = 0
                    holdTimer?.invalidate()
                    holdTimer = nil
                }
        )
        .accessibilityLabel(Text("Convert"))
        .accessibilityHint(Text("Press and hold to start converting"))
    }

    @ViewBuilder
    private var wideContent: some View {
        HStack(spacing: 10) {
            playGlyph
            VStack(spacing: 2) {
                Text("CONVERT")
                    .font(CarbonFont.mono(14, weight: .black))
                    .tracking(3.2)
                Text("PRESS & HOLD")
                    .font(CarbonFont.mono(8.5, weight: .bold))
                    .tracking(3.2)
                    .foregroundStyle(Color(hex: 0x1A1209).opacity(0.7))
            }
            .foregroundStyle(Color(hex: 0x1A1209))
            .frame(maxWidth: .infinity)

            armCluster
        }
    }

    @ViewBuilder
    private var compactContent: some View {
        HStack(spacing: 10) {
            playGlyph
            Text("CONVERT")
                .font(CarbonFont.mono(13, weight: .black))
                .tracking(2.6)
                .foregroundStyle(Color(hex: 0x1A1209))
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var playGlyph: some View {
        ZStack {
            Circle().fill(Color(hex: 0x1A1209))
            Text("▸")
                .font(CarbonFont.mono(13, weight: .black))
                .foregroundStyle(theme.orangeHi)
        }
        .frame(width: 22, height: 22)
        .shadow(color: Color.black.opacity(0.4), radius: 1, y: 1)
    }

    @ViewBuilder
    private var armCluster: some View {
        VStack(spacing: 2) {
            Circle()
                .fill(holdProgress > 0 ? Color(hex: 0xFFD1BD) : Color(hex: 0x1A1209))
                .frame(width: 8, height: 8)
                .shadow(color: holdProgress > 0 ? Color(hex: 0xFFD1BD) : .clear, radius: 4)
            Text("ARM")
                .font(CarbonFont.mono(9, weight: .bold))
                .tracking(1.8)
                .foregroundStyle(Color(hex: 0x1A1209).opacity(0.7))
        }
    }
}
