import AppKit
import CrateDiggerCore
import SwiftUI

/// Every sheet, panel and one-shot window trigger the app presents from
/// model state. They live on the root, above the layout switch, because the
/// compact player removes `MainShell` and the inspector from the tree: a
/// sheet attached there would never show, and a `carbonPanel` would close
/// on disappear but leave its model flag set, so it could never reopen.
private struct LibraryPresentations: ViewModifier {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    func body(content: Content) -> some View {
        content
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
            .onChange(of: model.fullScreenPlayerRequested) { requested in
                guard requested else { return }
                NowPlayingFullScreenPresenter.toggle(theme: theme, model: model)
                model.fullScreenPlayerRequested = false
            }
            // FIX TAGS conflict review — driven by the conflicts themselves so a
            // repair pass with no disagreements never flashes an empty panel.
            .carbonPanel(
                isPresented: Binding(
                    get: { !model.metadataRepairConflicts.isEmpty },
                    set: { if !$0 { model.metadataRepairConflicts = [] } }
                ),
                title: "Fix Tags",
                minSize: NSSize(width: 560, height: 400),
                initialSize: NSSize(width: 720, height: 560),
                maxSize: NSSize(width: 1100, height: 900),
                autosaveName: "cratedigger.panel.fixTags"
            ) {
                MetadataRepairSheetView().environmentObject(model)
            }
            // FIX TAGS online match review — same pattern: the matches are the state.
            .carbonPanel(
                isPresented: Binding(
                    get: { !model.metadataMatches.isEmpty },
                    set: { if !$0 { model.cancelMatchQueue() } }
                ),
                title: "Match Tags Online",
                minSize: NSSize(width: 620, height: 460),
                initialSize: NSSize(width: 820, height: 620),
                maxSize: NSSize(width: 1200, height: 950),
                autosaveName: "cratedigger.panel.matchTags"
            ) {
                MetadataMatchSheetView().environmentObject(model)
            }
    }
}

extension View {
    func libraryPresentations() -> some View {
        modifier(LibraryPresentations())
    }
}
