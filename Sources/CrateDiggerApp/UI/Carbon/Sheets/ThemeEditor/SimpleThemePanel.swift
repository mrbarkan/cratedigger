import AppKit
import CrateDiggerCore
import SwiftUI

/// The theme editor in Simple mode: a palette and a few choices on the left,
/// the illustrated preview of the candidate on the right.
///
/// The app behind keeps drawing the saved theme until APPLY, so the preview
/// is the only place the draft shows. It is drawn at 1:1 (never scaled): the
/// cover screen's LCD grid is planned in device pixels, and scaling the
/// picture would put it between them. A narrow panel scrolls the preview
/// rather than shrinking it.
struct SimpleThemePanel: View {
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry
    @ObservedObject var editor: SimpleThemeEditor
    @ObservedObject var session: ThemeEditorSession

    @State private var previewTab: PreviewTab = .window
    /// Each font role's face as the editor opened, offered as a sixth
    /// "Custom" chip when it is none of the presets.
    @State private var openingFonts: [String: ThemeFont] = [:]
    @State private var window: NSWindow?
    @State private var keyMonitor: Any?
    /// This panel's claim on the arrows, so a panel going away never drops the
    /// claim of the one that replaced it.
    @State private var claimToken = UUID()
    @State private var closeObserver: NSObjectProtocol?

    /// Wide enough for six 60 pt swatches and for every font preset's full
    /// name in its own face.
    static let controlsWidth: CGFloat = 420
    /// The widest preview (the full window, 600 pt) plus its margins.
    static let previewWidth: CGFloat = 640

    enum PreviewTab { case window, players }

    private var state: SimpleThemeState { editor.history.current }

    var body: some View {
        HStack(spacing: 0) {
            controls
                .frame(width: Self.controlsWidth)
            Rectangle().fill(theme.hair).frame(width: 1)
            previewArea
                .frame(minWidth: 200, maxWidth: .infinity)
        }
        .background(HostingWindowReader { window = $0 })
        .onAppear {
            openingFonts = editor.previewFonts ?? [:]
            installArrowKeys()
            #if DEBUG
            // A capture can't press PLAYERS.
            if ProcessInfo.processInfo.environment["CRATEDIGGER_THEME_PREVIEW"] == "players" {
                previewTab = .players
            }
            #endif
        }
        .onDisappear(perform: removeArrowKeys)
        .onChange(of: window) { _ in
            ThemeEditorArrowKeys.claim(window, token: claimToken)
            observeWindowClose()
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    sectionLabel("Palette", note: "Two to six colours. Hover one to see what it paints.")
                    PaletteSwatchRow(editor: editor, session: session)
                    shuffleRow
                        .padding(.top, 10)

                    sectionLabel("Contrast")
                    keyRow(SimpleContrast.allCases, selected: state.contrast, label: Self.contrastLabel) { level in
                        session.gated(.contrast) { editor.edit { $0.contrast = level } }
                    }
                    .carbonTip("How far text stands off its surface. Shuffle never changes it.")

                    sectionLabel("Appearance")
                    keyRow(SimpleAppearanceMode.allCases, selected: editor.choices.appearance,
                           label: { $0.rawValue.uppercased() }) { mode in
                        session.gated(.appearance) { setAppearance(mode) }
                    }
                    .carbonTip("Both makes a light and a dark version from the one palette, following the system setting.")

                    sectionLabel("Material")
                    keyGrid(columns: 3, [nil] + ShellMaterial.allCases.map { Optional($0) },
                            selected: editor.choices.material, label: Self.materialLabel) { material in
                        editor.choices.material = material
                    }

                    sectionLabel("Album Art", note: "On the compact player's and mini player's screen.")
                    keyGrid(columns: 2, [nil] + CoverScreenLook.allCases.map { Optional($0) },
                            selected: editor.choices.coverLook, label: Self.coverLabel) { look in
                        editor.choices.coverLook = look
                    }

                    sectionLabel("Fonts")
                    fontRow(role: "display", label: "Screen Titles", note: nil,
                            presets: SimpleFontPresets.screenTitles)
                    fontRow(role: "mono", label: "Labels & Readouts",
                            note: "Also sets the small headings across the app.",
                            presets: SimpleFontPresets.labels)
                    fontRow(role: "sans", label: "Interface", note: nil,
                            presets: SimpleFontPresets.interface)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
            Divider().overlay(theme.hair)
            footer
        }
    }

