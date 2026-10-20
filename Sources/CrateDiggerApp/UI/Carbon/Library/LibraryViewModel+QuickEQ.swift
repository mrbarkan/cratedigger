import AppKit
import CrateDiggerCore

/// Quick EQ: with the equalizer's QUICK switch on, the selected fader takes
/// ↑/↓ and W/S, and ←/→ and A/D select the fader beside it. The editor reports
/// which fader the pointer selected through `quickEQBand`; this is the
/// keyboard half, called from the one key monitor the app already has so it
/// can win the arrows from volume and the browser reliably (two monitors run
/// in an order AppKit does not promise).
extension LibraryViewModel {
    /// Acts on a Quick EQ key. Returns true when it took the key, so the
    /// monitor swallows it.
    func handleQuickEQKey(_ event: NSEvent) -> Bool {
        // Dragging is disabled with the EQ off, so the keys are too.
        guard quickEQEnabled, eqEnabled, showingEQEditor,
              let band = quickEQBand, eqGains.indices.contains(band),
              !isEditingText(),
              let action = QuickEQ.action(
                  keyCode: event.keyCode,
                  characters: event.charactersIgnoringModifiers,
                  hasCommandModifier: !event.modifierFlags.intersection([.command, .control, .option]).isEmpty
              )
        else { return false }

        switch action {
        case .nudge(let direction):
            eqGains[band] = QuickEQ.nudged(eqGains[band], direction, in: EqualizerEditorView.range)
        case .select(let offset):
            quickEQBand = QuickEQ.band(band, offsetBy: offset, count: eqGains.count)
        }
        return true
    }
}
