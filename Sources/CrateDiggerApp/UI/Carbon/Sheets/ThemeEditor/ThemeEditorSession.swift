import CrateDiggerCore
import Foundation
import SwiftUI

/// A question the theme editor asks inside its own panel, never as an alert:
/// the panel floats over the app, and a modal alert would hide what is being
/// decided about.
struct ThemeEditorPrompt: Identifiable {
    struct Choice: Identifiable {
        enum Role { case cancel, plain, primary }
        let id = UUID()
        let label: String
        let role: Role
        let action: () -> Void

        /// The macOS order, left to right: other choices, Cancel, then the
        /// primary action on the right.
        static func inMacOrder(_ choices: [Choice]) -> [Choice] {
            func rank(_ role: Role) -> Int {
                switch role {
                case .plain: return 0
                case .cancel: return 1
                case .primary: return 2
                }
            }
            return choices.enumerated()
                .sorted { (rank($0.element.role), $0.offset) < (rank($1.element.role), $1.offset) }
                .map(\.element)
        }
    }

    let id = UUID()
    let title: String
    let message: String
    let choices: [Choice]
}

/// What the theme editor panel is doing: which mode it is in (a Simple editor,
/// or the registry's Advanced draft), the question it is asking, and every
/// route out of the current theme (NEW, LOAD, a mode crossing, closing).
///
/// Every route that leaves a theme goes through `leave(then:)`, so an
/// unapplied Simple draft or an unsaved Advanced one is always asked about
/// first. While Simple is open the registry has no draft: the app keeps
/// drawing the saved theme until APPLY.
@MainActor
final class ThemeEditorSession: ObservableObject {
    /// Non-nil while the panel is in Simple mode.
    @Published private(set) var simple: SimpleThemeEditor?
    @Published var prompt: ThemeEditorPrompt?
    @Published var error: String?

    let registry: ThemeRegistry
    /// Closes the panel without asking; set by the view.
    var dismiss: (() -> Void)?
    /// The look on screen, so an adaptive theme opens on the layer showing.
    var onScreen: ThemeDefinition.BaseAppearance = .dark
    /// The id of an Advanced draft this session made from Simple (Copy or
    /// Convert) that is not saved yet. Comparing with the file can't tell:
    /// a converted NEW theme has no file, and its undo history starts empty.
    private(set) var unsavedDraftID: String?

    init(registry: ThemeRegistry? = nil) {
        self.registry = registry ?? .shared
    }

    var mode: ThemeEditorModeRules.Mode { simple == nil ? .advanced : .simple }

    // MARK: Opening

    /// The theme on screen, or the built-in for the appearance showing when
    /// nothing is selected.
    func currentManifest() -> ThemeManifest? {
        registry.manifest(for: PreferencesStore.shared.selectedThemeID)
            ?? registry.manifests.first { $0.definition.baseAppearance == onScreen }
            ?? registry.manifests.first
    }

    /// The panel opening with nothing asked for: the current theme, in its own mode.
    func openCurrent() {
        guard simple == nil, registry.draft == nil, let manifest = currentManifest() else { return }
        load(manifest)
    }

    /// NEW: a Simple theme started from `source` (the theme on screen by default).
    func startNew(from source: ThemeManifest? = nil) {
        leave { [self] in
            guard let manifest = source ?? currentManifest() else { return }
            registry.discardDraft()
            unsavedDraftID = nil
            simple = SimpleThemeEditor(newFrom: manifest, registry: registry)
        }
    }

    /// LOAD, or a theme's edit key in the picker: `manifest` in its own mode.
    /// Leaving an Advanced draft this way is as it always was (no question);
    /// leaving a Simple one asks.
    func open(_ manifest: ThemeManifest) {
        leave(askingAboutAdvanced: false) { [self] in load(manifest) }
    }

    private func load(_ manifest: ThemeManifest) {
        unsavedDraftID = nil
        if ThemeEditorModeRules.mode(of: manifest.definition) == .simple {
            registry.discardDraft()
            simple = SimpleThemeEditor(reopening: manifest, registry: registry)
        } else {
            simple = nil
            registry.beginEditing(manifest, appearance: onScreen)
        }
    }

    /// DUPLICATE in Simple: a sibling carrying the unapplied changes; the
    /// original keeps what it had.
    func duplicateSimple() {
        guard let simple else { return }
        self.simple = SimpleThemeEditor(copyOf: simple.candidate, registry: registry)
    }

    // MARK: Crossing modes

