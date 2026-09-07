import CrateDiggerCore
import SwiftUI

/// The inspector's *content*. Its tabs and library tools live on the chassis
/// around it — see `InspectorChrome`.
struct InspectorPane: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    private var activeTab: InspectorTab { model.inspectorTab }

    /// A long album title is truncated to one line so the cover keeps the
    /// height; clicking it reveals the rest.
    @State private var titleExpanded = false

    /// The big INFO cover doubles as the ARTWORK button; it lights up behind
    /// itself on hover so that's discoverable without a label.
    @State private var hoveringCover = false

    var body: some View {
        ZStack {
            if model.oledView == .conversion {
                ConvertPatchBay()
                    .transition(.opacity)
            } else if model.showingThemePicker {
                ThemePickerPane()
                    .transition(.opacity)
            } else {
                inspectorContent
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.22), value: model.oledView)
        .animation(.easeInOut(duration: 0.22), value: model.showingThemePicker)
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

    @ViewBuilder
    private var inspectorContent: some View {
        switch activeTab {
        case .info:
            if model.isRadioMode, let stream = model.selectedStream {
                RadioInfoView(stream: stream)
            } else if hasInspectorTrackList {
                // Gallery mode puts the album's tracks in here, so the poster
                // stays modest and the whole column scrolls.
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        AlbumPoster(album: model.selectedAlbum)
                            .frame(width: 120, height: 120)
                            .padding(.vertical, 14)
                        captionBlock
                        SpecRows(album: model.selectedAlbum)
                        RatingStars()
                        trackListBlock
                    }
                }
            } else {
                // Everything below the poster is fixed height, so giving the
                // poster the leftover makes it as large as fits — no scroll,
                // no measuring, and it follows the window as it resizes.
                VStack(spacing: 0) {
                    coverButton
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    captionBlock
                    SpecRows(album: model.selectedAlbum)
                    RatingStars()
                }
            }

        case .art:
            ArtworkInspectorView(album: model.selectedAlbum)

        case .disc:
            SpinningRecordView(model: model, adjustable: true)
                .padding(20)

        case .queue:
            QueueInspectorView()
        }
    }

    /// The INFO cover: same action as the ARTWORK key, with a glow behind the
    /// sleeve on hover.
    private var coverButton: some View {
        let album = model.selectedAlbum
        return Button(action: { if let album { model.showArtwork(for: album) } }) {
            AlbumPoster(album: album)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(theme.orange)
                        .blur(radius: 14)
                        .opacity(hoveringCover && album != nil ? 0.55 : 0)
                )
        }
        .buttonStyle(.plain)
        .onHover { hoveringCover = $0 }
        .animation(.easeInOut(duration: 0.18), value: hoveringCover)
        .carbonTip(album?.booklet != nil ? "Open this album's digital booklet" : "View the album cover")
    }

    /// In gallery mode the browser shows covers only, so the inspector carries
    /// the selected album's track list (play / now-playing) here.
    private var hasInspectorTrackList: Bool {
        model.showArtworkGallery && !(model.selectedAlbum?.tracks.isEmpty ?? true)
    }

    @ViewBuilder
    private var trackListBlock: some View {
        if hasInspectorTrackList, let album = model.selectedAlbum {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tracks".uppercased())
                    .font(CarbonFont.mono(9, weight: .bold))
                    .tracking(1.8)
                    .foregroundStyle(theme.ink3)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                ForEach(Array(album.tracks.enumerated()), id: \.element.track.id) { index, loaded in
                    inspectorTrackRow(loaded, number: index + 1)
                }
            }
            .padding(.bottom, 12)
            .overlay(
                Rectangle()
                    .fill(theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.08))
                    .frame(height: 1),
                alignment: .top
            )
        }
    }

    private func inspectorTrackRow(_ loaded: LoadedTrack, number: Int) -> some View {
        let isNowPlaying = model.nowPlayingTrack?.track.id == loaded.track.id
        return Button(action: { model.playTrack(id: loaded.track.id) }) {
            HStack(spacing: 10) {
                Text(isNowPlaying ? "▸" : "\(number)")
                    .font(CarbonFont.mono(9.5, weight: .bold))
                    .foregroundStyle(isNowPlaying ? theme.orange : theme.ink4)
                    .frame(width: 16, alignment: .trailing)
                Text(loaded.track.title)
                    .font(CarbonFont.sans(11, weight: isNowPlaying ? .bold : .regular))
                    .foregroundStyle(isNowPlaying ? theme.ink : theme.ink2)
                    .lineLimit(1)
                Spacer()
                Text(loaded.track.durationSeconds > 0 ? loaded.track.durationSeconds.asClock : "--:--")
                    .font(CarbonFont.mono(9))
                    .foregroundStyle(theme.ink4)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 16)
            .background(isNowPlaying ? theme.orange.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.carbonHover)
        .contextMenu { BrowserContextMenu.track(loaded, model: model) }
    }

    @ViewBuilder
    private var captionBlock: some View {
        let album = model.selectedAlbum
        VStack(alignment: .leading, spacing: 5) {
            Text(album?.title ?? "—")
                .font(CarbonFont.sans(19, weight: .heavy))
                .foregroundStyle(theme.ink)
                .lineLimit(titleExpanded ? 3 : 1)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
                .onTapGesture { titleExpanded.toggle() }
            Text((album?.artistName ?? "—").uppercased())
                .font(CarbonFont.mono(10, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(theme.ink2)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .animation(.easeInOut(duration: 0.16), value: titleExpanded)
        .onChange(of: album?.id) { _ in titleExpanded = false }
        .overlay(
            Rectangle()
                .fill(theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.08))
                .frame(height: 1),
            alignment: .bottom
        )
    }

}


/// The inspector's tab set. Top-level (not nested/private) so `LibraryViewModel`
/// can hold the selection.
enum InspectorTab: String, CaseIterable {
    case info = "INFO"
    case queue = "QUEUE"
    case art = "ART"
    case disc = "DISC"
}
