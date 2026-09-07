import AppKit
import CrateDiggerCore
import SwiftUI

/// The browser's search field: one strip across the top of the browser well,
/// above whichever browser is showing.
///
/// It sits above the list/gallery switch rather than inside `BrowserPane` on
/// purpose — the gallery draws `allAlbumsSorted`, which is filtered too, so one
/// field up here searches both instead of each needing its own.
///
/// Always visible rather than summoned by ⌘F: a search field you cannot see is
/// one you forget the app has, and the roadmap's whole complaint was that
/// people gave up scrolling because they did not know there was another way.
struct BrowserSearchBar: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel
    @FocusState private var focused: Bool

    var body: some View {
        RecessedWell(cornerRadius: 6, padding: 0) { row }
            .frame(height: 26)
            .padding(.horizontal, 8)
            .padding(.top, 7)
            .padding(.bottom, 3)
            // ⌘F bumps the tick; the field takes focus from it. A tick rather
            // than a bool because focusing has to fire again on the second
            // press, when nothing about the field itself has changed.
            .onChange(of: model.searchFocusTick) { _ in focused = true }
    }

    private var row: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(model.isSearchActive ? theme.orange : theme.ink4)

            field

            if model.isSearchActive {
                clearButton
            }
            if model.canWidenSearch {
                scopeToggle
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var field: some View {
        TextField("Search artists, albums, tracks", text: searchBinding)
            .textFieldStyle(.plain)
            .font(CarbonFont.mono(11))
            .foregroundStyle(theme.ink)
            .focused($focused)
            .onExitCommand {
                // Escape empties the field and hands the keys back to the
                // browser, which is where the arrows want to go next.
                model.clearSearch()
                focused = false
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var searchBinding: Binding<String> {
        Binding(get: { model.searchQuery }, set: { model.searchQuery = $0 })
    }

    private var clearButton: some View {
        Button {
            model.clearSearch()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(theme.ink4)
        }
        .buttonStyle(.carbonHover)
        .carbonTip("Clear the search")
    }

    /// CRATE or ALL. Widening moves you to All Records with the query intact,
    /// which the sidebar shows, so the browser never lists things the selected
    /// source does not contain.
    private var scopeToggle: some View {
        Button {
            ClickPlayer.shared.play(.key)
            model.setSearchScope(model.searchScope == .everywhere ? .source : .everywhere)
        } label: {
            Text(model.searchScope == .everywhere ? "ALL" : "CRATE")
                .font(CarbonFont.mono(8, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(model.searchScope == .everywhere ? theme.orange : theme.ink3)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(theme.chassisHi.opacity(model.searchScope == .everywhere ? 0.55 : 0.28))
                )
        }
        .buttonStyle(.carbonHover)
        .carbonTip("Search this crate only, or every crate you own")
    }
}
