import CrateDiggerCore
import SwiftUI

/// Right-column "Conversion · Patch Bay" replacement for the inspector.
/// Renders the design from `CrateDigger v4 Convert.html` — all selection
/// state lives on `LibraryViewModel.conversionSelection` so the legacy
/// sheet path and the patch bay stay in sync. Switch primitives live in
/// `PatchBayControls.swift`.
struct ConvertPatchBay: View {
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry
    @EnvironmentObject private var model: LibraryViewModel

    @State private var keepTags: Bool = true
    @State private var replayGain: Bool = true
    @State private var overwriteExisting: Bool = false
    @State private var ejectAfter: Bool = false
    /// Measured height of the scrollable settings rows, vs. the viewport, so a
    /// discrete "more below" fade appears only when a row is scrolled out of sight.
    @State private var patchContentHeight: CGFloat = 0

    var body: some View {
        // The settings rows scroll; the arm block (queue readout + Cancel /
        // Convert) is pinned below the scroller so the two critical buttons
        // are always on screen — on short panels they used to scroll out of
        // view with no indicator hinting they existed.
        VStack(spacing: 0) {
            GeometryReader { viewport in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: geometry.patchBayRowGap) {
                        if !model.browserCollapsed { roomHint }
                        scopeRow
                        formatRow
                        bitrateRow
                        sampleRow
                        layoutRow
                        patternRow
                        destRow
                        optsRow
                    }
                    .padding(EdgeInsets(top: 14, leading: 14, bottom: 10, trailing: 14))
                    .frame(maxWidth: .infinity, alignment: .top)
                    .background(
                        GeometryReader { content in
                            Color.clear.preference(key: PatchContentHeightKey.self, value: content.size.height)
                        }
                    )
                }
                .onPreferenceChange(PatchContentHeightKey.self) { patchContentHeight = $0 }
                .overlay(alignment: .bottom) {
                    if patchContentHeight > viewport.size.height + 1 {
                        scrollMoreIndicator
                    }
                }
            }

            armBlock
                .padding(EdgeInsets(top: 6, leading: 14, bottom: 14, trailing: 14))
        }
        .background(panelBackground)
    }

    /// A discrete "there's more below" cue: the last visible rows fade into the
    /// panel with a soft chevron. Never intercepts scrolling.
    private var scrollMoreIndicator: some View {
        LinearGradient(
            colors: [theme.paper.opacity(0), theme.paper.opacity(theme.isDark ? 0.92 : 0.96)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 24)
        .overlay(alignment: .bottom) {
            Image(systemName: "chevron.compact.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.ink3)
                .padding(.bottom, 2)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Background glass with horizontal scan lines

    private var panelBackground: some View {
        ZStack {
            Rectangle()
                .fill(theme.paper) // opaque, not Material — see ChassisLayer
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

    // MARK: - Room hint

    /// The patch bay is usable at the default inspector width, but it's cramped.
    /// Rather than auto-collapsing the browser on every CNVRT switch (a slow,
    /// GPU-heavy relayout), we leave it compact and offer a one-tap way in. Shown
    /// only while the browser is open — once collapsed there's nothing to gain.
    private var roomHint: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.25)) { model.browserCollapsed = true }
        }) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.cyan)
                Text("Collapse the browser for a roomier patch bay")
                    .font(CarbonFont.mono(9, weight: .medium))
                    .foregroundStyle(theme.ink3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 6)
                Text("EXPAND")
                    .font(CarbonFont.mono(8.5, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(theme.cyan)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.cyan.opacity(theme.isDark ? 0.10 : 0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(theme.cyan.opacity(0.30), lineWidth: 0.8)
            )
        }
        .buttonStyle(.carbonHover)
        .carbonTip("Collapse the browser pane to widen the conversion panel")
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
            // Freeform: drag tags to reorder, toggle `/`↔`·` to shape folders.
            FolderPatternEditor(
                tokenOrder: Binding(
                    get: { model.conversionSelection.tokenOrder },
                    set: { model.conversionSelection.tokenOrder = $0 }
                ),
                separators: Binding(
                    get: { model.conversionSelection.separators },
                    set: { model.conversionSelection.separators = $0 }
                ),
                preset: Binding(
                    get: { model.conversionSelection.templatePreset },
                    set: { model.conversionSelection.templatePreset = $0 }
                )
            )
            .disabled(model.conversionSelection.folderStructureMode != .metadataTemplate)
            .opacity(model.conversionSelection.folderStructureMode == .metadataTemplate ? 1 : 0.72)
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
                        // the inspector so the user has an obvious way out. Drop
                        // any pending send-to-device hand-off (and restore the
                        // pre-device conversion selection).
                        model.clearPendingDeviceConversion()
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
            .frame(height: 50)
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

private struct PatchContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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
            .buttonStyle(.carbonHover)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(
                    // Stay dark in both themes (the head text is white .45 and the
                    // tail is cyan — both wash out on the light-grey linen recess).
                    LinearGradient(
                        colors: [Color(hex: 0x1C2228), Color(hex: 0x0A0E12)],
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
        .buttonStyle(.carbonHover)
        .accessibilityLabel(Text("Cancel"))
    }
}

// MARK: - Illuminated CONVERT button (press & hold)

private struct ArmGoButton: View {
    @Environment(\.carbon) private var theme
    let enabled: Bool
    let action: () -> Void

    @State private var holdProgress: Double = 0

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
        // A plain onLongPressGesture survives the enclosing ScrollView, unlike a
        // minimumDistance-0 DragGesture (which the scroll view swallowed, leaving
        // Convert unresponsive). Pressing fills the hazard bar over the hold;
        // releasing early resets it.
        .onLongPressGesture(minimumDuration: 0.7, maximumDistance: 80) {
            guard enabled else { return }
            holdProgress = 0
            action()
        } onPressingChanged: { pressing in
            withAnimation(.linear(duration: pressing ? 0.7 : 0.15)) {
                holdProgress = (pressing && enabled) ? 1 : 0
            }
        }
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
