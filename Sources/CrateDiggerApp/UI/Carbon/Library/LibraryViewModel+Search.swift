import CrateDiggerCore
import Foundation

/// Library search: the field's state, the scope switch, and the display
/// takeover that goes with them.
///
/// The matching itself is Core's (`BrowserFilter`, `LibraryIndex.filtered`).
/// Everything here is wiring: what a keystroke recomputes, where widening
/// takes you, and which screen the OLED goes back to afterwards.
extension LibraryViewModel {

    // MARK: - The query

    /// The live query. Forwards onto `browser.filter` the way the sort pairs
    /// forward onto `browser`, with the work in the setter — a `didSet` on
    /// `browser` itself would re-sort the whole library on every click.
    var searchQuery: String {
        get { browser.filter.query }
        set {
            guard newValue != browser.filter.query else { return }
            browser.filter.query = newValue
            applyFilterChange()
            if browser.filter.isActive { showSearchScreen() } else { searchCleared() }
        }
    }

    var searchScope: BrowserFilter.Scope { browser.filter.scope }

    var isSearchActive: Bool { browser.filter.isActive }

    /// Radio is the one browser the search can't narrow: its list comes from
    /// `filteredStreams`, not from an index.
    var isSearchAvailable: Bool { !isRadioMode }

    /// The scope control only makes sense where there is somewhere wider to go:
    /// a crate or the Prep Crate. All Records is already everywhere, and a CD,
    /// playlist, device or remote library is not part of "every crate you own".
    var canWidenSearch: Bool {
        switch currentSource {
        case .localCrate, .prepCrate: return true
        case .localAll: return searchScope == .everywhere
        default: return false
        }
    }

    /// Recompute what the browser shows, then put the anchors back on rows that
    /// survived. Both halves matter: without the re-anchor the browser filters
    /// down to three rows with none of them selected.
    private func applyFilterChange() {
        recomputeSortedCollections()
        browser.reanchor(in: browsedIndex)
    }

    // MARK: - Scope

    /// Widening moves you to All Records with the query intact and says so in
    /// the sidebar; narrowing puts you back where you started. Nothing is
    /// hidden about which source you are in, which is the whole reason this is
    /// a source switch rather than a quiet second index.
    func setSearchScope(_ scope: BrowserFilter.Scope) {
        guard scope != browser.filter.scope else { return }
        // No saving the query around these: both ends are local sources, and a
        // move inside the local library carries the search with it (see
        // `LibrarySource.keepsSearch(movingTo:)`).
        switch scope {
        case .everywhere:
            let origin = currentSource
            selectSource(.localAll)
            sourceBeforeSearch = origin
        case .source:
            if let origin = sourceBeforeSearch { selectSource(origin) }
            sourceBeforeSearch = nil
        }

        browser.filter.scope = scope
        applyFilterChange()
        if browser.filter.isActive { showSearchScreen() }
    }

    // MARK: - Clearing

    /// Empty the field and put everything it moved back: the source you were in
    /// before widening, and the screen the display was on.
    func clearSearch() {
        guard isSearchActive || searchScope == .everywhere else { return }
        browser.filter.query = ""
        applyFilterChange()
        searchCleared()
    }

    /// The tail of clearing, shared by `clearSearch` and by the field going
    /// empty under the user's own backspace.
    func searchCleared() {
        if searchScope == .everywhere { setSearchScope(.source) }
        hideSearchScreen()
    }

    /// Drop the query, the scope and the remembered origin, for `selectSource`.
    /// Deliberately not `clearSearch()`: that one would recurse back through
    /// `setSearchScope` into `selectSource`.
    ///
    /// The recompute is not optional. `selectSource` assigns the new `index`
    /// first, whose `didSet` prunes with the filter that is about to be
    /// dropped; without this the browser would keep drawing the old query's
    /// results in a source that no longer has a query.
    func clearSearchState() {
        browser.filter = BrowserFilter()
        sourceBeforeSearch = nil
        recomputeSortedCollections()
    }

    // MARK: - Focus

    /// ⌘F, and the header's magnifier. Puts the browser somewhere the field can
    /// be seen, flips the display to SEARCH, and asks the field to take focus.
    func requestSearchFocus() {
        guard isSearchAvailable else { return }
        // Collapsed or hidden, the browser has nowhere to show the field — same
        // courtesy "Go to Current Song" already does for the reveal.
        browserCollapsed = false
        showSearchField = true
        showSearchScreen()
        bumpSearchFocusTick()
    }

    /// The header key: hide the field, or bring it back and put the cursor in
    /// it. Hiding takes the query with it, because a browser filtered by a
    /// field that isn't on screen reads as a bug rather than as a search.
    func toggleSearchField() {
        if showSearchField {
            clearSearch()
            showSearchField = false
        } else {
            requestSearchFocus()
        }
    }

    // MARK: - The display

    /// Take the glass over, remembering what was on it. Idempotent: typing a
    /// second character must not overwrite the memory with `.search` itself.
    func showSearchScreen() {
        guard oledView != .search else { return }
        oledViewBeforeSearch = oledView
        oledView = .search
    }

    /// Give the glass back — but only if the search still has it. Pressing
    /// DISPLAY mid-search is the user choosing a screen, and leaving the field
    /// must not yank it away from them.
    func hideSearchScreen() {
        defer { oledViewBeforeSearch = nil }
        guard oledView == .search else { return }
        oledView = oledViewBeforeSearch ?? .nowPlaying
    }
}
