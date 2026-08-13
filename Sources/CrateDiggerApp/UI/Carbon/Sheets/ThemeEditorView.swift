import AppKit
import CrateDiggerCore
import SwiftUI

/// The theme editor. Every control writes straight into
/// `ThemeRegistry.shared.draft`, which the whole app renders from while it's
/// open — so there is no preview pane here, deliberately. The preview is the
/// application behind this panel, which is the only preview that can't lie
/// about how a theme actually looks.
///
/// That also explains the panel form: it floats and can be moved out of the
/// way, so you can watch the header, browser and transport all change at once.
/// Docking it into the inspector column would hide a third of the thing being
/// themed.
struct ThemeEditorView: View {
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry
    @Environment(\.carbonPanelDismiss) private var dismiss
    @ObservedObject private var registry = ThemeRegistry.shared

    @State private var filter = ""
    @State private var saveError: String?

    private var draft: ThemeDefinition? { registry.draft }

    var body: some View {
        VStack(spacing: 0) {
            identityBar
            Divider().overlay(theme.hair)

            if draft == nil {
                emptyState
            } else {
                tokenList
                // Pinned rather than inline: you're judging a color or a
                // typeface from whatever row you happen to be scrolled to, so
                // the preview has to still be on screen when you get there.
                Divider().overlay(theme.hair)
                ThemeSurfaceSimulator()
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                Divider().overlay(theme.hair)
                actionBar
            }
        }
        .background(theme.chassis)
        .onAppear {
            // Opening with nothing loaded starts you on whatever you're
            // looking at, rather than a blank theme you'd have to build up.
            if registry.draft == nil { beginEditingActiveTheme() }
        }
    }

    // MARK: - Identity

