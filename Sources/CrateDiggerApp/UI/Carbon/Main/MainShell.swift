import CrateDiggerCore
import SwiftUI

struct MainShell: View {
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry
    @EnvironmentObject private var model: LibraryViewModel

    private static let collapsedRailWidth: CGFloat = 36

    private static let collapseAnimation: Animation =
        .spring(response: 0.36, dampingFraction: 0.92)

    var body: some View {
        HStack(spacing: geometry.mainGap) {
            sourcesSection
            browserSection
            inspectorSection
        }
        .frame(maxHeight: .infinity)
        .animation(Self.collapseAnimation, value: model.sourcesCollapsed)
        .animation(Self.collapseAnimation, value: model.browserCollapsed)
        .animation(Self.collapseAnimation, value: model.inspectorCollapsed)
        .animation(.easeInOut(duration: 0.22), value: model.oledView)
        .sheet(isPresented: $model.showingAddStreamSheet) {
            AddStreamSheet()
        }
        .sheet(isPresented: $model.showingRecordDividerSheet) {
            RecordDividerSheet()
        }
        .sheet(isPresented: $model.showingOnboarding) {
            OnboardingView()
        }
        .sheet(isPresented: $model.showingWelcomeTour,
               onDismiss: { model.welcomeTourDidDismiss() }) {
            WelcomeTourView()
        }
        .sheet(isPresented: $model.showingWhatsNew,
               onDismiss: { model.whatsNewDidDismiss() }) {
            WhatsNewView()
        }
        // Edit Tags is a working panel: movable and resizable so it can sit
        // beside the browser instead of covering it.
        .carbonPanel(
            isPresented: Binding(
                get: { model.tagEditTarget != nil },
                set: { if !$0 { model.tagEditTarget = nil } }
            ),
            title: "Edit Tags",
            minSize: NSSize(width: 520, height: 420),
            initialSize: NSSize(width: 640, height: 620),
            maxSize: NSSize(width: 900,  height: 1000),
            autosaveName: "cratedigger.panel.editTags"
        ) {
            if let target = model.tagEditTarget {
                MetadataEditorView(tracks: target.tracks).environmentObject(model)
            }
        }
        .sheet(isPresented: $model.showingEQEditor) {
            EqualizerEditorView()
        }
        // "View Artwork": a PDF booklet opens the rich page reader; everything
        // else (cover, booklet scans, inlay, disc, back, tray) flows through the
        // unified artwork navigator. Both float in their own window, so neither
        // disturbs the current source/selection. The album is a one-shot trigger.
        .onChange(of: model.artworkViewerAlbum) { album in
            guard let album else { return }
            if let booklet = album.booklet, case .pdf = booklet.source {
                BookletWindowManager.shared.showBooklet(booklet,
                                                        albumTitle: album.title,
                                                        artistName: album.artistName,
                                                        theme: theme)
            } else {
                ArtworkViewerPresenter.show(album: album, theme: theme, model: model)
            }
            model.artworkViewerAlbum = nil
        }
    }

    // MARK: - Sources

    private var sourcesSection: some View {
        Group {
            if model.sourcesCollapsed {
                CollapsedRail(
                    title: "Sources",
                    subtitle: sourcesCollapsedSubtitle,
                    onExpand: { model.sourcesCollapsed = false }
                )
            } else {
                wellShell(
                    title: "Sources",
                    trailing: sourcesTrailing,
                    trailingControl: AnyView(collapseChevron(action: { model.sourcesCollapsed = true }))
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
                    BrowserCondensed(onExpand: { model.toggleBrowserCollapsed() })
                }
            } else {
                wellShell(
                    title: browserWellTitle,
                    trailing: browserWellTrailing,
                    trailingControl: AnyView(HStack(spacing: 6) {
                        if !model.showArtworkGallery && !model.isRadioMode {
                            searchToggleButton()
                            browserLayoutMenu()
                            sortToggleButton()
                        }
                        collapseChevron(action: { model.toggleBrowserCollapsed() })
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
                    onExpand: { model.toggleInspectorCollapsed() }
                )
            } else {
                wellShell(
                    title: inspectorWellTitle,
                    trailing: inspectorWellTrailing,
                    trailingControl: AnyView(collapseChevron(action: { model.toggleInspectorCollapsed() })),
                    above: showsInspectorChrome ? AnyView(InspectorTabBar()) : nil,
                    below: showsInspectorChrome ? AnyView(InspectorToolsBar()) : nil
                ) {
                    InspectorPane()
                }
            }
        }
        .frame(maxWidth: inspectorMaxWidth, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: geometry.wellCornerRadius, style: .continuous))
    }

    /// Collapsed rail (36pt) or the fixed column width. Never flexes — a
    /// metadata column stretched across a wide window reads as empty chassis.
    private var inspectorMaxWidth: CGFloat {
        model.inspectorCollapsed ? Self.collapsedRailWidth : geometry.inspectorWidth
    }

    /// The patch bay and the theme picker take over the whole well, so the
    /// inspector's own tabs and tools step aside for them.
    private var showsInspectorChrome: Bool {
        model.oledView != .conversion && !model.showingThemePicker
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