    /// The SIMPLE / ADVANCED switch. Asks with the choices
    /// `ThemeEditorModeRules.crossings` allows.
    func cross(to target: ThemeEditorModeRules.Mode) {
        guard target != mode else { return }
        // Advanced with nothing open: there is nothing to copy, so Simple is NEW.
        if mode == .advanced, registry.draft == nil {
            startNew()
            return
        }
        let isBuiltIn = registry.draft.flatMap { registry.manifest(for: $0.id) }?.origin == .builtIn
        let crossings = ThemeEditorModeRules.crossings(from: mode, isBuiltIn: isBuiltIn)
        let choices = crossings.map { crossing -> ThemeEditorPrompt.Choice in
            switch crossing {
            case .cancel: return .init(label: "CANCEL", role: .cancel) {}
            case .copy: return .init(label: "COPY", role: mode == .advanced ? .primary : .plain) { [self] in copyAcross() }
            case .convert: return .init(label: "CONVERT", role: .primary) { [self] in convertToAdvanced() }
            }
        }
        if mode == .simple {
            prompt = ThemeEditorPrompt(
                title: "Switch to Advanced?",
                message: "Copy makes a new Advanced theme from what is on screen here, unapplied changes "
                    + "included, and leaves this one as it is. Convert makes this theme an Advanced one. "
                    + "A converted theme can't go back to Simple.",
                choices: ThemeEditorPrompt.Choice.inMacOrder(choices)
            )
        } else {
            prompt = ThemeEditorPrompt(
                title: "Switch to Simple?",
                message: "Simple starts a copy from this theme as saved: its main colours, fonts, material "
                    + "and everything else it sets. This theme stays as it is in Advanced, because Simple "
                    + "would repaint its hand-made colours."
                    + (advancedDraftHasChanges ? " You'll be asked about your unsaved changes first." : ""),
                choices: ThemeEditorPrompt.Choice.inMacOrder(choices)
            )
        }
    }

    private func copyAcross() {
        if let simple {
            registry.beginAdvancedCopy(of: simple.candidate)
            unsavedDraftID = registry.draft?.id
            self.simple = nil
        } else if let draft = registry.draft {
            // The copy is built from a saved file (its non-colour settings
            // come from there), so unsaved work is asked about first: Save
            // puts it in the file the copy is made from. An unsaved fork
            // ("Carbon Copy") has no file of its own; after Discard the copy
            // comes from the theme it was forked from.
            let fallbackID = draft.inherits ?? draft.id
            leave { [self] in
                let id = registry.manifest(for: draft.id) != nil ? draft.id : fallbackID
                guard let manifest = registry.manifest(for: id) else { return }
                registry.discardDraft()
                unsavedDraftID = nil
                simple = SimpleThemeEditor(copyOf: manifest.definition, registry: registry)
            }
        }
    }

    private func convertToAdvanced() {
        guard let simple else { return }
        registry.beginAdvancedConversion(of: simple.candidate)
        unsavedDraftID = registry.draft?.id
        self.simple = nil
    }

    // MARK: Leaving

    /// Whether the open Advanced draft holds work that isn't in its file: a
    /// Copy or Convert from Simple until it is saved, a draft that differs
    /// from its saved file, or an unsaved fork of a built-in once something in
    /// it was changed.
    var advancedDraftHasChanges: Bool {
        guard let draft = registry.draft else { return false }
        if draft.id == unsavedDraftID { return true }
        guard let manifest = registry.manifest(for: draft.id) else { return registry.undoDepth > 0 }
        return ThemeRegistry.seeded(manifest.definition) != draft
    }

    /// Runs `next` once the current theme can be left: an unapplied Simple
    /// draft asks Apply / Discard, an unsaved Advanced one Save / Discard.
    func leave(askingAboutAdvanced: Bool = true, then next: @escaping () -> Void) {
        if let simple, simple.hasUnappliedChanges {
            prompt = ThemeEditorPrompt(
                title: "Apply changes to “\(simple.name)”?",
                message: "The app is still showing the saved theme. Discard puts the editor back as it was.",
                choices: [
                    .init(label: "DISCARD", role: .plain) { simple.discard(); next() },
                    .init(label: "CANCEL", role: .cancel) {},
                    .init(label: "APPLY", role: .primary) { [self] in
                        if applySimple() { next() }
                    },
                ]
            )
        } else if askingAboutAdvanced, simple == nil, advancedDraftHasChanges, let draft = registry.draft {
            prompt = ThemeEditorPrompt(
                title: "Save changes to “\(draft.name)”?",
                message: "Discard drops what you changed since the theme was opened.",
                choices: [
                    .init(label: "DISCARD", role: .plain) { [self] in
                        registry.discardDraft()
                        unsavedDraftID = nil
                        next()
                    },
                    .init(label: "CANCEL", role: .cancel) {},
                    .init(label: "SAVE", role: .primary) { [self] in
                        do {
                            try registry.saveDraft()
                            unsavedDraftID = nil
                            error = nil
                            next()
                        } catch {
                            self.error = "Couldn't save: \(error.localizedDescription)"
                        }
                    },
                ]
            )
        } else {
            next()
        }
    }