    private var identityBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                sectionLabel("Theme")
                Spacer(minLength: 0)
                loadMenu
            }

            if let draft {
                TextField("Theme name", text: Binding(
                    get: { draft.name },
                    set: { registry.draft?.name = $0 }
                ))
                .textFieldStyle(.plain)
                .font(CarbonFont.sans(13, weight: .semibold))
                .foregroundStyle(theme.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 5).fill(theme.paper))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.hair))

                HStack(spacing: 6) {
                    Text(draft.id)
                        .font(CarbonFont.mono(8.5))
                        .foregroundStyle(theme.ink4)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(draft.inherits.map { "Inherits \($0)" } ?? "Root theme")

                    Spacer(minLength: 4)

                    // A theme declares light or dark; it drives window chrome
                    // and which built-in fills tokens the theme doesn't set.
                    ForEach([ThemeDefinition.BaseAppearance.light, .dark], id: \.rawValue) { base in
                        KeyButton(
                            style: draft.baseAppearance == base ? .selected : .normal,
                            action: { registry.draft?.baseAppearance = base }
                        ) {
                            Text(base == .light ? "LIGHT" : "DARK")
                        }
                        .frame(width: 50, height: 22)
                    }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.ink4)
                TextField("Filter tokens", text: $filter)
                    .textFieldStyle(.plain)
                    .font(CarbonFont.mono(10))
                    .foregroundStyle(theme.ink2)
                if !filter.isEmpty {
                    Button(action: { filter = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.ink4)
                    }
                    .buttonStyle(.carbonHover)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(theme.well))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.hair))
        }
        .padding(12)
    }

    private var loadMenu: some View {
        Menu {
            ForEach(registry.manifests) { manifest in
                Button(manifest.definition.name) { registry.beginEditing(manifest) }
            }
            if registry.manifests.isEmpty {
                Text("No themes installed")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.on.square").font(.system(size: 9))
                Text("LOAD").font(CarbonFont.mono(9, weight: .bold)).tracking(1.2)
            }
            .foregroundStyle(theme.ink2)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .carbonTip("Open an installed theme. Built-ins open as an editable copy — the originals ship with the app and stay put.")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Text("No theme loaded")
                .font(CarbonFont.sans(13, weight: .semibold))
                .foregroundStyle(theme.ink3)
            KeyButton(action: beginEditingActiveTheme) { Text("EDIT CURRENT THEME") }
                .frame(width: 180, height: geometry.keyHeight)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Tokens

    private var tokenList: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(visibleColorGroups) { group in
                    sectionLabel(group.name)
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                    ForEach(group.tokens, id: \.key) { token in
                        ThemeSwatchRow(token: token)
                    }
                }

                ForEach(visibleGeometryGroups) { group in
                    sectionLabel(group.name)
                        .padding(.top, 16)
                        .padding(.bottom, 6)
                    // Two dials per row: at the panel's working width that
                    // leaves each one big enough to drag precisely.
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                        ForEach(group.tokens) { token in
                            CarbonDial(
                                token: token,
                                value: Binding(
                                    get: { CGFloat(registry.draft?.geometry?[token.key] ?? 0) },
                                    set: { registry.draft?.geometry?[token.key] = Double($0) }
                                )
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }

                if showFonts {
                    sectionLabel("Fonts")
                        .padding(.top, 16)
                        .padding(.bottom, 4)
                    ForEach(ThemeTokenCatalog.fontRoles, id: \.key) { role in
                        fontRow(key: role.key, label: role.label, note: role.note, fallback: role.fallback)
                    }
                }

                if visibleColorGroups.isEmpty && visibleGeometryGroups.isEmpty && !showFonts {
                    Text("No tokens match “\(filter)”")
                        .font(CarbonFont.mono(10))
                        .foregroundStyle(theme.ink4)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Fonts

    private func fontRow(key: String, label: String, note: String, fallback: String) -> some View {
        let current = draft?.fonts?[key]
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label.uppercased())
                        .font(CarbonFont.mono(9, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(theme.ink3)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(current ?? "\(fallback) (default)")
                        .font(CarbonFont.mono(8))
                        .foregroundStyle(current == nil ? theme.ink4 : theme.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 4)

                systemFontMenu(for: key)

                KeyButton(action: { importFont(for: key) }) { Text("FILE") }
                    .frame(width: 42, height: 20)
                    .carbonTip("Bundle a font file inside the theme so it travels with the .cdtheme when you share it.")

                KeyButton(
                    style: current == nil ? .disabled : .normal,
                    action: { registry.draft?.fonts?[key] = nil }
                ) {
                    Text("RESET")
                }
                .frame(width: 48, height: 20)
            }
        }
        .padding(.vertical, 5)
        .help(note)
    }

    /// The installed-font list, in the editor rather than in `NSFontPanel`.
    ///
    /// The system font panel reports its selection through the responder chain
    /// (`changeFont:`), and a SwiftUI view hosted in a plain `NSWindow` puts
    /// nothing on that chain that implements it — so the panel opened, you
    /// picked a face, and nothing was ever delivered. That was the "font isn't
    /// saving" bug: the save path was fine, the pick never arrived.
    ///
    /// This reads the same registry `NSFontPanel` does, so it's still "every
    /// font on this Mac" — it just hands the result back directly, and keeps
    /// the choice inside the editor instead of opening a second floating
    /// window over an already-crowded screen.
    private func systemFontMenu(for role: String) -> some View {
        Menu {
            ForEach(ThemeTokenCatalog.systemFontFamilies, id: \.self) { family in
                Button(family) { selectSystemFont(family: family, for: role) }
            }
        } label: {
            Text("SYSTEM")
                .font(CarbonFont.mono(9, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(theme.ink2)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 62)
        .help("Use a font installed on this Mac. Nothing is copied — the theme records the name.")
    }

    /// A system font is recorded by name only, never copied: it's already on
    /// this Mac. If the theme travels to a Mac without it, `Font.custom` falls
    /// back to the system face (see `ThemeDefinition.fonts`), which is why FILE
    /// still exists for themes you intend to share.
    private func selectSystemFont(family: String, for role: String) {
        guard let postScriptName = ThemeTokenCatalog.regularPostScriptName(inFamily: family) else {
            saveError = "Couldn't resolve a usable face in “\(family)”."
            return
        }
        saveError = nil
        registry.draft?.fonts?[role] = postScriptName
    }

    /// Copies the chosen face into the theme's own `Fonts/` folder and records
    /// its PostScript name. Registering immediately is what makes the preview
    /// live — `CarbonFont` resolves through `ActiveThemeFonts` on the next
    /// redraw, so the app re-letters itself as soon as the panel closes.
    private func importFont(for role: String) {
        guard let draft, let authoring = registry.authoring else {
            saveError = "No writable Themes folder — can't import fonts."
            return
        }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "ttf"), .init(filenameExtension: "otf")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.message = "Choose a font to bundle with “\(draft.name)”"
        guard panel.runModal() == .OK, let source = panel.url else { return }

        do {
            let installed = try authoring.importFont(
                from: source,
                into: draft.id,
                replacing: registry.sourceURL(for: draft.id)
            )
            FontRegistrar.registerFonts(at: [installed])
            guard let postScriptName = ThemeTokenCatalog.postScriptName(of: installed) else {
                saveError = "Couldn't read a PostScript name from \(source.lastPathComponent)."
                return
            }
            registry.draft?.fonts?[role] = postScriptName
        } catch {
            saveError = "Couldn't import the font: \(error.localizedDescription)"
        }
    }

    // MARK: - Actions

    private var actionBar: some View {
        VStack(spacing: 6) {
            if let saveError {
                Text(saveError)
                    .font(CarbonFont.mono(9))
                    .foregroundStyle(theme.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                KeyButton(action: revealInFinder) { Text("REVEAL") }
                    .frame(width: 64, height: geometry.keyHeight)
                    .carbonTip("Show the Themes folder in Finder — themes are plain files you can zip and share.")

                Spacer(minLength: 0)

                KeyButton(action: {
                    registry.discardDraft()
                    dismiss?()
                }) {
                    Text("DISCARD")
                }
                .frame(width: 74, height: geometry.keyHeight)

                KeyButton(style: .glowingFilled, action: save) { Text("SAVE") }
                    .frame(width: 74, height: geometry.keyHeight)
                    .carbonTip("Write the theme to your Themes folder and switch to it.")
            }
        }
        .padding(12)
    }

    private func save() {
        do {
            try registry.saveDraft()
            saveError = nil
            dismiss?()
        } catch {
            saveError = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func revealInFinder() {
        guard let url = registry.userThemesDirectory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func beginEditingActiveTheme() {
        let selected = PreferencesStore.shared.selectedThemeID
        if let manifest = registry.manifest(for: selected) {
            registry.beginEditing(manifest)
        } else if let fallback = registry.manifests.first(where: {
            // No theme selected — fork whichever built-in matches the
            // appearance currently on screen, so editing starts from what the
            // user is actually looking at.
            $0.definition.baseAppearance == (theme.isDark ? .dark : .light)
        }) {
            registry.beginEditing(fallback)
        }
    }

    // MARK: - Filtering

    private var query: String {
        filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Notes are searchable too, so "shadow", "sidebar" or "hover" find the
    /// right control even when the label doesn't use that word.
    private func matches(_ fields: String...) -> Bool {
        guard !query.isEmpty else { return true }
        return fields.contains { $0.lowercased().contains(query) }
    }

    private var visibleColorGroups: [ThemeTokenCatalog.ColorGroup] {
        ThemeTokenCatalog.colorGroups.compactMap { group in
            let tokens = group.tokens.filter { matches($0.key, $0.label, $0.note, group.name) }
            return tokens.isEmpty ? nil : ThemeTokenCatalog.ColorGroup(name: group.name, tokens: tokens)
        }
    }

    private var visibleGeometryGroups: [ThemeTokenCatalog.GeometryGroup] {
        ThemeTokenCatalog.geometryGroups.compactMap { group in
            let tokens = group.tokens.filter { matches($0.key, $0.label, $0.note, group.name) }
            return tokens.isEmpty ? nil : ThemeTokenCatalog.GeometryGroup(name: group.name, tokens: tokens)
        }
    }

    private var showFonts: Bool {
        query.isEmpty || ThemeTokenCatalog.fontRoles.contains {
            matches($0.key, $0.label, $0.note, "fonts", "typeface")
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(CarbonFont.mono(9, weight: .bold))
            .tracking(1.8)
            .foregroundStyle(theme.ink3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Surface simulator

/// Miniatures of the two surfaces type actually lands on: the OLED glass and a
/// paper panel. Both are built from the same tokens and the same `CarbonFont`
/// roles the real views use, so what you see here is what the header and
/// inspector will do — the display face on glass, the interface face on paper,
/// mono for the readouts.
///
/// It exists because the interface itself is a poor place to judge a typeface:
/// the OLED is across the window from this panel, the inspector may be
/// collapsed, and neither shows you both faces side by side at a readable size.
private struct ThemeSurfaceSimulator: View {
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview")
                .font(CarbonFont.mono(8.5, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(theme.ink4)

            oledSlab
            paperCard
        }
    }

    /// The header display: `display` face for the title, `mono` for the status
    /// strip, on `oledSurface` with the theme's own scanline strength.
    private var oledSlab: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("MOON SAFARI")
                .font(CarbonFont.display(19))
                .foregroundStyle(theme.oledForeground)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            HStack(spacing: 6) {
                Text("NOW PLAYING")
                    .font(CarbonFont.mono(8, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(theme.onAir)
                Text("AIR · 1998")
                    .font(CarbonFont.mono(8))
                    .foregroundStyle(theme.oledForegroundMuted)
                Spacer(minLength: 0)
                Text("3:42")
                    .font(CarbonFont.mono(8, weight: .bold))
                    .foregroundStyle(theme.oledForegroundMuted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: geometry.oledCornerRadius, style: .continuous)
                .fill(theme.oledSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: geometry.oledCornerRadius, style: .continuous)
                .strokeBorder(theme.oledStrokeInner, lineWidth: 1)
        )
        .scanlines(opacity: theme.oledScanlineOpacity)
        .clipShape(RoundedRectangle(cornerRadius: geometry.oledCornerRadius, style: .continuous))
    }

    /// The inspector panel: `sans` for titles and body, `mono` for the spec
    /// rows — the same pairing `SpecRows` uses.
    private var paperCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Moon Safari")
                .font(CarbonFont.sans(15, weight: .heavy))
                .foregroundStyle(theme.ink)
                .lineLimit(1)

            Text("AIR · 1998")
                .font(CarbonFont.mono(9, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(theme.ink2)

            Rectangle().fill(theme.hair).frame(height: 1)

            HStack(spacing: 8) {
                Text("FORMAT")
                    .font(CarbonFont.mono(8.5))
                    .foregroundStyle(theme.ink3)
                Text("FLAC · 846 kbps")
                    .font(CarbonFont.sans(10))
                    .foregroundStyle(theme.ink2)
                Spacer(minLength: 0)
            }

            Text("The quick brown fox jumps over the lazy dog.")
                .font(CarbonFont.sans(11))
                .foregroundStyle(theme.ink2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: geometry.paperCornerRadius, style: .continuous)
                .fill(theme.paper)
        )
        .overlay(
            RoundedRectangle(cornerRadius: geometry.paperCornerRadius, style: .continuous)
                .strokeBorder(theme.hair, lineWidth: 1)
        )
    }
}

// MARK: - Swatch row

/// One color token: native picker on the left, hex on the right. Both edit the
/// same value; the hex field is there because that's how a theme is actually
/// specified and shared, and eyedropping a value you then have to read back out
/// of a file is worse than typing it.
private struct ThemeSwatchRow: View {
    @Environment(\.carbon) private var theme
    @ObservedObject private var registry = ThemeRegistry.shared
    let token: ThemeTokenCatalog.ColorToken

    private var hex: String {
        registry.draft?.colors?[token.key] ?? ""
    }

    var body: some View {
        HStack(spacing: 6) {
            // The system picker, not a hand-rolled one: it brings the
            // eyedropper, palettes and recents for free.
            ColorPicker("", selection: Binding(
                get: { Color(hexString: hex) ?? .black },
                set: { registry.draft?.colors?[token.key] = $0.themeHexString }
            ), supportsOpacity: true)
            .labelsHidden()
            .frame(width: 36)

            Text(token.label)
                .font(CarbonFont.sans(11))
                .foregroundStyle(theme.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)

            HexField(
                value: Binding(
                    get: { hex },
                    set: { registry.draft?.colors?[token.key] = $0 }
                )
            )
            .frame(width: 78)
        }
        .padding(.vertical, 2)
        // The note says where the color shows up; the raw token name is kept
        // on the end because that's what you'd search for in a theme file.
        .help("\(token.note)\n\nToken: \(token.key)")
    }
}

/// A hex entry that only ever writes a value the theme parser accepts.
///
/// Committing on every keystroke would push "#F", "#FF", "#FFA"… into the live
/// theme and flash the whole app through garbage on the way to a real color, so
/// edits stay local until they parse and are committed on Return or focus loss.
/// Text that never parses snaps back rather than silently writing a token the
/// loader will drop later.
private struct HexField: View {
    @Environment(\.carbon) private var theme
    @Binding var value: String

    @State private var text: String = ""
    @FocusState private var focused: Bool

    private var parses: Bool { Color(hexString: text) != nil }

    var body: some View {
        TextField("#RRGGBB", text: $text)
            .textFieldStyle(.plain)
            .font(CarbonFont.mono(10))
            .foregroundStyle(parses ? theme.ink2 : theme.red)
            .focused($focused)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 4).fill(theme.paper))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(parses ? theme.hair : theme.red.opacity(0.7))
            )
            .onSubmit(commit)
            .onChange(of: focused) { isFocused in
                if !isFocused { commit() }
            }
            .onAppear { text = value }
            // Keeps the field honest when the value changes from elsewhere —
            // the color picker on the same row, or loading another theme.
            .onChange(of: value) { newValue in
                if !focused { text = newValue }
            }
    }

    private func commit() {
        if parses {
            // Normalize on the way in, so the file gets one canonical form.
            value = text.hasPrefix("#") ? text.uppercased() : "#" + text.uppercased()
            text = value
        } else {
            text = value
        }
    }
}

// MARK: - Dial

/// A rotary control for geometry values: drag vertically to change it,
/// double-click to snap back to the shipped default for that token.
///
/// Vertical drag rather than true rotary tracking: circular tracking round a
/// small knob is fiddly and inverts awkwardly as the pointer crosses the
/// center, which is why hardware editors settled on drag-up/drag-down too.
private struct CarbonDial: View {
    @Environment(\.carbon) private var theme
    let token: ThemeTokenCatalog.GeometryToken
    @Binding var value: CGFloat

    private var label: String { token.label }
    private var range: ClosedRange<CGFloat> { token.range }

    /// Points of vertical travel to sweep the whole range. Long enough that a
    /// pane width lands on the pixel you meant, short enough to cross a corner
    /// radius in one gesture.
    private static let travel: CGFloat = 180
    private static let sweep: Double = 280   // degrees, centered on straight up

    @State private var dragStart: CGFloat?

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return Double((value.clamped(to: range) - range.lowerBound) / span)
    }

    private var angle: Angle {
        .degrees(-Self.sweep / 2 + fraction * Self.sweep)
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(theme.metal)
                    .overlay(Circle().strokeBorder(theme.hair, lineWidth: 1))

                // Travel arc — shows where in the range you are without
                // needing to read the number.
                Circle()
                    .trim(from: 0, to: fraction * (Self.sweep / 360))
                    .stroke(theme.orange, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90 - Self.sweep / 2))
                    .padding(-4)

                // Pointer
                Capsule()
                    .fill(theme.ink)
                    .frame(width: 2, height: 11)
                    .offset(y: -7)
                    .rotationEffect(angle)
            }
            .frame(width: 34, height: 34)
            .contentShape(Circle())
            // The panel is `isMovableByWindowBackground`, so without this the
            // window swallows the drag and the knob never moves — the same
            // guard `FaderTrack` needs for the volume rail.
            .background(WindowDragGuard())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let start = dragStart ?? value
                        if dragStart == nil { dragStart = value }
                        let span = range.upperBound - range.lowerBound
                        // Up increases, matching every hardware knob.
                        let delta = -drag.translation.height / Self.travel * span
                        value = (start + delta).clamped(to: range).rounded()
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture(count: 2) { value = defaultValue }

            Text(label.uppercased())
                .font(CarbonFont.mono(7.5, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(theme.ink4)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text("\(Int(value))")
                .font(CarbonFont.mono(9, weight: .semibold))
                .foregroundStyle(theme.ink2)
        }
        .frame(maxWidth: .infinity)
        .help("\(token.note)\n\nDrag to change, double-click to reset.\nToken: \(token.key)")
    }

    /// The shipped value for this token, so a double-click undoes an
    /// experiment rather than parking on an arbitrary midpoint.
    private var defaultValue: CGFloat {
        CarbonGeometry.standard[keyPath: token.read]
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
