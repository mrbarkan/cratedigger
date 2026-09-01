import AppKit
import CrateDiggerCore

/// Keyboard navigation of the browser: bare ↑/↓ move the selection within the
/// focused column, ←/→ switch columns. Space stays play/pause and ⌘-arrows stay
/// transport/volume (handled by the existing shortcut monitor / menu). Driven from
/// `setupKeyboardShortcutsMonitor`, which calls `handleBrowserArrowNav` first.
@MainActor
extension LibraryViewModel {

    /// The columns the view shows, left to right, as indices into it.
    var navColumns: Range<Int> { 0..<browserView.facets.count }

    /// `focusedColumn` clamped to a column this view has. Also what the
    /// browser reads to light the focused column's header — `focusedColumn`
    /// itself can point past the end after the view narrows.
    var effectiveColumn: Int {
        min(max(focusedColumn, 0), max(navColumns.upperBound - 1, 0))
    }

    /// Handle a bare arrow key as browser navigation. Returns true when consumed.
    func handleBrowserArrowNav(_ event: NSEvent) -> Bool {
        // Bare arrows only — ⌘/⌥/⌃/⇧ fall through (⌘-arrows = transport/volume).
        // Arrows always carry .function/.numericPad, so those are not "modifiers".
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              isBrowserKeyContext() else { return false }

        // The gallery is a grid, not columns: ←/→ step one cover, ↑/↓ a whole row.
        if showArtworkGallery {
            switch event.keyCode {
            case 126: moveGallerySelection(by: -galleryColumnsPerRow); return true  // up
            case 125: moveGallerySelection(by:  galleryColumnsPerRow); return true  // down
            case 123: moveGallerySelection(by: -1); return true                     // left
            case 124: moveGallerySelection(by:  1); return true                     // right
            default:  return false
            }
        }

        switch event.keyCode {
        case 126: moveBrowserSelection(by: -1); return true   // up
        case 125: moveBrowserSelection(by:  1); return true   // down
        case 123: moveBrowserFocus(by: -1);     return true   // left
        case 124: moveBrowserFocus(by:  1);     return true   // right
        default:  return false
        }
    }

    /// Step the gallery selection through `allAlbumsSorted`, clamped at both ends.
    /// `delta` is ±1 for a cover or ±`galleryColumnsPerRow` for a row.
    func moveGallerySelection(by delta: Int) {
        let items = allAlbumsSorted
        guard !items.isEmpty else { return }
        let current = selectedAlbumID.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        let next = items[min(max(current + delta, 0), items.count - 1)]
        selectAlbum(next, command: false, shift: false, ordered: items, flat: true)
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
        guard !navColumns.isEmpty else { return }
        focusedColumn = min(max(effectiveColumn + delta, 0), navColumns.upperBound - 1)
    }

    /// One row up or down in the focused column, whatever it shows. The row
    /// ids come from the column's content, so this is the same walk for an
    /// artist, a genre or a track.
    func moveBrowserSelection(by delta: Int) {
        let column = effectiveColumn
        guard let ids = browserColumns[safe: column]?.ids, !ids.isEmpty else { return }
        let current = browser.selection.anchor(column).flatMap { ids.firstIndex(of: $0) } ?? 0
        let next = ids[min(max(current + delta, 0), ids.count - 1)]
        browser.select(column: column, id: next, command: false, shift: false, ordered: ids)
    }
}
