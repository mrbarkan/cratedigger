import CrateDiggerCore
import SwiftUI

struct InspectorPane: View {
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry
    @EnvironmentObject private var model: LibraryViewModel

    @State private var showingCleanup = false
    /// One-time tip (dismissable) pointing at the ART tab's online art search,
    /// shown under OPEN ARTWORK when the album has no booklet to open.
    @AppStorage("cratedigger.tip.artTabSearch.hidden") private var hideArtTip = false

    /// The visible tab. Lives on the model rather than in local `@State` so
    /// anything outside the view tree can drive it — the dev shot list walks
    /// the inspector through its tabs to capture the website screenshots.
    private var activeTab: InspectorTab { model.inspectorTab }

    /// The DISC tab (spinning record) only makes sense for local files — it's
    /// disabled while browsing Radio / Streams.
    private func isTabDisabled(_ tab: InspectorTab) -> Bool {
        tab == .disc && model.isRadioMode
    }


    /// Width threshold above which the inspector switches from the default
    /// vertical layout (poster on top, metadata below) to a wide horizontal
    /// layout (metadata on the left, square poster on the right). Tuned to
    /// the inspector well width when the browser is collapsed: ~580pt+.
    private static let wideLayoutThreshold: CGFloat = 520

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
        // These three are tools you work *in*, so they get movable, resizable
        // panels rather than sheets pinned to the window. Bindings are unchanged.
        .carbonPanel(
            isPresented: $showingCleanup,
            title: "Library Cleanup",
            minSize: NSSize(width: 560, height: 420),
            initialSize: NSSize(width: 720, height: 560),
            maxSize: NSSize(width: 1200, height: 900),
            autosaveName: "cratedigger.panel.cleanup"
        ) {
            LibraryCleanupView().environmentObject(model)
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

    private var tabSwitcher: some View {
        HStack(spacing: 8) {
            tabButton(.info)
            tabButton(.art)
            tabButton(.disc)
            tabButton(.queue)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(
            Rectangle()
                .fill(theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.08))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private func tabButton(_ tab: InspectorTab) -> some View {
        KeyButton(
            style: activeTab == tab ? .selected : .normal,
            action: { model.inspectorTab = tab }
        ) {
            Text(tab.rawValue)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 22)
        .disabled(isTabDisabled(tab))
        .opacity(isTabDisabled(tab) ? 0.4 : 1)
        .carbonTip(isTabDisabled(tab) ? "Not available for Radio / Streams" : "")
    }


    private var inspectorContent: some View {
        VStack(spacing: 0) {
            tabSwitcher
            
            GeometryReader { geo in
                if geo.size.width >= Self.wideLayoutThreshold {
                    wideLayout(width: geo.size.width)
                } else {
                    narrowLayout(height: geo.size.height)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: activeTab)
        }
        // Entering Radio / Streams while on the DISC tab falls back to INFO.
        .onChange(of: model.isRadioMode) { isRadio in
            if isRadio && activeTab == .disc { model.inspectorTab = .info }
        }
    }

    // Default vertical layout: tab contents stacked
    @ViewBuilder
    private func narrowLayout(height: CGFloat) -> some View {
        switch activeTab {
        case .info:
            if model.isRadioMode, let stream = model.selectedStream {
                RadioInfoView(stream: stream)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        AlbumPoster(album: model.selectedAlbum)
                            .frame(width: 120, height: 120)
                            .padding(.vertical, 14)
                        captionBlock
                        SpecRows(album: model.selectedAlbum)
                        RatingStars()
                        TagChips(album: model.selectedAlbum)
                        utilitiesBlock
                        trackListBlock
                    }
                }
            }

        case .art:
            ArtworkInspectorView(album: model.selectedAlbum)
                .frame(height: height)

        case .disc:
            SpinningRecordView(model: model, adjustable: true)
                .padding(20)
                .frame(height: height)

        case .queue:
            QueueInspectorView()
                .frame(height: height)
        }
    }

    // Wide layout: metadata column on the left, square album art on the
    // right. Activated when the browser is collapsed and the inspector
    // takes the freed chassis width — better proportions for the artwork
    // and stops the metadata from being squashed.
    @ViewBuilder
    private func wideLayout(width: CGFloat) -> some View {
        let posterSize = min(max(width * 0.45, 280), 460)
        switch activeTab {
        case .info:
            if model.isRadioMode, let stream = model.selectedStream {
                RadioInfoView(stream: stream)
            } else {
                HStack(alignment: .top, spacing: 18) {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            captionBlock
                            SpecRows(album: model.selectedAlbum)
                            RatingStars()
                            TagChips(album: model.selectedAlbum)
                            utilitiesBlock
                            trackListBlock
                        }
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 0) {
                        AlbumPoster(album: model.selectedAlbum)
                            .frame(width: 140, height: 140)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 14)
                }
                .padding(EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14))
            }

        case .art:
            ArtworkInspectorView(album: model.selectedAlbum)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .disc:
            SpinningRecordView(model: model, adjustable: true)
                .frame(maxWidth: posterSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(14)

        // A list either way — the extra width has nothing to add to it.
        case .queue:
            QueueInspectorView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var utilitiesBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Library Tools".uppercased())
                .font(CarbonFont.mono(9, weight: .bold))
                .tracking(1.8)
                .foregroundStyle(theme.ink3)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            
            HStack(spacing: 8) {
                KeyButton(style: model.selectedTrack != nil ? .normal : .disabled, action: {
                    model.editTags(for: model.tracksForInspectorTagEdit())
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "tag.fill")
                            .font(.system(size: 9))
                        Text("EDIT TAGS")
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: geometry.keyHeight)
                
                // On a mounted device this slot becomes FIX ART: CLEANUP
                // reorganizes the *library*, which is meaningless while you're
                // looking at what's on a player, and repairing that player's
                // covers is the thing you actually reach for there.
                if model.browsedMountedDevice != nil {
                    KeyButton(style: model.canFixDeviceAlbumArt ? .normal : .disabled, action: {
                        model.fixDeviceAlbumArt()
                    }) {
                        HStack(spacing: 4) {
                            if model.isFixingDeviceArt {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.system(size: 9))
                            }
                            Text(model.isFixingDeviceArt ? "FIXING…" : "FIX ART")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: geometry.keyHeight)
                    .disabled(!model.canFixDeviceAlbumArt)
                    .carbonTip("Write a cover.jpg beside every album on this device, taken from the tracks already on it. Players that read folder art (Rockbox) pick it up; the audio files aren't touched.")
                } else {
                    KeyButton(style: .normal, action: {
                        showingCleanup = true
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 9))
                            Text("CLEANUP")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: geometry.keyHeight)
                }
                
                // Select tracks → re-probe them, then look the release up online
                // and offer the differences for review. With nothing selected it
                // falls back to a local-only sweep of the source (see
                // LibraryViewModel+MetadataRepair).
                // While a run is in flight the key becomes its own stop button —
                // a whole-library selection is thousands of file reads, and the
                // press that started it is where you look to end it.
                KeyButton(style: model.canRepairMetadata ? .normal : .disabled, action: {
                    if model.isRepairingMetadata {
                        model.cancelMetadataRepair()
                    } else {
                        model.repairMissingMetadata()
                    }
                }) {
                    HStack(spacing: 4) {
                        if model.isRepairingMetadata {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "bandage.fill")
                                .font(.system(size: 9))
                        }
                        Text(model.isRepairingMetadata ? "STOP" : "FIX TAGS")
                            .font(CarbonFont.mono(9, weight: .bold))
                            .tracking(1.0)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: geometry.keyHeight)
                .disabled(!model.canRepairMetadata)
                .carbonTip("Look up the selected tracks online (MusicBrainz · iTunes) and choose which tags to correct. If the names don't match anything, Deep Scan identifies them by their audio instead. With nothing selected, checks the whole source against the files without going online.")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, model.selectedAlbum == nil ? 12 : 8)

            // Opens the album's booklet if it has one, otherwise the cover.
            if let album = model.selectedAlbum {
                let hasBooklet = album.booklet != nil
                Button(action: { model.showArtwork(for: album) }) {
                    HStack(spacing: 7) {
                        Image(systemName: hasBooklet ? "book.fill" : "photo.fill").font(.system(size: 11))
                        Text("OPEN ARTWORK")
                            .font(CarbonFont.mono(10, weight: .bold))
                            .tracking(1.0)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: geometry.keyHeight)
                    .background(theme.orange)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .depthShadow(color: .black.opacity(0.2), radius: 3, y: 1)
                }
                .buttonStyle(.carbonHover)
                .carbonTip(hasBooklet ? "Open this album's digital booklet" : "View the album cover")
                .padding(.horizontal, 16)
                .padding(.bottom, (!hasBooklet && !hideArtTip) ? 6 : 12)

                // No booklet → nudge toward the ART tab's online art search.
                if !hasBooklet && !hideArtTip {
                    HStack(spacing: 6) {
                        Image(systemName: "lightbulb.fill").font(.system(size: 8.5))
                            .foregroundStyle(theme.sun)
                        Text("Search for cover art in the ART tab.")
                            .font(CarbonFont.mono(8.5, weight: .medium))
                            .foregroundStyle(theme.ink3)
                        Spacer(minLength: 4)
                        Button("Don't show") { hideArtTip = true }
                            .buttonStyle(.carbonHover)
                            .font(CarbonFont.mono(8, weight: .bold))
                            .foregroundStyle(theme.ink4)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }
        }
        .overlay(
            Rectangle()
                .fill(theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.08))
                .frame(height: 1),
            alignment: .top
        )
    }

    /// In gallery mode the browser shows covers only, so the inspector carries
    /// the selected album's track list (play / now-playing) here.
    @ViewBuilder
    private var trackListBlock: some View {
        if model.showArtworkGallery, let album = model.selectedAlbum, !album.tracks.isEmpty {
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
                .lineLimit(2)
                .minimumScaleFactor(0.82)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 7) {
                Text((album?.artistName ?? "—").uppercased())
                    .font(CarbonFont.mono(10, weight: .semibold))
                    .tracking(1.6)
                    .foregroundStyle(theme.ink2)
                    .lineLimit(1)
                if let year = album?.year {
                    Text("·")
                        .font(CarbonFont.mono(10, weight: .semibold))
                        .foregroundStyle(theme.ink4)
                    Text(String(year))
                        .font(CarbonFont.mono(10, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(theme.ink3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
    case art = "ART"
    case disc = "DISC"
    case queue = "QUEUE"
}