    /// APPLY. Returns false (and says why) when the registry refused.
    @discardableResult
    func applySimple() -> Bool {
        guard let simple else { return false }
        do {
            try simple.apply()
            error = nil
            return true
        } catch {
            self.error = "Couldn't apply: \(error.localizedDescription)"
            return false
        }
    }

    /// The panel's close button and the editor's own close: Simple with
    /// unapplied changes asks first. Returns whether the window may close now.
    func shouldClose() -> Bool {
        guard prompt == nil else { return false }
        guard let simple, simple.hasUnappliedChanges else { return true }
        leave { [self] in finishClose() }
        return false
    }

    /// Asks if needed, then closes.
    func requestClose() {
        if shouldClose() { finishClose() }
    }

    private func finishClose() {
        simple = nil
        dismiss?()
    }

    // MARK: Regenerating a reopened theme

    /// Runs `change` on the Simple editor, first asking whether a reopened
    /// saved theme may be regenerated when `kind` would do that.
    func gated(_ kind: SimpleThemeEditor.Change, onCancel: @escaping () -> Void = {},
               _ change: @escaping () -> Void) {
        guard let simple, simple.needsWarning(for: kind) else { change(); return }
        prompt = ThemeEditorPrompt(
            title: "Regenerate this theme?",
            message: "Its colours may change slightly.",
            choices: [
                .init(label: "CANCEL", role: .cancel, action: onCancel),
                .init(label: "REGENERATE", role: .primary) {
                    simple.confirmRegenerate()
                    change()
                },
            ]
        )
    }

    /// Runs a prompt choice: the question goes away first, so a choice that
    /// asks another question can put it up.
    func answer(_ choice: ThemeEditorPrompt.Choice) {
        prompt = nil
        choice.action()
    }
}

/// A `ThemeEditorPrompt` drawn over the panel: the panel dims, a paper card
/// asks, and its keys answer. Return picks the primary choice, Esc cancels.
struct ThemeEditorPromptView: View {
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry
    let prompt: ThemeEditorPrompt
    let answer: (ThemeEditorPrompt.Choice) -> Void

    var body: some View {
        ZStack {
            // Swallows clicks, so nothing behind the question changes under it.
            theme.chassis.opacity(0.6)
                .contentShape(Rectangle())
                .onTapGesture {}

            VStack(alignment: .leading, spacing: 10) {
                Text(prompt.title)
                    .font(CarbonFont.sans(13, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(prompt.message)
                    .font(CarbonFont.sans(11))
                    .foregroundStyle(theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    ForEach(prompt.choices) { choice in
                        key(choice)
                    }
                }
                .padding(.top, 4)
            }
            .padding(14)
            // A fixed width, not a maximum: the hosting window sizes itself from the
            // content's minimum, and wrapping text measured at zero width is
            // thousands of points tall.
            .frame(width: 300)
            .background(
                RoundedRectangle(cornerRadius: geometry.paperCornerRadius, style: .continuous)
                    .fill(theme.paper)
            )
            .overlay(
                RoundedRectangle(cornerRadius: geometry.paperCornerRadius, style: .continuous)
                    .strokeBorder(theme.hair)
            )
            .shadow(color: .black.opacity(theme.castsShadows ? 0.28 : 0), radius: 14, y: 6)
            .padding(16)
        }
    }

    @ViewBuilder
    private func key(_ choice: ThemeEditorPrompt.Choice) -> some View {
        let button = KeyButton(style: choice.role == .primary ? .glowingFilled : .normal,
                               action: { answer(choice) }) {
            Text(choice.label)
        }
        .frame(minWidth: 64)
        .frame(height: geometry.keyHeight)
        .fixedSize(horizontal: true, vertical: false)

        switch choice.role {
        case .primary: button.keyboardShortcut(.defaultAction)
        case .cancel: button.keyboardShortcut(.cancelAction)
        case .plain: button
        }
    }
}