    /// SHUFFLE between ← and →: other arrangements of the same colours, and the
    /// last twenty steps back and forth (the keyboard arrows too).
    private var shuffleRow: some View {
        HStack(spacing: 6) {
            KeyButton(style: editor.history.canGoBack ? .normal : .disabled, action: editor.back) {
                Image(systemName: "chevron.left")
            }
            .frame(width: 40, height: geometry.keyHeight)
            .carbonTip("Step back (←). Every colour change, pin and Shuffle is a step; twenty are kept.")
            .accessibilityLabel("Step back")

            KeyButton(style: .glowingOrange, action: { session.gated(.shuffle) { editor.shuffle() } }) {
                Text("SHUFFLE")
            }
            .frame(maxWidth: .infinity)
            .frame(height: geometry.keyHeight)
            .carbonTip("Give the same colours different jobs. Pinned jobs, contrast, fonts, material and album art stay.")

            KeyButton(style: editor.history.canGoForward ? .normal : .disabled, action: editor.forward) {
                Image(systemName: "chevron.right")
            }
            .frame(width: 40, height: geometry.keyHeight)
            .carbonTip("Step forward again (→).")
            .accessibilityLabel("Step forward")
        }
    }

    private func fontRow(role: String, label: String, note: String?, presets: [SimpleFontPreset]) -> some View {
        let current = editor.choices.fonts[role] ?? editor.previewFonts?[role]
        let currentFace = current?.regular ?? Self.shippedFace(role)
        let matching = presets.first { $0.font.regular == currentFace }
        let opening = openingFonts[role]
        let custom = opening.flatMap { font in presets.contains { $0.font.regular == font.regular } ? nil : font }

        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label.uppercased())
                    .font(CarbonFont.mono(8, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(theme.ink3)
                if let note {
                    Text(note)
                        .font(CarbonFont.mono(7.5))
                        .foregroundStyle(theme.ink4)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            // Chips as wide as their names, wrapping: a grid of equal cells
            // truncated the wide faces ("Major Mono…", "Pixel Op…").
            ChipFlow(spacing: 6) {
                ForEach(presets) { preset in
                    KeyButton(style: matching?.id == preset.id ? .selected : .normal,
                              action: { setFont(preset.font, role: role) }) {
                        Text(preset.label)
                            .font(Self.chipFont(preset.font.regular))
                    }
                    .frame(minWidth: 64)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(height: 24)
                    .accessibilityLabel("\(label): \(preset.label)")
                }
                if let custom {
                    let installed = NSFont(name: custom.regular, size: 11) != nil
                    KeyButton(style: matching == nil && currentFace == custom.regular ? .selected : .normal,
                              action: { setFont(custom, role: role) }) {
                        Text("Custom")
                            .font(installed ? Self.chipFont(custom.regular) : CarbonFont.mono(9, weight: .bold))
                    }
                    .frame(minWidth: 64)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(height: 24)
                    .accessibilityLabel("\(label): custom, \(custom.regular)")
                    .carbonTip(installed
                               ? "The theme's own face: \(ThemeTokenCatalog.familyName(ofPostScriptName: custom.regular) ?? custom.regular)."
                               : "The theme names \(custom.regular), which isn't installed on this Mac; the system face stands in.")
                }
            }
        }
        .padding(.bottom, 8)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            TextField("Theme name", text: $editor.name)
                .textFieldStyle(.plain)
                .font(CarbonFont.sans(13, weight: .semibold))
                .foregroundStyle(theme.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 5).fill(theme.paper))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.hair))

            if let error = session.error {
                Text(error)
                    .font(CarbonFont.mono(9))
                    .foregroundStyle(theme.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Text(status.text)
                    .font(CarbonFont.mono(8, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(status.lit ? theme.orange : theme.ink4)
                    .animation(CarbonMotion.state, value: status.lit)
                    .carbonTip(status.tip)
                Spacer(minLength: 0)

                KeyButton(action: { editor.discard(); session.requestClose() }) { Text("DISCARD") }
                    .frame(width: 74, height: geometry.keyHeight)
                    .carbonTip("Close without applying. The saved theme stays as it is.")

                KeyButton(style: canApply ? .glowingFilled : .disabled,
                          action: { session.applySimple() }) {
                    Text("APPLY")
                }
                .frame(width: 74, height: geometry.keyHeight)
                .carbonTip("Save the theme to your Themes folder and switch the app to it.")
            }
        }
        .padding(12)
    }

    /// A NEW or duplicated theme is not in the Themes folder until its first
    /// APPLY, so it can be applied untouched.
    private var isSaved: Bool { session.registry.manifest(for: editor.candidate.id) != nil }
    private var canApply: Bool { editor.hasUnappliedChanges || !isSaved }

    private var status: (text: String, lit: Bool, tip: String) {
        if !isSaved {
            return ("NEW · NOT SAVED", true,
                    "Not in your Themes folder yet. APPLY saves it and switches the app to it.")
        }
        if editor.hasUnappliedChanges {
            return ("NOT APPLIED", true, "The app is still showing the saved theme. APPLY to use this one.")
        }
        return ("SAVED", false, "Matches the theme in your Themes folder.")
    }

    // MARK: - Preview

    private var previewArea: some View {
        let preview = editor.previewTheme
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                tabKey("WINDOW", .window)
                tabKey("PLAYERS", .players)
                Spacer(minLength: 8)
                if editor.choices.appearance == .both {
                    Text("SHOWING")
                        .font(CarbonFont.mono(8, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(theme.ink4)
                    ForEach([ThemeDefinition.BaseAppearance.light, .dark], id: \.rawValue) { look in
                        KeyButton(style: editor.previewAppearance == look ? .glowingFilled : .normal,
                                  action: { editor.previewAppearance = look }) {
                            Text(look == .light ? "LIGHT" : "DARK")
                        }
                        .frame(width: 58, height: 20)
                    }
                }
            }
            .padding(12)

            Divider().overlay(theme.hair)

            ScrollView([.horizontal, .vertical]) {
                ThemePreviewIllustration(
                    theme: preview.theme,
                    fonts: editor.previewFonts,
                    highlighted: editor.highlightedJobs,
                    screens: previewTab == .window ? [.fullWindow] : [.mini, .compact]
                )
                .padding(20)
            }
            .background(theme.well)
        }
    }

    private func tabKey(_ title: String, _ tab: PreviewTab) -> some View {
        KeyButton(style: previewTab == tab ? .selected : .normal, action: { previewTab = tab }) {
            Text(title)
        }
        .frame(width: 76, height: 20)
        .carbonTip(tab == .window ? "The full window." : "The mini player and the compact player, with the album-art look.")
    }

    // MARK: - Building blocks

    private func sectionLabel(_ text: String, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text.uppercased())
                .font(CarbonFont.mono(9, weight: .bold))
                .tracking(1.8)
                .foregroundStyle(theme.ink3)
            if let note {
                Text(note)
                    .font(CarbonFont.mono(8))
                    .foregroundStyle(theme.ink4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private func keyRow<Value: Hashable>(
        _ values: [Value], selected: Value, label: @escaping (Value) -> String,
        action: @escaping (Value) -> Void
    ) -> some View {
        HStack(spacing: 6) {
            ForEach(values, id: \.self) { value in
                KeyButton(style: value == selected ? .selected : .normal, action: { action(value) }) {
                    Text(label(value))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 22)
            }
        }
    }

    private func keyGrid<Value: Hashable>(
        columns: Int, _ values: [Value], selected: Value, label: @escaping (Value) -> String,
        action: @escaping (Value) -> Void
    ) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
            ForEach(values, id: \.self) { value in
                KeyButton(style: value == selected ? .selected : .normal, action: { action(value) }) {
                    Text(label(value))
                }
                .frame(height: 22)
            }
        }
    }

    // MARK: - Actions

    /// A single-appearance theme previews in its own appearance; Both keeps
    /// whichever layer the preview was showing.
    private func setAppearance(_ mode: SimpleAppearanceMode) {
        editor.choices.appearance = mode
        switch mode {
        case .light: editor.previewAppearance = .light
        case .dark: editor.previewAppearance = .dark
        case .both: break
        }
    }

    private func setFont(_ font: ThemeFont, role: String) {
        editor.choices.fonts[role] = font
    }

    // MARK: - Keyboard

    /// ←/→ step the history while this panel is the key window, no text field
    /// is being edited and no question is up. The view model's shortcut
    /// monitor stands aside for this window (`ThemeEditorArrowKeys`), so the
    /// arrows don't also skip tracks.
    private func installArrowKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard ThemeEditorArrowKeys.claims(event),
                  !ThemeEditorArrowKeys.isEditingText(),
                  session.prompt == nil
            else { return event }
            if event.keyCode == ThemeEditorArrowKeys.left { editor.back() } else { editor.forward() }
            return nil
        }
    }

    /// The panel window closing ends the monitor even if SwiftUI never sends
    /// `onDisappear` for a window torn down from AppKit.
    private func observeWindowClose() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        guard let window else { return }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated { removeArrowKeys() }
        }
    }

    private func removeArrowKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        ThemeEditorArrowKeys.release(token: claimToken)
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
    }

    // MARK: - Labels

    private static func contrastLabel(_ level: SimpleContrast) -> String {
        switch level {
        case .soft: return "SOFT"
        case .standard: return "STANDARD"
        case .high: return "HIGH"
        }
    }

    private static func materialLabel(_ material: ShellMaterial?) -> String {
        switch material {
        case nil: return "NONE"
        case .grain?: return "GRAIN"
        case .plastic?: return "PLASTIC"
        case .brushed?: return "BRUSHED"
        case .blasted?: return "BLASTED"
        case .weave?: return "WEAVE"
        }
    }

    private static func coverLabel(_ look: CoverScreenLook?) -> String {
        switch look {
        case nil: return "OFF"
        case .grid?: return "LCD GRID"
        case .pixel?: return "PIXEL LCD"
        case .handheld?: return "HANDHELD LCD"
        }
    }

    /// The face a role draws when the theme names none.
    private static func shippedFace(_ role: String) -> String {
        switch role {
        case "display": return CarbonFont.displayFamily
        case "mono": return CarbonFont.monoFamily
        default: return CarbonFont.sansFamily
        }
    }

    /// A chip's name drawn in its own face, so the row is the specimen.
    private static func chipFont(_ postScriptName: String) -> Font {
        postScriptName.hasPrefix(".") ? .system(size: 10.5, weight: .medium) : .custom(postScriptName, fixedSize: 10.5)
    }
}

