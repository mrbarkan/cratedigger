import CrateDiggerCore
import SwiftUI

struct MainShell: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    private static let collapsedRailWidth: CGFloat = 36
    private static let condensedBrowserWidth: CGFloat = 200

    private static let collapseAnimation: Animation =
        .spring(response: 0.36, dampingFraction: 0.92)

    var body: some View {
        HStack(spacing: CarbonLayout.mainGap) {
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
        .sheet(item: $model.tagEditTarget) { target in
            MetadataEditorView(tracks: target.tracks)
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
        .clipShape(RoundedRectangle(cornerRadius: CarbonLayout.wellCornerRadius, style: .continuous))
    }

    private var sourcesMaxWidth: CGFloat {
        model.sourcesCollapsed ? Self.collapsedRailWidth : CarbonLayout.sidebarWidth
    }

    private var sourcesCollapsedSubtitle: String? {
        let n = model.index.artists.count
        return n == 0 ? nil : String(format: "%02d ART", n)
    }

    // MARK: - Browser
    //
    // Browser has two states: condensed (compact track-list context column,
    // fixed 200pt) and full (Artist/Album/Track 3-pane, flex). When the
    // inspector is also collapsed the browser flexes — see flex math below.

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
                            browserLayoutMenu()
                            sortToggleButton()
                        }
                        collapseChevron(action: { model.toggleBrowserCollapsed() })
                    })
                ) {
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
        .frame(maxWidth: browserMaxWidth, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: CarbonLayout.wellCornerRadius, style: .continuous))
    }

    /// Browser is at 200pt when condensed AND inspector is full (so inspector
    /// can flex). When BOTH are condensed/collapsed, the invariant in the
    /// view-model prevents this — but as a defense in depth, browser flexes
    /// to absorb leftover space if it would otherwise leave dead chassis.
    private var browserMaxWidth: CGFloat {
        if model.browserCollapsed && !model.inspectorCollapsed {
            return Self.condensedBrowserWidth
        }
        return .infinity
    }

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
                    trailingControl: AnyView(collapseChevron(action: { model.toggleInspectorCollapsed() }))
                ) {
                    InspectorPane()
                }
            }
        }
        .frame(maxWidth: inspectorMaxWidth, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: CarbonLayout.wellCornerRadius, style: .continuous))
    }

    /// Inspector has three target widths:
    /// - collapsed rail (36pt fixed)
    /// - default narrow (380pt fixed) — when browser is full
    /// - flex (`.infinity`) — when browser is collapsed/condensed, so the
    ///   inspector takes the freed chassis width
    private var inspectorMaxWidth: CGFloat {
        if model.inspectorCollapsed { return Self.collapsedRailWidth }
        if model.browserCollapsed   { return .infinity }
        return CarbonLayout.inspectorWidth
    }

    private var inspectorWellTitle: String {
        if model.oledView == .conversion {
            return "Conversion · Patch Bay"
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

    private var browserTrailing: String {
        let n = model.index.allTracks.count
        return n == 0 ? "—" : "\(n) RECORDS"
    }

    // MARK: - Well shell builder

    private func wellShell<Inner: View>(
        title: String,
        trailing: String,
        trailingControl: AnyView? = nil,
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

                PaperPanel {
                    content()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func collapseChevron(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            chevronGlyph()
        }
        .buttonStyle(.plain)
        .carbonTip("Collapse panel")
    }

    /// Menu to pick the browser column layout (3-pane / Album·Track / flat Track).
    private func browserLayoutMenu() -> some View {
        Menu {
            ForEach(BrowserLayout.allCases, id: \.self) { layout in
                Button {
                    model.browserLayout = layout
                } label: {
                    if model.browserLayout == layout {
                        Label(layout.title, systemImage: "checkmark")
                    } else {
                        Text(layout.title)
                    }
                }
            }
        } label: {
            ZStack {
                ChromeChassis(theme: theme, cornerRadius: 4)
                    .frame(width: 18, height: 14)
                Image(systemName: model.browserLayout.iconName)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(theme.ink3)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .carbonTip("Browser columns")
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
        .buttonStyle(.plain)
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
                .buttonStyle(.plain)
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
