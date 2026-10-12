import CrateDiggerCore
import SwiftUI

struct MainShell: View {
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let collapsedRailWidth: CGFloat = 36

    /// Emptying the Prep Crate also drops the saved dig folders, so one stray
    /// click must not do it. The sidebar's context-menu item is a deliberate
    /// act already; a key in a toolbar is not.
    @State private var confirmingClearPrepCrate = false

    var body: some View {
        HStack(spacing: geometry.mainGap) {
            sourcesSection
            browserSection
            inspectorSection
        }
        .frame(maxHeight: .infinity)
        // No implicit `.animation` out here. Keyed on the collapse flags it
        // also animated whatever else changed in that update, and Go to
        // Current Song and ⌘F expand the browser in the same breath as a
        // source switch or a cleared search, so a 14k-row list re-flowed on
        // a spring. Keyed on `oledView` it was worse: typing the first letter
        // of a search flips the display to SEARCH, so every new query pruned
        // the list under a 0.22 s ease. The panes move only when the user
        // moves one (`movePanes`); the inspector animates only its own swap.
    }

    /// Collapses or expands a pane on the surface spring. Only the chevrons
    /// and rails go through here, so only a pane change rides the animation;
    /// the model's own expansions (⌘F, ⌘L) land at once with the content
    /// they bring, which is what keeps the list out of the transaction.
    private func movePanes(_ change: () -> Void) {
        withAnimation(CarbonMotion.layout(CarbonMotion.panel, reduceMotion: reduceMotion), change)
    }

    // MARK: - Sources