// MARK: - Chip flow

/// Lays chips out left to right at their own widths, wrapping to a new line
/// when the next one would not fit.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

// MARK: - Keyboard ownership

/// Which window, if any, owns bare ←/→ for the Simple editor's history.
@MainActor
enum ThemeEditorArrowKeys {
    static let left: UInt16 = 123
    static let right: UInt16 = 124

    private(set) static weak var claimingWindow: NSWindow?
    private static var claimToken: UUID?

    static func claim(_ window: NSWindow?, token: UUID) {
        claimingWindow = window
        claimToken = window == nil ? nil : token
    }

    static func release(token: UUID) {
        guard claimToken == token else { return }
        claimingWindow = nil
        claimToken = nil
    }

    /// True for a bare ← or → while the claiming window is key.
    static func claims(_ event: NSEvent) -> Bool {
        guard event.keyCode == left || event.keyCode == right,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              let claimingWindow, NSApp.keyWindow === claimingWindow
        else { return false }
        return true
    }

    static func isEditingText() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if let textView = responder as? NSTextView { return textView.isEditable }
        return responder is NSTextField
    }
}

// MARK: - Window access

/// Hands the hosting `NSWindow` to SwiftUI, for the few things only AppKit
/// can do to it (its size, its key status).
struct HostingWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { ReaderView(onWindow: onWindow) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class ReaderView: NSView {
        let onWindow: (NSWindow?) -> Void
        init(onWindow: @escaping (NSWindow?) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = self.window
            DispatchQueue.main.async { [onWindow] in onWindow(window) }
        }
    }
}

