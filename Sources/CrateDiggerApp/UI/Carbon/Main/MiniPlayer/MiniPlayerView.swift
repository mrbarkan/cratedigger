import CrateDiggerCore
import SwiftUI

/// Mini player art treatment, cycled by the top-bar art button. Disc follows
/// the album's marked media format (Art tab dropdown) — vinyl shows only when
/// the album is explicitly marked Vinyl; Auto reads as CD.
enum MiniPlayerArtMode: String, CaseIterable {
    // Raw value stays "cd" so pre-existing saved prefs restore; an old saved
    // "vinyl" fails the rawValue init and falls back to the default (.disc).
    case disc = "cd"
    case cover

    var next: MiniPlayerArtMode {
        self == .disc ? .cover : .disc
    }

    var iconName: String {
        switch self {
        case .disc:  return "opticaldisc"
        case .cover: return "photo"
        }
    }

    var label: String {
        switch self {
        case .disc:  return "Disc"
        case .cover: return "Album Cover"
        }
    }
}

/// The floating mini player: a light Carbon strip that mirrors the full app's
/// playback (same `LibraryViewModel`), with a pull-out panel underneath for
/// what is coming and for putting something else on without opening the
/// full window.
struct MiniPlayerView: View {
    /// Follows the global Light/Dark choice, like `ThemedSheetWrapper`. It used
    /// to be pinned to `.dark`, which left it dark glass while the rest of the
    /// app was in the light theme.
    @AppStorage(AppearanceMode.userDefaultsKey) private var rawMode: String = AppearanceMode.system.rawValue
    @ObservedObject var model: LibraryViewModel
    let onExpand: () -> Void
    /// The panel was opened or closed. The window controller animates the
    /// window to `height(panelOpen:)`; the drawer below follows the window's
    /// edge, so the animation is the window's.
    let onPanelChange: (Bool) -> Void

    @State private var panelOpen = false
    @State private var panelTab: MiniPlayerPanelTab = .sources
    @State private var appeared = false

    // MARK: Fixed geometry
    //
    // The controller sizes the window from these, so they have to agree with
    // the layout. They are sums of the fixed frames and paddings below; a
    // change to either side without the other shows up at once as a drawer
    // that stops short or a deck with a gap under it.

    static let width: CGFloat = 272
    /// The deck: 13 pad, 22 bar + 11, 246 art, 13 + 72 OLED, 12 + 54
    /// transport (the play dome is the tallest key), 12 + 11 rail, 13 pad.
    static let deckHeight: CGFloat = 479
    /// The drawer's visible part: 34 tabs (22 + 6 + 6), 300 list, 13 pad.
    static let drawerHeight: CGFloat = 347
    /// How far the drawer runs up behind the deck, so the seam between the
    /// two is the deck's own rounded foot and never a hairline gap.
    static let drawerOverlap: CGFloat = 40

    static func height(panelOpen: Bool) -> CGFloat {
        panelOpen ? deckHeight + drawerHeight : deckHeight
    }

    var body: some View {
        // A slider phone: the drawer is the keypad half, parked behind the
        // screen half, and the window's bottom edge drags it out. It is always
        // in the tree; only its offset moves, and that is a pure function of
        // the window's live height, so opening and closing are the same code
        // run in opposite directions and there is no state to get out of step.
        GeometryReader { window in
            let travel = window.size.height - Self.height(panelOpen: true)
            ZStack(alignment: .top) {
                MiniPlayerDrawer(model: model, tab: $panelTab)
                    .frame(height: Self.drawerHeight + Self.drawerOverlap)
                    .offset(y: Self.deckHeight - Self.drawerOverlap + travel)
                MiniPlayerBody(
                    model: model, clock: model.playbackClock, onExpand: onExpand,
                    panelOpen: $panelOpen, panelTab: $panelTab, onPanelChange: onPanelChange
                )
                .frame(height: Self.deckHeight)
                // The deck sits *on* the drawer once it is out, so it casts
                // onto it. Faded with the travel: while parked, the deck's foot
                // is the window's own edge, and a shadow clipped there draws as
                // a hard rectangular line around the window. Plain `.shadow`, not
                // `depthShadow`: this is one part sliding over another, and a
                // flat theme still needs to show where the deck ends.
                .shadow(color: .black.opacity(0.3 * (1 + travel / Self.drawerHeight)), radius: 10, y: 5)
            }
            .frame(width: Self.width, height: max(window.size.height, 1), alignment: .top)
        }
        .frame(width: Self.width)
        .carbonThemed(mode: AppearanceMode(rawValue: rawMode) ?? .system)
        .onAppear {
            guard !appeared else { return }
            appeared = true
            let playing = model.nowPlayingTrack != nil || model.isStreamActive
            panelTab = MiniPlayerPanelTab.initial(isPlaying: playing, isStream: model.isStreamActive)
            panelOpen = MiniPlayerPanelTab.opensExpanded(isPlaying: playing)
            onPanelChange(panelOpen)
        }
        .onExitCommand {
            guard panelOpen else { return }
            panelOpen = false
            onPanelChange(false)
        }
    }
}

