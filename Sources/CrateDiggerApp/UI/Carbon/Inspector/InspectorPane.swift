import CrateDiggerCore
import SwiftUI

struct InspectorPane: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel

    @State private var showingCleanup = false
    @State private var activeTab: InspectorTab = .info
    /// One-time tip (dismissable) pointing at the ART tab's online art search,
    /// shown under OPEN ARTWORK when the album has no booklet to open.
    @AppStorage("cratedigger.tip.artTabSearch.hidden") private var hideArtTip = false

    private enum InspectorTab: String, CaseIterable {
        case info = "INFO"
        case art = "ART"
        case disc = "DISC"
    }

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
            } else {
                inspectorContent
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.22), value: model.oledView)
        .sheet(isPresented: $showingCleanup) {
            LibraryCleanupView()
        }
    }

    private var tabSwitcher: some View {
        HStack(spacing: 8) {
            tabButton(.info)
            tabButton(.art)
            tabButton(.disc)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
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
            action: { activeTab = tab }
        ) {
            Text(tab.rawValue)
                .font(CarbonFont.mono(9, weight: .bold))
                .tracking(1.5)
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
            if isRadio && activeTab == .disc { activeTab = .info }
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
            VStack {
                Spacer()
                SpinningRecordView(model: model)
                    .padding(20)
                Spacer()
            }
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
            HStack {
                Spacer()
                SpinningRecordView(model: model)
                    .frame(width: posterSize, height: posterSize)
                Spacer()
            }
            .padding(14)
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
                    if let track = model.selectedTrack { model.editTags(for: [track]) }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "tag.fill")
                            .font(.system(size: 9))
                        Text("EDIT TAGS")
                            .font(CarbonFont.mono(9, weight: .bold))
                            .tracking(1.0)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: CarbonLayout.keyHeight)
                
                KeyButton(style: .normal, action: {
                    showingCleanup = true
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9))
                        Text("CLEANUP")
                            .font(CarbonFont.mono(9, weight: .bold))
                            .tracking(1.0)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: CarbonLayout.keyHeight)
                
                KeyButton(style: .normal, action: {
                    model.automaticallyReorganizeLibrary()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 9))
                        Text("ORGANIZE")
                            .font(CarbonFont.mono(9, weight: .bold))
                            .tracking(1.0)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: CarbonLayout.keyHeight)
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
                    .frame(height: CarbonLayout.keyHeight)
                    .background(theme.orange)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                }
                .buttonStyle(.plain)
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
                            .buttonStyle(.plain)
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
        .buttonStyle(.plain)
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