    private var sourcesSection: some View {
        Group {
            if model.sourcesCollapsed {
                CollapsedRail(
                    title: "Sources",
                    subtitle: sourcesCollapsedSubtitle,
                    onExpand: { movePanes { model.sourcesCollapsed = false } }
                )
            } else {
                wellShell(
                    title: "Sources",
                    trailing: sourcesTrailing,
                    trailingControl: AnyView(collapseChevron(action: { movePanes { model.sourcesCollapsed = true } }))
                ) {
                    SourcesSidebar()
                }
            }
        }
        .frame(maxWidth: sourcesMaxWidth, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: geometry.wellCornerRadius, style: .continuous))
    }

    private var sourcesMaxWidth: CGFloat {
        model.sourcesCollapsed ? Self.collapsedRailWidth : geometry.sidebarWidth
    }

    private var sourcesCollapsedSubtitle: String? {
        let n = model.index.artists.count
        return n == 0 ? nil : String(format: "%02d ART", n)
    }

    // MARK: - Browser
    //
    // Browser has two states: condensed (compact track-list context column)
    // and full (Artist/Album/Track 3-pane). Both flex — it is the only
    // section that absorbs the chassis width.

    private var browserSection: some View {
        Group {
            if model.browserCollapsed {
                wellShell(
                    title: "Browser",
                    trailing: browserCollapsedTrailing,
                    trailingControl: nil
                ) {
                    BrowserCondensed(onExpand: { movePanes { model.toggleBrowserCollapsed() } })
                }
            } else {
                wellShell(
                    title: browserWellTitle,
                    trailing: browserWellTrailing,
                    trailingControl: AnyView(HStack(spacing: 6) {
                        // The gallery searches the same collections as the
                        // list, so its key is here too; columns and per-column
                        // sort are the list's alone.
                        if !model.isRadioMode {
                            searchToggleButton()
                        }
                        if !model.showArtworkGallery && !model.isRadioMode {
                            browserLayoutMenu()
                            sortToggleButton()
                        }
                        if showsClearPrepCrateKey {
                            clearPrepCrateButton()
                        }
                        collapseChevron(action: { movePanes { model.toggleBrowserCollapsed() } })
                    })
                ) {
                    VStack(spacing: 0) {
                        // Above the switch, not inside BrowserPane: the gallery
                        // reads the same filtered collections, so one field
                        // searches both browsers.
                        if model.isSearchAvailable && model.showSearchField {
                            BrowserSearchBar()
                        }
                        if model.isRadioMode {
                            RadioListView()
                        } else if model.showArtworkGallery {
                            ArtworkGalleryView()
                        } else {
                            BrowserPane()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: browserMaxWidth, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: geometry.wellCornerRadius, style: .continuous))
    }

    /// The browser always flexes: the inspector is a fixed-width column, so
    /// the browser is what absorbs the chassis width, condensed or not.
    private var browserMaxWidth: CGFloat { .infinity }

    private var browserCollapsedTrailing: String {
        let n = model.visibleTracks.count
        return n == 0 ? "—" : "\(n) TRK"
    }

    // MARK: - Inspector / Patch Bay

    private var inspectorSection: some View {
        Group {
            if model.inspectorCollapsed {
                CollapsedRail(
                    title: inspectorCollapsedTitle,
                    subtitle: inspectorCollapsedSubtitle,
                    onExpand: { movePanes { model.toggleInspectorCollapsed() } }
                )
            } else {
                wellShell(
                    title: inspectorWellTitle,
                    trailing: inspectorWellTrailing,
                    trailingControl: AnyView(collapseChevron(action: { movePanes { model.toggleInspectorCollapsed() } })),
                    above: showsInspectorChrome ? AnyView(InspectorTabBar()) : nil,
                    below: showsInspectorChrome ? AnyView(InspectorToolsBar()) : nil
                ) {
                    InspectorPane()
                }
            }
        }
        .frame(maxWidth: inspectorMaxWidth, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: geometry.wellCornerRadius, style: .continuous))
        // CONVERT and THEME swap what the well holds: the tab row and tools
        // step aside and the paper grows into their room while the content
        // crossfades (`InspectorPane`). Keyed on the surface, not `oledView`,
        // so NOW → SCAN → SEARCH, which leave the inspector alone, animate
        // nothing; and scoped to this column, so the browser beside it never
        // shares the transaction.
        .animation(CarbonMotion.movement(CarbonMotion.panel, reduceMotion: reduceMotion), value: inspectorSurface)
    }

    private var inspectorSurface: InspectorSurface {
        InspectorSurface(oledView: model.oledView, showingThemePicker: model.showingThemePicker)
    }

    /// Collapsed rail (36pt) or the fixed column width. Never flexes — a
    /// metadata column stretched across a wide window reads as empty chassis.
    private var inspectorMaxWidth: CGFloat {
        model.inspectorCollapsed ? Self.collapsedRailWidth : geometry.inspectorWidth
    }

    /// The patch bay and the theme picker take over the whole well, so the
    /// inspector's own tabs and tools step aside for them.
    private var showsInspectorChrome: Bool {
        inspectorSurface == .inspector
    }

    private var inspectorWellTitle: String {
        if model.oledView == .conversion {
            return "Conversion · Setup"
        }
        return "Inspector"
    }

    private var inspectorWellTrailing: String {
        if model.oledView == .conversion {
            let count = model.conversionQueueTracks.count
            return count == 0 ? "EMPTY" : "\(count) TRK · QUEUED"
        }
        if model.isRadioMode { return "Stream" }
        return "Rec. Metadata"
    }

    private var inspectorCollapsedTitle: String {
        model.oledView == .conversion ? "Conversion" : "Inspector"
    }

    private var inspectorCollapsedSubtitle: String? {
        if model.oledView == .conversion {
            let count = model.conversionQueueTracks.count
            return count == 0 ? "0 TRK" : "\(count) TRK"
        }
        return nil
    }

    // MARK: - Header bits

    private var sourcesTrailing: String {
        let n = model.index.artists.count
        return n == 0 ? "—" : String(format: "%02d", n)
    }

    private var browserSubtitle: String {
        if model.scanProgress.isRunning { return "Scanning" }
        if model.index.allTracks.isEmpty { return "Empty" }
        return "Library"
    }

    private var browserWellTitle: String {
        if model.isRadioMode { return "Browser · RADIO" }
        if model.showArtworkGallery { return "Browser · GALLERY" }
        return "Browser · \(browserSubtitle)"
    }

    private var browserWellTrailing: String {
        if model.isRadioMode {
            let n = model.filteredStreams.count
            return n == 0 ? "—" : "\(n) STREAMS"
        }
        return browserTrailing
    }

    /// While a search is live this says how much of the source it hid, so the
    /// well never claims four hundred records over twelve rows.
    private var browserTrailing: String {
        let total = model.index.allTracks.count
        guard total > 0 else { return "—" }
        if model.isSearchActive {
            return "\(model.browsedIndex.allTracks.count) OF \(total) RECORDS"
        }
        return "\(total) RECORDS"
    }

    // MARK: - Well shell builder

    /// `above` / `below` mount controls on the chassis, outside the paper
    /// panel — the inspector's tab row and library tools.
    private func wellShell<Inner: View>(
        title: String,
        trailing: String,
        trailingControl: AnyView? = nil,
        above: AnyView? = nil,
        below: AnyView? = nil,
        @ViewBuilder content: @escaping () -> Inner
    ) -> some View {
        RecessedWell {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(title.uppercased())
                        .font(CarbonFont.mono(9, weight: .bold))
                        .tracking(2.2)
                        .foregroundStyle(theme.ink2)
                        .lineLimit(1)
                    Spacer()
                    Text(trailing)
                        .font(CarbonFont.mono(9))
                        .foregroundStyle(theme.ink3)
                        .lineLimit(1)
                    if let trailingControl {
                        trailingControl
                    }
                }
                .padding(.horizontal, 4)

                if let above {
                    above.padding(.horizontal, 2)
                }

                PaperPanel {
                    content()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let below {
                    below.padding(.horizontal, 2)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func collapseChevron(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            chevronGlyph()
        }
        .buttonStyle(.carbonHover)
        .carbonTip("Collapse panel")
    }

    /// How many columns the browser has: 1, 2 or 3. What each shows is picked
    /// in the column's own header.
    private func browserLayoutMenu() -> some View {
        Menu {
            ForEach(1...BrowserView.maxColumns, id: \.self) { count in
                Button {
                    model.setColumnCount(count)
                } label: {
                    let title = count == 1 ? "1 Column" : "\(count) Columns"
                    if model.browserView.columnCount == count {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
        } label: {
            ZStack {
                ChromeChassis(theme: theme, cornerRadius: 4)
                    .frame(width: 18, height: 14)
                Image(systemName: columnCountIcon)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(theme.ink3)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .carbonTip("Browser columns: " + model.browserView.facets.map(\.title).joined(separator: " · "))
    }

    private var columnCountIcon: String {
        switch model.browserView.columnCount {
        case 1:  return "rectangle"
        case 2:  return "rectangle.split.2x1"
        default: return "rectangle.split.3x1"
        }
    }

    /// Shows the search field and puts the cursor in it, or puts it away.
    /// Lights while a query is live, so a filtered browser always has something
    /// on screen saying why.
    private func searchToggleButton() -> some View {
        Button(action: { model.toggleSearchField() }) {
            ZStack {
                ChromeChassis(theme: theme, cornerRadius: 4)
                    .frame(width: 18, height: 14)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(searchKeyColor)
            }
        }
        .buttonStyle(.carbonHover)
        .carbonTip(model.showSearchField ? "Hide the search field" : "Search the library (⌘F)")
    }

    private var searchKeyColor: Color {
        if model.isSearchActive { return theme.orange }
        return model.showSearchField ? theme.cyan : theme.ink3
    }

    /// The Prep Crate is staging, not storage, so the key that empties it
    /// belongs beside the other view controls of the browser showing it —
    /// never in DIG CRATE's slot in the header, which is the action you still
    /// want while the crate has something in it.
    private var showsClearPrepCrateKey: Bool {
        model.currentSource == .prepCrate && !model.prepCrateTracks.isEmpty
    }

    private func clearPrepCrateButton() -> some View {
        Button(action: { confirmingClearPrepCrate = true }) {
            ZStack {
                ChromeChassis(theme: theme, cornerRadius: 4)
                    .frame(width: 18, height: 14)
                Image(systemName: "trash")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(theme.red)
            }
        }
        .buttonStyle(.carbonHover)
        .carbonTip("Clear the Prep Crate — \(model.prepCrateTracks.count) staged track\(model.prepCrateTracks.count == 1 ? "" : "s") and the dig folders they came from")
        .confirmationDialog(
            "Clear the Prep Crate?",
            isPresented: $confirmingClearPrepCrate,
            titleVisibility: .visible
        ) {
            Button("Clear Crate", role: .destructive) { model.clearPrepCrate() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("\(model.prepCrateTracks.count) staged track\(model.prepCrateTracks.count == 1 ? "" : "s") leave the Prep Crate, along with the dig folders they came from. Nothing on disk is touched, and tracks already filed in a crate stay there.")
        }
    }

    /// Toggles the per-column sort menus in the browser headers.
    private func sortToggleButton() -> some View {
        Button(action: { model.showSortControls.toggle() }) {
            ZStack {
                ChromeChassis(theme: theme, cornerRadius: 4)
                    .frame(width: 18, height: 14)
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(model.showSortControls ? theme.cyan : theme.ink3)
            }
        }
        .buttonStyle(.carbonHover)
        .carbonTip(model.showSortControls ? "Hide sort controls" : "Show sort controls")
    }

    private func chevronGlyph() -> some View {
        let inset: CGFloat = 1
        return ZStack {
            ChromeChassis(theme: theme, cornerRadius: 4)
                .frame(width: 18, height: 14)
            Text("›|")
                .font(CarbonFont.mono(9, weight: .heavy))
                .foregroundStyle(theme.ink2)
                .padding(.horizontal, inset)
        }
    }
}

// MARK: - Collapsed rail (used by Sources + Inspector)

struct CollapsedRail: View {
    @Environment(\.carbon) private var theme
    let title: String
    var subtitle: String? = nil
    let onExpand: () -> Void

    var body: some View {
        RecessedWell(padding: 6) {
            VStack(spacing: 10) {
                Button(action: onExpand) {
                    chevron
                }
                .buttonStyle(.carbonHover)
                .carbonTip("Expand \(title)")

                Spacer(minLength: 0)

                Text(title.uppercased())
                    .font(CarbonFont.mono(9, weight: .bold))
                    .tracking(2.2)
                    .foregroundStyle(theme.ink2)
                    .rotationEffect(.degrees(-90))
                    .fixedSize()

                if let subtitle {
                    Spacer(minLength: 0)
                    Text(subtitle.uppercased())
                        .font(CarbonFont.mono(8.5, weight: .semibold))
                        .tracking(1.6)
                        .foregroundStyle(theme.ink3)
                        .rotationEffect(.degrees(-90))
                        .fixedSize()
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
    }

    private var chevron: some View {
        ZStack {
            ChromeChassis(theme: theme, cornerRadius: 5)
                .frame(width: 22, height: 18)
            Text("⟨⟩")
                .font(CarbonFont.mono(10, weight: .heavy))
                .foregroundStyle(theme.ink2)
        }
    }
}