/// Resizes the editor's window for a mode, keeping its top edge where it is
/// and staying on screen.
@MainActor
enum ThemeEditorWindowSizing {
    struct Size {
        var width: CGFloat
        var minHeight: CGFloat?
        var minimum: NSSize
    }

    static let advancedWidth: CGFloat = 340
    static let advancedMinimum = NSSize(width: 296, height: 420)
    static let advancedPreviewWidth: CGFloat = 520

    static func size(simple: Bool, preview: Bool, currentWidth: CGFloat) -> Size {
        if simple {
            return Size(width: SimpleThemePanel.controlsWidth + 1 + SimpleThemePanel.previewWidth,
                        minHeight: 720, minimum: NSSize(width: 720, height: 560))
        }
        if preview {
            return Size(width: advancedWidth + 1 + advancedPreviewWidth, minHeight: 700,
                        minimum: NSSize(width: advancedMinimum.width + 1 + 300, height: advancedMinimum.height))
        }
        // Back from a wider mode: the narrow panel the app is watched through.
        let width = currentWidth > 560 ? advancedWidth : currentWidth
        return Size(width: width, minHeight: nil, minimum: advancedMinimum)
    }

    static func apply(_ size: Size, to window: NSWindow, animate: Bool) {
        window.contentMinSize = size.minimum
        let content = window.contentRect(forFrameRect: window.frame)
        let height = max(content.height, size.minHeight ?? 0)
        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: size.width, height: height))
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            let margin: CGFloat = 24
            frame.size.width = min(frame.width, visible.width - margin * 2)
            frame.size.height = min(frame.height, visible.height - margin * 2)
            frame.origin.x = min(max(window.frame.minX, visible.minX + margin), visible.maxX - margin - frame.width)
            let top = min(window.frame.maxY, visible.maxY)
            frame.origin.y = max(top - frame.height, visible.minY + margin)
        } else {
            frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        }
        guard frame != window.frame else { return }
        window.setFrame(frame, display: true, animate: animate)
    }
}
