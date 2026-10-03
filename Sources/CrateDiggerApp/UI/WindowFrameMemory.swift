import CoreGraphics
import CrateDiggerCore

/// Where the main window's frame is remembered: one slot per player layout,
/// so the full console and the compact player each reopen where they were left.
///
/// Inert until `arm()`. AppKit posts `windowDidMove` synchronously from the
/// window controller's own launch-time `setFrame`, before the saved frame has
/// been applied; recording that overwrote the user's frame with the centred
/// default on every launch.
struct WindowFrameMemory {
    let prefs: PreferencesStore
    private(set) var isArmed = false

    init(prefs: PreferencesStore) {
        self.prefs = prefs
    }

    /// Call once the launch frame has been restored.
    mutating func arm() {
        isArmed = true
    }

    func saved(for layout: PlayerLayout) -> CGRect? {
        switch layout {
        case .full:    return prefs.savedWindowFrame
        case .compact: return prefs.savedCompactWindowFrame
        }
    }

    func record(_ frame: CGRect, for layout: PlayerLayout) {
        guard isArmed else { return }
        switch layout {
        case .full:    prefs.savedWindowFrame = frame
        case .compact: prefs.savedCompactWindowFrame = frame
        }
    }
}
