import AppKit
import CrateDiggerCore

/// Which browser column the keyboard arrows act on.
enum BrowserColumn: Sendable {
    case artist, album, track
}

/// Keyboard navigation of the browser: bare ↑/↓ move the selection within the
/// focused column, ←/→ switch columns. Space stays play/pause and ⌘-arrows stay
/// transport/volume (handled by the existing shortcut monitor / menu). Driven from
/// `setupKeyboardShortcutsMonitor`, which calls `handleBrowserArrowNav` first.
@MainActor
extension LibraryViewModel {

    /// Columns the current layout actually shows, left→right.
    var navColumns: [BrowserColumn] {
        switch browserLayout {
        case .full:       return [.artist, .album, .track]
        case .albumTrack: return [.album, .track]
        case .track:      return [.track]
        }
    }

    /// `focusedColumn` clamped to a column this layout shows.
    private var effectiveColumn: BrowserColumn {
        navColumns.contains(focusedColumn) ? focusedColumn : (navColumns.last ?? .track)
    }

    /// Handle a bare arrow key as browser navigation. Returns true when consumed.
    func handleBrowserArrowNav(_ event: NSEvent) -> Bool {
        // Bare arrows only — ⌘/⌥/⌃/⇧ fall through (⌘-arrows = transport/volume).
        // Arrows always carry .function/.numericPad, so those are not "modifiers".
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              isBrowserKeyContext() else { return false }
        switch event.keyCode {
        case 126: moveBrowserSelection(by: -1); return true   // up
        case 125: moveBrowserSelection(by:  1); return true   // down
        case 123: moveBrowserFocus(by: -1);     return true   // left
        case 124: moveBrowserFocus(by:  1);     return true   // right
        default:  return false
        }
    }

    /// True when the main window is key (not a sheet, the mini-player, or the
    /// booklet/artwork windows — those have their own key handling) and no text
    /// field is editing, so arrows belong to the browser.
    private func isBrowserKeyContext() -> Bool {
        guard let key = NSApp.keyWindow, key === NSApp.mainWindow else { return false }
        return !isEditingText()
    }

    private func isEditingText() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if let textView = responder as? NSTextView { return textView.isEditable }
        return responder is NSTextField || responder is NSSearchField || responder is NSComboBox
    }

    // MARK: - Movement

    func moveBrowserFocus(by delta: Int) {
        let cols = navColumns
        let current = cols.firstIndex(of: effectiveColumn) ?? (cols.count - 1)
        focusedColumn = cols[min(max(current + delta, 0), cols.count - 1)]
    }

    func moveBrowserSelection(by delta: Int) {
        switch effectiveColumn {
        case .artist:
            let items = visibleArtists
            guard let next = neighbor(items, selectedArtistID, { $0.id }, delta) else { return }
            selectArtist(next, command: false, shift: false, ordered: items)
        case .album:
            let items = browserLayout == .albumTrack ? allAlbumsSorted : visibleAlbums
            guard let next = neighbor(items, selectedAlbumID, { $0.id }, delta) else { return }
            selectAlbum(next, command: false, shift: false, ordered: items, flat: browserLayout == .albumTrack)
        case .track:
            let items = browserLayout == .track ? flatTracksSorted : visibleTracks
            guard let next = neighbor(items, selectedTrackID, { $0.track.id }, delta) else { return }
            selectTrack(next, command: false, shift: false, ordered: items)
        }
    }

    /// The item one step (clamped) from the one matching `currentID`; starts at the
    /// first item when nothing is selected yet.
    private func neighbor<Item, ID: Equatable>(
        _ items: [Item], _ currentID: ID?, _ idOf: (Item) -> ID, _ delta: Int
    ) -> Item? {
        guard !items.isEmpty else { return nil }
        let current = currentID.flatMap { id in items.firstIndex { idOf($0) == id } } ?? 0
        return items[min(max(current + delta, 0), items.count - 1)]
    }
}
