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
    @EnvironmentObject private var model: LibraryViewModel

    @State private var filter = ""
    @State private var saveError: String?
    /// Which layer a pending "copy to" click is armed against — see
    /// `copyLayerButton`. `nil` means nothing is armed.
    @State private var armedCopyTarget: ThemeDefinition.BaseAppearance?
    /// Font roles whose per-weight rows are open. Collapsed by default: the
    /// family pick already maps every weight, and three roles × four faces
    /// permanently on screen would bury the rest of the panel.
    @State private var expandedWeightRoles: Set<String> = []

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
            if let preset = model.themeEditorInitialFilter {
                filter = preset
                model.themeEditorInitialFilter = nil
            }
        }
    }

    // MARK: - Identity

    private var identityBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                sectionLabel("Theme")
                Spacer(minLength: 0)
                if draft != nil {
                    KeyButton(action: { registry.duplicateDraft() }) { Text("DUPLICATE") }
                        .frame(width: 74, height: 20)
                        .carbonTip("Fork this theme into a new one, keeping everything you've changed. The original is left alone.")
                }
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
                }

                appearanceControl(draft)
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

    /// Whether the theme is light, dark, or carries both — and when it carries
    /// both, which layer you're editing.
    ///
    /// BOTH is what stops a skin having to ship as a "— Light"/"— Dark" pair:
    /// the theme keeps one shared palette plus whatever each appearance
    /// changes, and follows the user's Light/Dark/System setting.
    @ViewBuilder
    private func appearanceControl(_ draft: ThemeDefinition) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                ForEach([ThemeDefinition.BaseAppearance.light, .dark], id: \.rawValue) { base in
                    KeyButton(
                        style: (!draft.isAdaptive && draft.baseAppearance == base) ? .selected : .normal,
                        action: {
                            registry.setDraftAdaptive(false)
                            registry.setDraftBaseAppearance(base)
                        }
                    ) {
                        Text(base == .light ? "LIGHT" : "DARK")
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
                    .carbonTip("A \(base == .light ? "light" : "dark")-only theme. Colors you haven't edited are repainted to match; your own edits are kept.")
                }

                KeyButton(
                    style: draft.isAdaptive ? .selected : .normal,
                    action: { registry.setDraftAdaptive(true) }
                ) {
                    Text("BOTH")
                }
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .carbonTip("One theme with a light and a dark version, following the system setting — instead of two separate themes.")
            }

            if draft.isAdaptive {
                HStack(spacing: 6) {
                    Text("EDITING")
                        .font(CarbonFont.mono(8, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(theme.ink4)
                    ForEach([ThemeDefinition.BaseAppearance.light, .dark], id: \.rawValue) { base in
                        KeyButton(
                            style: registry.draftEditingAppearance == base ? .glowingFilled : .normal,
                            action: { registry.draftEditingAppearance = base }
                        ) {
                            Text(base == .light ? "LIGHT" : "DARK")
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 20)
                    }
                }
                .carbonTip("Colors you change now apply to this version only. The app previews the version you're editing.")

                copyLayerButton
            }
        }
        .onChange(of: registry.draftEditingAppearance) { _ in
            // Switching layers cancels a pending overwrite — the target has
            // just changed meaning, so the armed click no longer means what it
            // did when it was armed.
            armedCopyTarget = nil
        }
    }

    /// Seeds the other appearance from this one. Two steps rather than one:
    /// it replaces that layer wholesale and there's no undo, so a mis-click
    /// while reaching for the EDITING keys above it would silently destroy the
    /// other half of the theme.
    private var copyLayerButton: some View {
        let source = registry.draftEditingAppearance
        let target: ThemeDefinition.BaseAppearance = source == .light ? .dark : .light
        let targetName = target == .light ? "LIGHT" : "DARK"
        let armed = armedCopyTarget == target

        return KeyButton(
            style: armed ? .glowingOrange : .normal,
            action: {
                if armed {
                    registry.copyDraftLayer(to: target)
                    armedCopyTarget = nil
                } else {
                    armedCopyTarget = target
                }
            }
        ) {
            Text(armed ? "REPLACE \(targetName)?" : "COPY TO \(targetName)")
        }
        .frame(maxWidth: .infinity)
        .frame(height: 20)
        .carbonTip(armed
                   ? "Click again to replace the \(targetName.lowercased()) version with what you see now."
                   : "Start the \(targetName.lowercased()) version from this one, then tweak it. Replaces whatever that version currently has.")
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
                    if group.name == ThemeTokenCatalog.screenGroupName {
                        screenPresetRow
                    }
                    ForEach(group.tokens, id: \.key) { token in
                        ThemeSwatchRow(token: token)
                    }
                }

                if showDepth {
                    sectionLabel("Depth")
                        .padding(.top, 16)
                        .padding(.bottom, 6)
                    flatSwitch
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

                if visibleColorGroups.isEmpty && visibleGeometryGroups.isEmpty && !showFonts && !showDepth {
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

    /// One-click screen looks, above the swatches they write into. The screen
    /// is the one surface with a genre — LCD, VFD, LED, paper — and matching
    /// its glass, its type and its scanline by hand is six swatches and a font
    /// pick before you can see whether the idea was any good.
    ///
    /// There's no undo: a preset overwrites those tokens outright, and getting
    /// the old ones back means re-loading the theme.
    private var screenPresetRow: some View {
        VStack(spacing: 6) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3),
                spacing: 6
            ) {
                ForEach(ThemeTokenCatalog.screenPresets) { preset in
                    KeyButton(action: { apply(preset) }) { Text(preset.name) }
                        .frame(height: 20)
                        .carbonTip(preset.note + (preset.isAppearanceAware && draft?.isAdaptive == true
                                                  ? " Sets both versions at once."
                                                  : ""))
                }
            }
            monochromeSwitch
            scanlineRow
        }
        .padding(.bottom, 6)
    }

    /// The CRT rake over the glass. It's the effect people either love or
    /// can't stand, so it gets a switch of its own as well as the dial — a
    /// preset that ships lines shouldn't be the only way to change them.
    /// Off is `oledScanlineOpacity` = 0; on restores the shipped strength.
    private var scanlineRow: some View {
        let value = theme.oledScanlineOpacity
        let on = value > 0
        return HStack(spacing: 6) {
            KeyButton(
                style: on ? .selected : .normal,
                action: { setScanline(on ? 0 : ThemeTokenCatalog.scanlineOn) }
            ) {
                Text(on ? "SCAN LINES · ON" : "SCAN LINES · OFF")
            }
            .frame(width: 132, height: 20)
            .carbonTip(on
                       ? "Horizontal scan lines rake the display, like a CRT. Click for clean glass."
                       : "Clean glass. Click to rake the display with CRT scan lines.")

            Slider(
                value: Binding(get: { value }, set: { setScanline($0) }),
                in: 0...ThemeTokenCatalog.scanlineMax
            )
            .controlSize(.small)
            .disabled(!on)
            .help("Scan-line intensity · token: oledScanlineOpacity")

            Text(String(format: "%.3f", value))
                .font(CarbonFont.mono(8, weight: .semibold))
                .foregroundStyle(theme.ink4)
                .frame(width: 30, alignment: .trailing)
        }
    }

    private func setScanline(_ value: Double) {
        var effects = registry.draft?.effects ?? [:]
        effects["oledScanlineOpacity"] = min(max(value, 0), ThemeTokenCatalog.scanlineMax)
        registry.draft?.effects = effects
    }

    /// Whether the display is a single-emitter panel. Real LCD, VFD and LED
    /// hardware only makes one colour, so with this on everything drawn on the
    /// glass — lit annunciators, meters, warnings, the ON AIR lamp — is the
    /// screen's own foreground at whatever brightness it had, and the theme's
    /// accents stay on the chassis where they belong.
    private var monochromeSwitch: some View {
        let on = theme.oledMonochrome
        return KeyButton(
            style: on ? .selected : .normal,
            action: { setMonochrome(!on) }
        ) {
            Text(on ? "MONOCHROME · ON" : "MONOCHROME · OFF")
        }
        .frame(maxWidth: .infinity)
        .frame(height: 20)
        .carbonTip(on
                   ? "One colour on the glass, like real LCD or VFD hardware. Click to let the theme's accents onto the display again."
                   : "Accent colours are drawn on the display. Click for a true single-colour panel — everything in the screen's own phosphor.")
    }

    private func setMonochrome(_ isOn: Bool) {
        var effects = registry.draft?.effects ?? [:]
        effects["oledMonochrome"] = isOn ? 1 : 0
        registry.draft?.effects = effects
    }

    /// A preset paints *both* versions of an adaptive theme, not just the one
    /// open in the editor: the display is a piece of hardware, and hardware
    /// doesn't change when the room lights do. The one preset that does differ
    /// between them — an iPod, backlight off or on — carries the pair itself.
    ///
    /// The scanline and the display face are shared tokens either way; a
    /// typeface isn't lighter at night.
    private func apply(_ preset: ThemeTokenCatalog.ScreenPreset) {
        if registry.draft?.isAdaptive == true {
            registry.setDraftColors(preset.colors(for: .dark), appearance: .dark)
            registry.setDraftColors(preset.colors(for: .light), appearance: .light)
        } else if let appearance = registry.draft?.baseAppearance {
            registry.setDraftColors(preset.colors(for: appearance), appearance: nil)
        }

        var effects = registry.draft?.effects ?? [:]
        effects["oledScanlineOpacity"] = preset.scanline
        effects["oledMonochrome"] = preset.monochrome ? 1 : 0
        registry.draft?.effects = effects

        // Nothing is written when the family isn't installed: leaving the
        // current face beats pinning the role to a name that can't be drawn.
        if let font = ThemeTokenCatalog.themeFont(forFamily: preset.fontFamily) {
            var fonts = registry.draft?.fonts ?? [:]
            fonts["display"] = font
            registry.draft?.fonts = fonts
        }
    }

    /// Whether the chassis casts shadows at all. Off, every panel, key and
    /// cover loses its cast shadow while its bevels and gradients stay — the
    /// same hardware, printed rather than moulded. Glows are emission, not
    /// depth, so the display keeps lighting up.
    private var flatSwitch: some View {
        let flat = !theme.castsShadows
        return KeyButton(
            style: flat ? .selected : .normal,
            action: { setFlat(!flat) }
        ) {
            Text(flat ? "FLAT · ON" : "FLAT · OFF")
        }
        .frame(maxWidth: .infinity)
        .frame(height: 20)
        .carbonTip(flat
                   ? "No cast shadows anywhere. Click to give the panels their depth back."
                   : "Panels, keys and covers cast shadows. Click to drop every one of them and keep only the bevels.")
    }

    private func setFlat(_ isOn: Bool) {
        var effects = registry.draft?.effects ?? [:]
        effects["flat"] = isOn ? 1 : 0
        registry.draft?.effects = effects
    }

    // MARK: - Fonts

    private func fontRow(key: String, label: String, note: String, fallback: String) -> some View {
        let current = draft?.fonts?[key]
        let activeFace = current?.regular ?? fallback
        let family = ThemeTokenCatalog.familyName(ofPostScriptName: activeFace)

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(label.uppercased())
                    .font(CarbonFont.mono(9, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(theme.ink3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 4)

                KeyButton(action: { importFont(for: key) }) { Text("FILE") }
                    .frame(width: 42, height: 19)
                    .carbonTip("Bundle a font file inside the theme so it travels with the .cdtheme when you share it.")

                KeyButton(
                    style: current == nil ? .disabled : .normal,
                    action: { registry.draft?.fonts?[key] = nil }
                ) {
                    Text("RESET")
                }
                .frame(width: 48, height: 19)
            }

            // Family takes the room; style is narrower and fixed, so the two
            // rows below each other line up across all three roles.
            HStack(spacing: 6) {
                systemFontMenu(for: key, current: family)
                    .frame(maxWidth: .infinity)
                variantMenu(for: key, family: family, current: current, fallback: fallback)
                    .frame(width: 104)
            }

            HStack(spacing: 6) {
                weightsDisclosure(for: key, family: family)
                weightSummary(current, family: family)
            }

            if expandedWeightRoles.contains(key) {
                weightRows(for: key, family: family, current: current, fallback: fallback)
            }
        }
        .padding(.vertical, 7)
        .help(note)
    }

    /// Picking a family maps every weight it can supply, which is the right
    /// one-click answer nine times out of ten. This opens the other tenth:
    /// the family's *own* faces, italics included, assigned by hand — the
    /// nearest-weight search behind the automatic mapping searches upright
    /// faces only, so a Condensed or Italic base otherwise gets heavier
    /// weights from a different style axis than the one that was chosen.
    private func weightsDisclosure(for role: String, family: String?) -> some View {
        let expanded = expandedWeightRoles.contains(role)
        let faceCount = family.map { ThemeTokenCatalog.faces(inFamily: $0).count } ?? 0

        return Button {
            if expanded { expandedWeightRoles.remove(role) } else { expandedWeightRoles.insert(role) }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                Text("WEIGHTS")
                    .font(CarbonFont.mono(7.5, weight: .bold))
                    .tracking(1.1)
            }
            .foregroundStyle(theme.ink3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.carbonHover)
        .disabled(faceCount < 2)
        .carbonTip(faceCount < 2
                   ? "This family ships a single face — nothing to map."
                   : "Assign each weight a face from this family by hand.")
    }

    /// One row per weight the interface asks for, minus `regular` — that's the
    /// base, and it's the VARIANT menu above.
    private func weightRows(for role: String, family: String?, current: ThemeFont?, fallback: String) -> some View {
        let faces = family.map { ThemeTokenCatalog.faces(inFamily: $0) } ?? []

        return VStack(spacing: 3) {
            ForEach(ThemeFontWeight.allCases.filter { $0 != .regular }, id: \.rawValue) { weight in
                HStack(spacing: 6) {
                    Text(weight.rawValue.uppercased())
                        .font(CarbonFont.mono(7.5, weight: .bold))
                        .tracking(1.1)
                        .foregroundStyle(theme.ink4)
                        .frame(width: 62, alignment: .leading)

                    weightMenu(for: role, weight: weight, faces: faces, current: current, fallback: fallback)
                }
            }
        }
        .padding(.leading, 2)
        .padding(.top, 2)
    }

    private func weightMenu(
        for role: String,
        weight: ThemeFontWeight,
        faces: [ThemeTokenCatalog.FontFace],
        current: ThemeFont?,
        fallback: String
    ) -> some View {
        let named = current?.face(for: weight)
        let title = named.flatMap { name in faces.first { $0.postScriptName == name }?.styleName ?? name }
            ?? "Auto"

        return menuField(title, enabled: faces.count > 1) {
            Button("Auto") { setFace(nil, weight: weight, role: role, current: current, fallback: fallback) }
            Divider()
            ForEach(faces) { face in
                Button(face.styleName) {
                    setFace(face.postScriptName, weight: weight, role: role, current: current, fallback: fallback)
                }
            }
        }
        .help(named == nil
              ? "Auto — falls back to the nearest face this role names."
              : "Drawn in \(named ?? "") wherever the interface asks for \(weight.rawValue).")
    }

    private func setFace(
        _ postScriptName: String?,
        weight: ThemeFontWeight,
        role: String,
        current: ThemeFont?,
        fallback: String
    ) {
        var font = current ?? ThemeFont(regular: fallback)
        font.setFace(postScriptName, for: weight)
        registry.draft?.fonts?[role] = font
    }

    /// What the theme will actually draw at each weight, beside the WEIGHTS
    /// toggle. A role naming fewer faces than its family ships isn't broken —
    /// the unnamed ones are synthesised — but it is worth pointing at, since
    /// opening the rows is what fixes it.
    @ViewBuilder
    private func weightSummary(_ font: ThemeFont?, family: String?) -> some View {
        if let font {
            let named = ThemeFontWeight.allCases.filter { font.face(for: $0) != nil }
            let available = family.map { ThemeTokenCatalog.availableWeightCount(inFamily: $0) } ?? named.count

            // Amber only for the one case that's actually a defect — a role
            // pinned to a single face, where every heading is a smear of it.
            // Anything else is a fact about the mapping, not a warning: an
            // unmapped weight is a deliberate Auto away in the rows below.
            Text(named.count == 1
                 ? "one face · every weight synthesised"
                 : "\(named.count) of \(available) mapped")
                .font(CarbonFont.mono(7.5))
                .foregroundStyle(named.count == 1 ? theme.sun : theme.ink4)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// A menu dressed as a field: boxed, left-aligned, filling its slot. Bare
    /// borderless menus floated in the middle of their frames and nothing in
    /// the Fonts section lined up with anything else.
    private func menuField<Content: View>(
        _ title: String,
        enabled: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu(content: content) {
            HStack(spacing: 4) {
                Text(title)
                    .font(CarbonFont.mono(8.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(enabled ? theme.ink2 : theme.ink4)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
        }
        .menuStyle(.borderlessButton)
        // Stretch the menu itself, not the finished field: applying this after
        // the background just centres a content-sized box in a wider slot,
        // which is what left the three font rows ragged down the left edge.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.hair))
        .disabled(!enabled)
    }

    /// Picks the variant *within* the chosen family — Light, Condensed, Italic
    /// — and pins it as the role's base face. The heavier weights stay mapped
    /// from the same family, so a Thin base still gets a real bold for headings.
    @ViewBuilder
    private func variantMenu(
        for role: String,
        family: String?,
        current: ThemeFont?,
        fallback: String
    ) -> some View {
        let faces = family.map { ThemeTokenCatalog.faces(inFamily: $0) } ?? []
        let activeName = current?.regular ?? fallback
        let activeStyle = faces.first { $0.postScriptName == activeName }?.styleName ?? "Regular"

        menuField(activeStyle, enabled: faces.count > 1) {
            ForEach(faces) { face in
                Button(face.styleName) { selectVariant(face, family: family, for: role) }
            }
        }
        .help(faces.count < 2
              ? "This family ships a single style."
              : "Choose the weight or style used as this role's base.")
    }

    private func selectVariant(
        _ face: ThemeTokenCatalog.FontFace,
        family: String?,
        for role: String
    ) {
        guard let family,
              let font = ThemeTokenCatalog.themeFont(forFamily: family, base: face.postScriptName)
        else {
            registry.draft?.fonts?[role] = ThemeFont(regular: face.postScriptName)
            return
        }
        registry.draft?.fonts?[role] = font
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
    private func systemFontMenu(for role: String, current: String?) -> some View {
        menuField(current ?? "CHOOSE FONT") {
            ForEach(ThemeTokenCatalog.systemFontFamilies, id: \.self) { family in
                Button(family) { selectSystemFont(family: family, for: role) }
            }
        }
        .help("Use a font installed on this Mac. Nothing is copied — the theme records the name.")
    }

    /// A system font is recorded by name only, never copied: it's already on
    /// this Mac. If the theme travels to a Mac without it, `Font.custom` falls
    /// back to the system face (see `ThemeDefinition.fonts`), which is why FILE
    /// still exists for themes you intend to share.
    private func selectSystemFont(family: String, for role: String) {
        guard let font = ThemeTokenCatalog.themeFont(forFamily: family) else {
            saveError = "Couldn't resolve a usable face in “\(family)”."
            return
        }
        saveError = nil
        registry.draft?.fonts?[role] = font
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
            // A bundled file is one face; its family's other weights aren't
            // necessarily installed, so don't map any.
            registry.draft?.fonts?[role] = ThemeFont(regular: postScriptName)
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

    private var showDepth: Bool {
        matches("flat", "shadow", "depth", "shadows", "surfaces")
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

    /// The slab below is a display, so it reads the same substituted palette
    /// the real one does — otherwise the preview keeps an accent the header
    /// has already given up.
    private var glass: CarbonTheme { theme.oledMonochrome ? theme.monochromeGlass : theme }

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
                    .foregroundStyle(glass.onAir)
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

    /// Reads through the registry so an adaptive theme shows the layer being
    /// edited rather than the shared token underneath it.
    private var hex: String {
        registry.draftColor(token.key) ?? ""
    }

    var body: some View {
        HStack(spacing: 9) {
            // The system picker, not a hand-rolled one: it brings the
            // eyedropper, palettes and recents for free.
            //
            // Its swatch has a fixed intrinsic width of about 44pt; squeezing
            // the frame below that doesn't shrink the control, it just lets it
            // overflow into the label beside it.
            ColorPicker("", selection: Binding(
                get: { Color(hexString: hex) ?? .black },
                set: { registry.setDraftColor(token.key, $0.themeHexString) }
            ), supportsOpacity: true)
            .labelsHidden()
            .fixedSize()

            Text(token.label)
                .font(CarbonFont.sans(11))
                .foregroundStyle(theme.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)

            HexField(
                value: Binding(
                    get: { hex },
                    set: { registry.setDraftColor(token.key, $0) }
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

            HStack(spacing: 5) {
                Text("\(Int(value))")
                    .font(CarbonFont.mono(9, weight: .semibold))
                    .foregroundStyle(theme.ink2)

                // Double-click resets too, but nothing advertises that. The dot
                // lights only when the dial has been moved, so it doubles as
                // the marker for "this one differs from the shipped default".
                Button(action: { value = defaultValue }) {
                    Circle()
                        .fill(isModified ? theme.orange : theme.ink4.opacity(0.3))
                        .frame(width: 6, height: 6)
                        .shadow(color: isModified ? theme.orange.opacity(0.7) : .clear, radius: 2.5)
                        // Hit target well beyond the dot: 6pt is a fine lamp
                        // and an unusable button.
                        .frame(width: 15, height: 15)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.carbonHover)
                .disabled(!isModified)
                .help(isModified
                      ? "Reset \(label) to \(Int(defaultValue))"
                      : "\(label) is at its default")
            }
        }
        .frame(maxWidth: .infinity)
        .help("\(token.note)\n\nDrag to change, double-click to reset.\nToken: \(token.key)")
    }

    /// The shipped value for this token, so a reset undoes an experiment
    /// rather than parking on an arbitrary midpoint.
    private var defaultValue: CGFloat {
        CarbonGeometry.standard[keyPath: token.read]
    }

    /// Compared with a half-point tolerance: the dial only ever lands on whole
    /// numbers, so anything closer than that is the default.
    private var isModified: Bool {
        abs(value - defaultValue) >= 0.5
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