/// The lower half: UP NEXT / SOURCES on their own glass body.
private struct MiniPlayerDrawer: View {
    @ObservedObject var model: LibraryViewModel
    @Binding var tab: MiniPlayerPanelTab
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            MiniPlayerPanel(model: model, tab: $tab)
                .padding(.horizontal, 13)
                .padding(.bottom, 13)
        }
        .frame(width: MiniPlayerView.width)
        .background(MiniPlayerGlass(cornerRadius: geometry.scaled(22, following: \.chassisCornerRadius)))
    }
}

/// The glass both halves are made of.
private struct MiniPlayerGlass: View {
    @Environment(\.carbon) private var theme
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(theme.chassis) // opaque, not Material — see ChassisLayer
            .overlay(
                shape.fill(LinearGradient(
                    colors: [theme.chassisHi.opacity(0.5), theme.chassis.opacity(0.55), theme.chassisLo.opacity(0.62)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
    }
}

/// The upper half: art, readout, transport. The screen half of the slider.
private struct MiniPlayerBody: View {
    @ObservedObject var model: LibraryViewModel
    /// Deliberately NOT observed here. The clock ticks ~5×/s, and observing it
    /// at this level re-evaluated the whole panel on every tick. Only the two
    /// leaf views that actually show time observe it (`MiniPlayerTimeReadout`,
    /// `MiniPlayerSeekRail`).
    let clock: PlaybackClock
    let onExpand: () -> Void
    @Binding var panelOpen: Bool
    @Binding var panelTab: MiniPlayerPanelTab
    let onPanelChange: (Bool) -> Void
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry

    /// Cover for the COVER art mode, resolved off-main like AlbumPoster.
    @State private var coverImage: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            artFrame
            oledDisplay.padding(.top, 13)
            transport
            MiniPlayerSeekRail(model: model, clock: clock, theme: theme)
                .padding(.top, 12).padding(.horizontal, 2)
        }
        .padding(13)
        .frame(width: MiniPlayerView.width)
        .background(MiniPlayerGlass(cornerRadius: geometry.scaled(22, following: \.chassisCornerRadius)))
        // Drawn above the drawer, and the glass is opaque, so the drawer is
        // out of sight while it is parked behind.
        .compositingGroup()
        .task(id: coverKey) { await loadCoverImage() }
    }

    private func setPanel(open: Bool) {
        ClickPlayer.shared.play(.key)
        if open {
            let playing = model.nowPlayingTrack != nil || model.isStreamActive
            panelTab = MiniPlayerPanelTab.initial(isPlaying: playing, isStream: model.isStreamActive)
        }
        // No SwiftUI animation on purpose: the window animates, and the
        // drawer's position is a function of the window's height.
        panelOpen = open
        onPanelChange(open)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(theme.keyLamp).frame(width: 6, height: 6)
                    .shadow(color: theme.keyLamp.opacity(0.8), radius: 3)
                Text(model.isStreamActive ? "ON AIR" : "NOW PLAYING")
                    .font(CarbonFont.mono(9, weight: .bold)).tracking(2)
                    .foregroundStyle(theme.ink3)
            }
            Spacer(minLength: 0)
            iconButton(system: panelOpen ? "chevron.up" : "list.bullet",
                       lit: panelOpen,
                       help: panelOpen ? "Close the panel" : "Up Next and Sources") {
                setPanel(open: !panelOpen)
            }
            artModeButton
            iconButton(system: "arrow.up.left.and.arrow.down.right", help: "Open the full app") {
                onExpand()
            }
        }
        .frame(height: 22)
        .padding(.bottom, 11)
        .padding(.horizontal, 2)
    }

    private var artModeButton: some View {
        Button(action: {
            ClickPlayer.shared.play(.key)
            model.miniPlayerArtMode = model.miniPlayerArtMode.next
        }) {
            Image(systemName: model.miniPlayerArtMode.iconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(artModeDisabled ? theme.ink4.opacity(0.5) : theme.ink3)
                .frame(width: 24, height: 24)
                .background(ChromeChassis(theme: theme, cornerRadius: geometry.scaled(7, following: \.keyCornerRadius)))
        }
        .buttonStyle(.carbonHover)
        .disabled(artModeDisabled)
        .carbonTip("Art: \(model.miniPlayerArtMode.label). Tap to cycle")
        .padding(.leading, 6)
    }

    /// Nothing to cycle while a stream owns the deck: both modes would draw
    /// the same thumbnail.
    private var artModeDisabled: Bool { model.isRadioMode || model.isStreamActive }

    private func iconButton(system: String, lit: Bool = false, help: String, action: @escaping () -> Void) -> some View {
        Button(action: { ClickPlayer.shared.play(.key); action() }) {
            Image(systemName: system)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(lit ? theme.orange : theme.ink3)
                .frame(width: 24, height: 24)
                .background(ChromeChassis(theme: theme, cornerRadius: geometry.scaled(7, following: \.keyCornerRadius)))
        }
        .buttonStyle(.carbonHover)
        .carbonTip(help)
        .padding(.leading, 6)
    }

    // MARK: - Art

    private var artFrame: some View {
        let shape = RoundedRectangle(cornerRadius: geometry.scaled(14, following: \.paperCornerRadius),
                                     style: .continuous)
        return ZStack {
            shape.fill(theme.wellDeep)
            artContent
            shape
                .fill(LinearGradient(colors: [Color.white.opacity(0.16), .clear],
                                     startPoint: .topLeading, endPoint: .center))
                .allowsHitTesting(false)
        }
        .frame(width: 246, height: 246)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.black.opacity(0.6), lineWidth: 1))
        // A sleeve laid on the card, not a tile floating over it.
        .depthShadow(color: .black.opacity(0.18), radius: 5, y: 2)
    }

    // MARK: - OLED display (title / band / album · time)

    private var oledDisplay: some View {
        let shape = RoundedRectangle(cornerRadius: geometry.scaled(10, following: \.oledCornerRadius),
                                     style: .continuous)
        return shape
            .fill(theme.oledSurface)
            .overlay(Scanlines(opacity: 0.02).clipShape(shape))
            .overlay(shape.strokeBorder(theme.oledStrokeInner, lineWidth: 1.5))
            .overlay(
                // Same faces as the main display's NOW screen: the display
                // face for the title, the mono for the two lines under it.
                VStack(alignment: .leading, spacing: 4) {
                    Text(trackTitle)
                        .font(CarbonFont.display(18, weight: .thin))
                        .tracking(-0.4)
                        .foregroundStyle(theme.oledForeground)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(band)
                        .font(CarbonFont.mono(9.5, weight: .semibold)).tracking(1.9)
                        .textCase(.uppercase)
                        .foregroundStyle(theme.oledForeground.opacity(0.52))
                        .lineLimit(1)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(album)
                            .font(CarbonFont.mono(9.5, weight: .semibold)).tracking(1.9)
                            .textCase(.uppercase)
                            .foregroundStyle(theme.oledForeground.opacity(0.52))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        MiniPlayerTimeReadout(model: model, clock: clock)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            )
            .frame(height: 72)
            .compositingGroup()
    }

    @ViewBuilder
    private var artContent: some View {
        // A stream has no disc and no album cover. Falling through to the art
        // modes drew the last local track's record, which reads as that album
        // playing while a YouTube set is on the air.
        if model.isStreamActive, let stream = model.selectedStream {
            StreamThumbnail(stream: stream)
        } else {
            localArtContent
        }
    }

    @ViewBuilder
    private var localArtContent: some View {
        switch model.miniPlayerArtMode {
        case .cover:
            if let image = coverImage {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color(hex: 0xD97757), Color(hex: 0xC14A2E)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        case .disc:
            SpinningRecordView(model: model).padding(10)
        }
    }

    /// Reload key: track change or a freshly committed cover (hash change).
    private var coverKey: String {
        if model.isStreamActive { return "stream-\(model.selectedStreamID ?? "none")" }
        let track = model.nowPlayingTrack?.track
        return "\(track?.id.uuidString ?? "none")-\(track?.artworkHash ?? "")"
    }

    /// Same resolution order as AlbumPoster: album cover file on disk first,
    /// then cached bytes by hash, then the audio file itself.
    private func loadCoverImage() async {
        guard let loaded = model.nowPlayingTrack else {
            coverImage = nil
            return
        }
        if let album = model.album(containing: loaded.track.id),
           let coverURL = album.booklet?.frontCoverURL,
           let image = await loadThumbnail(url: coverURL, maxPixelSize: 480) {
            coverImage = image
            return
        }
        if let hash = loaded.track.artworkHash,
           let image = await model.artworkService.thumbnailAsync(artworkHash: hash, maxPixel: 480) {
            coverImage = image
            return
        }
        if loaded.track.fileURL.isFileURL,
           let asset = await model.artworkService.resolveArtwork(trackURL: loaded.track.fileURL) {
            coverImage = await model.artworkService.thumbnailAsync(artworkHash: asset.hash, maxPixel: 480)
            return
        }
        coverImage = nil
    }

    private var trackTitle: String {
        if model.isStreamActive, let stream = model.selectedStream { return stream.title }
        return model.nowPlayingTrack?.track.title ?? "Nothing Playing"
    }

    private var band: String {
        if model.isStreamActive, let stream = model.selectedStream {
            return stream.channel.isEmpty ? "LIVE" : stream.channel.uppercased()
        }
        guard let t = model.nowPlayingTrack?.track else { return "PICK SOMETHING BELOW" }
        return t.artist.uppercased()
    }

    /// Third line. A stream has no album; the time readout still sits here.
    private var album: String {
        if model.isStreamActive { return "" }
        return (model.nowPlayingTrack?.track.album ?? "").uppercased()
    }

    // MARK: - Transport

    /// The footer's transport row, scaled to the card: the round play dome in
    /// the middle, one size up, is the only key that lights while playing;
    /// the four square keys beside it are the footer's, and shuffle and
    /// repeat light when they are on.
    private var transport: some View {
        HStack(spacing: 6) {
            transportKey("shuffle", lit: model.shuffleEnabled, tip: "Shuffle") { model.toggleShuffle() }
            transportKey("backward.end.fill", tip: "Previous") { model.previous() }
            Button(action: { ClickPlayer.shared.play(.firm); model.togglePlayPause() }) {
                SiliconeCap(shape: Circle(), lit: model.playbackState == .playing, shadowScale: 0.6) {
                    Image(systemName: "playpause.fill").font(.system(size: 17, weight: .black))
                }
                .frame(width: 54, height: 54)
            }
            .buttonStyle(.carbonHover)
            .carbonTip("Play / Pause")
            .accessibilityLabel(model.playbackState == .playing ? "Pause" : "Play")
            transportKey("forward.end.fill", tip: "Next") { model.next() }
            transportKey(repeatIcon, lit: model.repeatMode != .off, tip: "Repeat") { model.cycleRepeatMode() }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    private var repeatIcon: String {
        model.repeatMode == .one ? "repeat.1" : "repeat"
    }

    private func transportKey(_ system: String, lit: Bool = false, tip: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: { ClickPlayer.shared.play(.key); action() }) {
            SiliconeCap(shape: RoundedRectangle(cornerRadius: 11, style: .continuous), lit: lit, shadowScale: 0.6) {
                Image(systemName: system).font(.system(size: 13, weight: .semibold))
            }
            .frame(width: 40, height: 40)
        }
        .buttonStyle(.carbonHover)
        .carbonTip(tip)
        .accessibilityLabel(tip)
    }
}

// MARK: - The pull-out panel

/// UP NEXT and SOURCES under the deck. Rows are the browser's language at a
/// smaller size, so the panel reads as the same hardware rather than a menu.
private struct MiniPlayerPanel: View {
    @ObservedObject var model: LibraryViewModel
    @Binding var tab: MiniPlayerPanelTab
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry

    /// Tall enough for a dozen rows, short enough that a library with forty
    /// crates does not become a two-foot window.
    private static let listHeight: CGFloat = 300

    var body: some View {
        let well = RoundedRectangle(cornerRadius: geometry.scaled(12, following: \.wellCornerRadius),
                                    style: .continuous)
        VStack(spacing: 0) {
            tabs
            Group {
                switch tab {
                case .upNext:  upNext
                case .sources: sources
                }
            }
            .frame(height: Self.listHeight)
        }
        .background(
            well
                .fill(theme.well.opacity(theme.isDark ? 0.75 : 0.9))
                .overlay(well.strokeBorder(theme.hair.opacity(theme.isDark ? 0.6 : 0.8), lineWidth: 1))
        )
        .clipShape(well)
        // Dragging inside the lists must scroll and reorder, not move the window.
        .background(WindowDragGuard())
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(MiniPlayerPanelTab.allCases, id: \.self) { candidate in
                Button {
                    ClickPlayer.shared.play(.key)
                    tab = candidate
                } label: {
                    Text(candidate.title)
                        .font(CarbonFont.mono(8.5, weight: .bold))
                        .tracking(1.8)
                        .foregroundStyle(tab == candidate ? theme.orange : theme.ink3)
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: geometry.scaled(6, following: \.keyCornerRadius),
                                             style: .continuous)
                                .fill(tab == candidate ? theme.orange.opacity(0.14) : Color.clear)
                        )
                }
                .buttonStyle(.carbonHover)
            }
        }
        .padding(6)
        .overlay(
            Rectangle()
                .fill(theme.hair.opacity(theme.isDark ? 0.5 : 0.8))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    // MARK: Up Next

    @ViewBuilder private var upNext: some View {
        if model.isStreamActive {
            notice("A stream is playing.\nUp Next is for library tracks.")
        } else if !model.hasUpNext {
            notice(model.nowPlayingTrack == nil
                   ? "Nothing playing.\nPick a crate or a stream under Sources."
                   : "Nothing up next.")
        } else {
            List {
                ForEach(Array(model.upNextTracks.enumerated()), id: \.element.track.id) { offset, loaded in
                    MiniQueueRow(
                        loaded: loaded,
                        position: offset + 1,
                        onPlay: { model.playFromQueue(trackID: loaded.track.id) },
                        onRemove: { model.removeFromQueue(trackIDs: [loaded.track.id]) }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                .onMove { offsets, destination in
                    guard let first = offsets.first, let current = model.playbackCurrentIndex else { return }
                    // Up Next is the queue after the playing track; shift into
                    // queue coordinates the way the inspector does.
                    let base = current + 1
                    model.moveInQueue(from: base + first, to: base + destination)
                }
                // A shuffle deals a fixed hand, so the end of the list is where
                // you ask for more of the same crate rather than a dead stop.
                if model.shuffleDealMoreCount > 0 {
                    dealMoreRow
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Rows are two lines of small type; List's default minimum would
            // pad each one out to a finger-sized cell.
            .environment(\.defaultMinListRowHeight, 1)
        }
    }

    private var dealMoreRow: some View {
        let more = min(model.shuffleDealMoreCount, LibraryViewModel.shuffleDealSize)
        return Button {
            ClickPlayer.shared.play(.key)
            model.dealMoreShuffled()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 10, weight: .semibold))
                Text("ADD \(more) MORE")
                    .font(CarbonFont.mono(8.5, weight: .bold))
                    .tracking(1.6)
            }
            .foregroundStyle(theme.orange)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
        }
        .buttonStyle(.carbonHover)
        .carbonTip("Deal another \(more) shuffled from this source")
    }

    // MARK: Sources

    private var sources: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Says what a tap does before you make it: every row here
                // shuffles, and it deals a hand rather than the whole box.
                Text("TAP TO SHUFFLE \(LibraryViewModel.shuffleDealSize) INTO UP NEXT")
                    .font(CarbonFont.mono(7.5, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(theme.ink4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                sectionHeader("LIBRARY")
                sourceRow(icon: "square.grid.2x2", title: "All Records",
                          trailing: "shuffle", playing: isPlaying(.localAll)) {
                    model.shuffleAllRecords()
                    tab = .upNext
                }
                if !model.availableCrates.isEmpty {
                    sectionHeader("CRATES")
                    ForEach(model.availableCrates, id: \.self) { crate in
                        sourceRow(icon: "shippingbox.fill", title: crate,
                                  trailing: "\(model.crateTrackCounts[crate] ?? 0)",
                                  playing: isPlaying(.localCrate(name: crate))) {
                            model.shuffleCrate(named: crate)
                            tab = .upNext
                        }
                    }
                }
                if !model.playlists.isEmpty {
                    sectionHeader("PLAYLISTS")
                    ForEach(model.playlists) { playlist in
                        sourceRow(icon: "music.note.list", title: playlist.name,
                                  trailing: "\(playlist.trackURLs.count)",
                                  playing: isPlaying(.playlist(name: playlist.name))) {
                            model.shufflePlaylist(named: playlist.name)
                            tab = .upNext
                        }
                    }
                }
                ForEach(model.streamCategories, id: \.self) { category in
                    sectionHeader(category.title.uppercased())
                    ForEach(model.streams.filter { category.contains($0) }) { stream in
                        sourceRow(icon: category.iconName, title: stream.title,
                                  trailing: stream.isLive ? "LIVE" : "",
                                  playing: model.isStreamActive && model.selectedStreamID == stream.id) {
                            model.playStream(id: stream.id)
                        }
                    }
                }
                if model.availableCrates.isEmpty && model.playlists.isEmpty && model.streams.isEmpty {
                    notice("Nothing to play yet.\nDig a crate in the full app.")
                }
            }
            .padding(.bottom, 6)
        }
    }

    private func isPlaying(_ source: LibrarySource) -> Bool {
        model.nowPlayingTrack != nil && !model.isStreamActive && model.playingSource == source
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(CarbonFont.mono(7.5, weight: .bold))
            .tracking(1.8)
            .foregroundStyle(theme.ink4)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func sourceRow(icon: String, title: String, trailing: String, playing: Bool,
                           action: @escaping () -> Void) -> some View {
        MiniSourceRow(icon: icon, title: title, trailing: trailing, playing: playing) {
            ClickPlayer.shared.play(.key)
            action()
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(CarbonFont.mono(9))
            .foregroundStyle(theme.ink4)
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
    }
}

/// One crate, playlist or stream. The whole row is the target; the trailing
/// text is a count, LIVE, or the shuffle glyph for All Records.
private struct MiniSourceRow: View {
    @Environment(\.carbon) private var theme
    @Environment(\.carbonGeometry) private var geometry
    let icon: String
    let title: String
    let trailing: String
    let playing: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(playing ? theme.orange : theme.ink3)
                    .frame(width: 14)
                Text(title)
                    .font(CarbonFont.sans(12, weight: playing ? .semibold : .regular))
                    .foregroundStyle(playing ? theme.ink : theme.ink2)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if trailing == "shuffle" {
                    Image(systemName: "shuffle")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(hovering ? theme.orange : theme.ink4)
                } else if !trailing.isEmpty {
                    Text(trailing)
                        .font(CarbonFont.mono(8.5, weight: .semibold))
                        .foregroundStyle(trailing == "LIVE" ? theme.onAir : theme.ink4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: geometry.scaled(6, following: \.keyCornerRadius), style: .continuous)
                    .fill(playing ? theme.orange.opacity(0.10) : (hovering ? theme.ink.opacity(0.05) : Color.clear))
                    .padding(.horizontal, 5)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// One queued track: number, title, artist, and on hover a remove key. Click
/// to jump to it; drag to reorder.
private struct MiniQueueRow: View {
    @Environment(\.carbon) private var theme
    let loaded: LoadedTrack
    let position: Int
    let onPlay: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(String(format: "%02d", position))
                .font(CarbonFont.mono(8.5))
                .foregroundStyle(theme.ink4)
                .frame(width: 18, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(loaded.track.title)
                    .font(CarbonFont.sans(12, weight: .medium))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Text(loaded.track.artist.uppercased())
                    .font(CarbonFont.mono(8))
                    .foregroundStyle(theme.ink4)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(theme.ink2)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .carbonTip("Remove from queue")
            } else if loaded.track.durationSeconds > 0 {
                Text(QueueInspectorView.durationLabel(loaded.track.durationSeconds))
                    .font(CarbonFont.mono(8.5))
                    .foregroundStyle(theme.ink4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(hovering ? theme.ink.opacity(0.05) : Color.clear)
        .onHover { hovering = $0 }
        .onTapGesture(perform: onPlay)
    }
}

// MARK: - Clock-driven leaves

/// The elapsed/total readout. Split out of `MiniPlayerBody` so a clock tick
/// repaints ~40pt of text instead of the entire player panel.
private struct MiniPlayerTimeReadout: View {
    @ObservedObject var model: LibraryViewModel
    @ObservedObject var clock: PlaybackClock
    @Environment(\.carbon) private var theme

    var body: some View {
        Text(model.isStreamActive
             ? timeString(model.displayedCurrentTime)
             : "\(timeString(model.displayedCurrentTime)) / \(timeString(model.playbackDuration))")
            .font(CarbonFont.mono(8.5, weight: .semibold))
            .foregroundStyle(theme.orange)
            .fixedSize()
    }

    private func timeString(_ seconds: Double) -> String {
        let t = Int(max(0, seconds))
        return t >= 3600
            ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
            : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// The progress/scrub rail. Also split out: its lit mask and thumb offset are
/// the only other things that need to move on every clock tick.
private struct MiniPlayerSeekRail: View {
    @ObservedObject var model: LibraryViewModel
    @ObservedObject var clock: PlaybackClock
    let theme: CarbonTheme

    var body: some View {
        GeometryReader { proxy in
            let w = max(proxy.size.width, 1)
            let p = model.playbackDuration > 0
                ? min(max(model.displayedCurrentTime / model.playbackDuration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.42)).frame(height: 5)
                    .overlay(Capsule().stroke(Color.white.opacity(0.07), lineWidth: 0.6))
                // Full-width cyan→orange ramp revealed by the lit mask — the
                // gradient's endpoints stay fixed (like the OLED/footer bars)
                // instead of stretching with playback progress.
                Capsule()
                    .fill(LinearGradient(colors: [theme.cyan, theme.orange], startPoint: .leading, endPoint: .trailing))
                    .frame(height: 5)
                    .mask(
                        Capsule()
                            .frame(width: max(5, w * p))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    )
                    .shadow(color: theme.cyan.opacity(0.4), radius: 4)
                Circle()
                    .fill(RadialGradient(colors: [.white, Color(white: 0.82)],
                                         center: .init(x: 0.4, y: 0.3), startRadius: 0, endRadius: 6))
                    .frame(width: 11, height: 11)
                    .depthShadow(color: .black.opacity(0.6), radius: 2)
                    .offset(x: min(max(w * p - 5.5, 0), w - 11))
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .background(WindowDragGuard())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in model.scrubbingFraction = min(max(g.location.x / w, 0), 1) }
                    .onEnded { g in
                        ClickPlayer.shared.play(.tick)
                        model.commitScrubSeek(toFraction: min(max(g.location.x / w, 0), 1))
                    }
            )
        }
        .frame(height: 11)
    }
}
