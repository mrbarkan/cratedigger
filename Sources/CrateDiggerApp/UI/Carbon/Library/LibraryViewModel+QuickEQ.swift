import AppKit
import CrateDiggerCore

/// Quick EQ: with the equalizer's QUICK switch on, the fader under the pointer
/// takes ↑/↓ and W/S. The editor reports which fader that is through
/// `quickEQBand`; this is the keyboard half, called from the one key monitor
/// the app already has so it can win the arrows from volume reliably (two
/// monitors run in an order AppKit does not promise).
extension LibraryViewModel {
    /// Moves the fader under the pointer for a Quick EQ key. Returns true when
    /// it took the key, so the monitor swallows it.
    func handleQuickEQKey(_ event: NSEvent) -> Bool {
        // Dragging is disabled with the EQ off, so the keys are too.
        guard quickEQEnabled, eqEnabled, showingEQEditor,
              let band = quickEQBand, eqGains.indices.contains(band),
              !isEditingText(),
              let direction = QuickEQ.direction(
                  keyCode: event.keyCode,
                  characters: event.charactersIgnoringModifiers,
                  hasCommandModifier: !event.modifierFlags.intersection([.command, .control, .option]).isEmpty
              )
        else { return false }

        eqGains[band] = QuickEQ.nudged(eqGains[band], direction, in: EqualizerEditorView.range)
        return true
    }
}
