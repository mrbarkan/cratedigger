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

    /// Which face of the patch bay is showing. Mirrors the inspector's tab
    /// switcher so the two panes are operated the same way.
    private enum PatchTab: String, CaseIterable {
        case queue = "QUEUE"
        case settings = "SETTINGS"
        case options = "OPTIONS"
    }

    @State private var activeTab: PatchTab = .settings

    var body: some View {
        // The tab contents scroll; the arm block (queue readout + Cancel /
        // Convert) is pinned below the scroller so the two critical buttons
        // are always on screen — on short panels they used to scroll out of
        // view with no indicator hinting they existed.
        VStack(spacing: 0) {
            tabSwitcher
            GeometryReader { viewport in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: geometry.patchBayRowGap) {
                        tabContent
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

    private var tabSwitcher: some View {
        HStack(spacing: 8) {
            ForEach(PatchTab.allCases, id: \.self) { tab in
                KeyButton(style: activeTab == tab ? .selected : .normal,
                          action: { activeTab = tab }) {
                    Text(tab.rawValue)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 22)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch activeTab {
        case .queue:
            ConversionQueueView()
                .frame(minHeight: 220)
        case .settings:
            scopeRow
            presetChipRow
            formatRow
            bitrateRow
            sampleRow
            layoutRow
            // PATTERN is CUSTOM's editor. It used to sit there dimmed and dead
            // in every other mode, taking a row's height to say nothing.
            if folderPlan.wrappedValue == .custom {
                patternRow
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            destRow
        case .options:
            artworkRow
            artworkSizeRow
            optsRow
        }
    }

    /// How album art travels into the output. This used to be inferred from
    /// whether a max dimension was set, so "keep the original art, just cap it"
    /// and "strip the art" were both unreachable.
    private var artworkRow: some View {
        cvRow("Art") {
            PatchBayBank(
                label: "Art",
                options: ArtworkMode.allCases,
                selection: $model.conversionSelection.artworkMode,
                size: .medium,
                displayText: artworkModeLabel
            )
        }
    }

    private var artworkSizeRow: some View {
        cvRow("Art Size") {
            PatchBayBank(
                label: "Art Size",
                options: Self.artworkDimensions,
                selection: artworkDimensionBinding,
                size: .medium,
                displayText: artworkDimensionLabel
            )
            .disabled(model.conversionSelection.artworkMode == .none)
            .opacity(model.conversionSelection.artworkMode == .none ? 0.5 : 1)
        }
    }

    /// 0 stands for "original" — the bank needs a non-optional value.
    private static let artworkDimensions = [0, 500, 800, 1000, 1400]

    private var artworkDimensionBinding: Binding<Int> {
        Binding(
            get: { model.conversionSelection.artworkMaxDimension ?? 0 },
            set: { model.conversionSelection.artworkMaxDimension = $0 == 0 ? nil : $0 }
        )
    }

    private func artworkModeLabel(_ mode: ArtworkMode) -> String {
        switch mode {
        case .preserve:      return "Keep"
        case .compatReembed: return "Re-embed"
        case .none:          return "Strip"
        }
    }

    private func artworkDimensionLabel(_ dimension: Int) -> String {
        dimension == 0 ? "Original" : "\(dimension)px"
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

    // MARK: - Rows

    /// On a device route the queue is the hand-off list, so a live Scope bank
    /// would be a control that changes nothing — it reads as the queue's source
    /// while the queue quietly ignores it. Swap it for what's actually true.
    @ViewBuilder
    private var scopeRow: some View {
        if let device = model.pendingDeviceConversion {
            cvRow("Queue") {
                HStack(spacing: 8) {
                    Text("\(model.conversionQueueTracks.count) TRK")
                        .font(CarbonFont.mono(12, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(theme.ink)
                    Text("SENT FROM THE BROWSER")
                        .font(CarbonFont.mono(8, weight: .bold))
                        .tracking(1.3)
                        .foregroundStyle(theme.ink4)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                }
                .help("Queued for \(device.deviceName). Send more from the browser to add to this queue.")
            }
        } else {
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
    }

    /// The format rows below belong to the device while a route is set — they
    /// were seeded from its profile and are saved back to it. Without this the
    /// swap was invisible, and looked like the app forgetting your settings.
    @ViewBuilder
    private var presetChipRow: some View {
        if let device = model.pendingDeviceConversion {
            HStack(spacing: 7) {
                Circle()
                    .fill(theme.orange)
                    .frame(width: 6, height: 6)
                    .shadow(color: theme.orange.opacity(0.7), radius: 3)
                Text("\(device.deviceName.uppercased()) PRESET")
                    .font(CarbonFont.mono(8.5, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(theme.orange)
                Text("· EDITS SAVE TO THIS DEVICE")
                    .font(CarbonFont.mono(8, weight: .bold))
                    .tracking(1.3)
                    .foregroundStyle(theme.ink4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
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

    /// The four folder plans the FOLDERS row offers.
    ///
    /// Deliberately a UI type rather than a fourth `FolderStructureMode`:
    /// CUSTOM plans paths exactly like TAGS does, so a Core case would be a
    /// duplicate in every switch that touches the planner — the kind that
    /// silently diverges the first time someone adds a fifth. What actually
    /// differs is which token order is used and whether the pattern editor is
    /// on screen, and that is already expressible.
    enum FolderPlan: Hashable, CaseIterable {
        case mirror, flat, tags, custom
    }

    /// A pattern built in CUSTOM, parked while another plan is selected.
    ///
    /// TAGS has to write the standard order into `tokenOrder` — the planner
    /// reads that, not the preset, so leaving a custom order in place would
    /// mean the output quietly disagreeing with the key that's lit. Parking it
    /// means a tap on TAGS and back doesn't cost you the pattern you built.
    @State private var parkedPattern: (tokens: [FolderToken], separators: [FolderSeparator])?

    private var folderPlan: Binding<FolderPlan> {
        Binding(
            get: {
                switch model.conversionSelection.folderStructureMode {
                case .sourceRelative: return .mirror
                case .flat:           return .flat
                case .metadataTemplate:
                    return model.conversionSelection.templatePreset == .custom ? .custom : .tags
                }
            },
            set: { plan in
                var selection = model.conversionSelection
                if selection.templatePreset == .custom, plan != .custom {
                    parkedPattern = (selection.tokenOrder, selection.separators)
                }
                switch plan {
                case .mirror:
                    selection.folderStructureMode = .sourceRelative
                case .flat:
                    selection.folderStructureMode = .flat
                case .tags:
                    // TAGS means the standard layout, so it can't inherit a
                    // pattern someone built in CUSTOM and then hid from view.
                    selection.folderStructureMode = .metadataTemplate
                    if selection.templatePreset == .custom {
                        selection.templatePreset = .artistYearAlbum
                    }
                    selection.tokenOrder = FolderTokenOrder.normalize(
                        selection.templatePreset.defaultTokenOrder
                    )
                    selection.separators = []
                case .custom:
                    selection.folderStructureMode = .metadataTemplate
                    if selection.templatePreset != .custom {
                        if let parked = parkedPattern {
                            // Back to the pattern you were building.
                            selection.tokenOrder = parked.tokens
                            selection.separators = parked.separators
                        } else {
                            // Nothing parked: open on the layout already in
                            // effect rather than on some default.
                            selection.tokenOrder = FolderTokenOrder.normalize(
                                selection.templatePreset.defaultTokenOrder
                            )
                            selection.separators = []
                        }
                        selection.templatePreset = .custom
                    }
                }
                model.conversionSelection = selection
            }
        )
    }

    private func folderPlanLabel(_ plan: FolderPlan) -> String {
        switch plan {
        case .mirror: return "MIRROR"
        case .flat:   return "FLAT"
        case .tags:   return "TAGS"
        case .custom: return "CUSTOM"
        }
    }

    private var layoutRow: some View {
        // "Layout" said nothing — layout of what? This row decides the folder
        // structure the converted files are written into, so it says so.
        cvRow("Folders") {
            PatchBayBank(
                label: "Folders",
                options: FolderPlan.allCases,
                selection: folderPlan,
                size: .small,
                displayText: folderPlanLabel
            )
            .carbonTip("How the converted files are foldered. MIRROR keeps your source tree's shape · FLAT puts everything in one folder · TAGS uses the standard Artist / Year Album layout · CUSTOM opens the pattern editor so you can shape it yourself.")
        }
        .animation(.easeInOut(duration: 0.18), value: folderPlan.wrappedValue)
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
                    .minimumScaleFactor(0.75)
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

            // Where it's going, and the one number that decides whether it fits.
            // Both were only discoverable from the destination strip two tabs
            // away — and the free space not at all until the preflight failed.
            if let route = deviceRouteLine {
                HStack(spacing: 0) {
                    Text(route)
                        .font(CarbonFont.mono(9, weight: .bold))
                        .tracking(2.0)
                        .foregroundStyle(theme.orange)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
            }

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
                    enabled: armEnabled,
                    label: goLabel
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
        // Named, because the QUEUE tab now lists device queues beside this one
        // and the key below must not look like it runs those too — those are
        // pre-converted from their own PRE-CONVERT keys.
        let label = model.pendingDeviceConversion == nil ? "CRATE QUEUE" : "DEVICE QUEUE"
        return "\(label) · \(count) TRK · \(bytes) · \(dur)"
    }

    /// `nil` on the folder route — the destination strip already says it, and a
    /// second line for "your usual output folder" is noise.
    private var deviceRouteLine: String? {
        guard let device = model.pendingDeviceConversion else { return nil }
        let name = device.deviceName.uppercased()
        guard let free = device.destinationRoot.volumeFreeBytes else {
            return "→ \(name) · NOT CONNECTED"
        }
        return "→ \(name) · \(formatBytes(free)) FREE"
    }

    /// The key says what the press does. Same gesture, same lamp — a different
    /// word, because "CONVERT" was the only thing on screen for a send.
    private var goLabel: String {
        model.pendingDeviceConversion.map { "SEND TO \($0.deviceName.uppercased())" } ?? "CONVERT"
    }

    // MARK: - Row scaffolding

    @ViewBuilder
    private func cvRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 10) {
            // No divider rule: the label sits close enough to its control to
            // belong to it, which is what the rule was standing in for.
            Text(label.uppercased())
                .font(CarbonFont.mono(8, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(theme.ink4)
                .frame(width: 46, alignment: .trailing)
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
        case .queue:     return "QUEUE"
        case .prep:      return "PREP"
        case .selection: return "SEL"
        }
    }

    private func scopeSub(_ scope: ConversionBatchScope) -> String? {
        switch scope {
        case .queue:     return shortCount(model.convertQueue.count)
        case .prep:      return shortCount(model.prepCrateTracks.count)
        case .selection: return shortCount(model.selectedTracksForCrateAdd().count)
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
        case .sourceRelative:   return "MIRROR"
        case .flat:             return "FLAT"
        case .metadataTemplate: return "TAGS"
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
        // The whole strip is the control. A separate CHOOSE… key was a second
        // slab to say what clicking the path already says, and the forced-dark
        // screen behind it made a folder path look like an instrument readout.
        Button(action: onChoose) {
            HStack(spacing: 7) {
                Image(systemName: "folder")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.ink4)
                Text(formattedPath)
                    .font(CarbonFont.mono(10))
                    .lineLimit(1)
                    // Head truncation, not middle: the folder being written
                    // into is the part worth keeping, and it's at the end.
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(theme.ink4)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(theme.isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.04))
            )
        }
        .buttonStyle(.carbonHover)
        .carbonTip("Converted files are written to \(path). Click to choose another folder.")
    }

    /// Parent dimmed, destination folder in full ink — the leaf is what you
    /// actually check before pressing convert.
    private var formattedPath: AttributedString {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let slash = trimmed.lastIndex(of: "/"), slash != trimmed.startIndex else {
            var only = AttributedString(trimmed)
            only.foregroundColor = theme.ink
            return only
        }
        var head = AttributedString(String(trimmed[...slash]))
        head.foregroundColor = theme.ink4
        var leaf = AttributedString(String(trimmed[trimmed.index(after: slash)...]))
        leaf.foregroundColor = theme.ink
        return head + leaf
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
                // Flat, like every other key in the app — the pillowed
                // gradient made the two action keys the loudest thing in a
                // panel where the settings above them are the point.
                .background(KeyChrome())
        }
        .buttonStyle(.carbonHover)
        .accessibilityLabel(Text("Cancel"))
    }
}

// MARK: - Illuminated CONVERT button (press & hold)

private struct ArmGoButton: View {
    @Environment(\.carbon) private var theme
    let enabled: Bool
    /// CONVERT, or SEND TO <DEVICE> when the run is routed at one.
    var label: String = "CONVERT"
    let action: () -> Void

    @State private var holdProgress: Double = 0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(enabled ? theme.orange : theme.metal)

            // Hazard fill that grows with hold progress so the user gets
            // feedback that they're arming the convert.
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.black.opacity(0.18))
                    .frame(width: geo.size.width * holdProgress)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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
        .accessibilityLabel(Text(label))
        .accessibilityHint(Text("Press and hold to start"))
    }

    @ViewBuilder
    private var wideContent: some View {
        HStack(spacing: 10) {
            playGlyph
            VStack(spacing: 2) {
                Text(label)
                    .font(CarbonFont.mono(14, weight: .black))
                    .tracking(3.2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
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
            Text(label)
                .font(CarbonFont.mono(13, weight: .black))
                .tracking(2.6)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
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
        .depthShadow(color: Color.black.opacity(0.4), radius: 1, y: 1)
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
