import AppKit
import CrateDiggerCore
import NowPlayingFeed
import WidgetKit

/// The Now Playing widget's feed: what is playing, the pictures that go with
/// it, and the modes picked in Settings ▸ Interface. What the widget shows for
/// a feed is `NowPlayingFeed`, which booklet pages make a slideshow is
/// `WidgetSlide`, which crate a record is credited to is `WidgetCaption`; this
/// file is the wiring.
///
/// Pictures come at two speeds. The playing cover is encoded on the spot from
/// the thumbnail the system now-playing info already uses. Library covers and
/// booklet pages are rendered off the main thread, and the feed is published
/// again once they land; until then the store leaves them out.
struct WidgetFeedState {
    /// Random library covers for the idle slideshow, with the words that go
    /// beside them, picked once per launch.
    var idlePool: [(slide: WidgetSlide, cover: NowPlayingFeed.Cover)] = []
    /// The playing album's slides, and the folder and cover they were read for.
    var albumSlides: [WidgetSlide] = []
    var albumSlidesKey: String?
    /// The last album that played, carried into the idle feed.
    var lastCover: NowPlayingFeed.Cover?
    /// Whether the last feed published was a record playing, so the first
    /// feed after it can stamp when the music stopped.
    var wasPlaying = false
    /// Pictures already handed to a background render, so a publish never
    /// starts the same work twice. One that failed stays here and is not
    /// retried until the next launch.
    var rendering: Set<String> = []
}

@MainActor
extension LibraryViewModel {
    private static let widgetIdlePoolSize = 30
    /// Twice the largest spot a picture fills (the small widget, 164 pt), with
    /// room to spare for a booklet page's text.
    private static let widgetPictureMaxPixel = 600

    /// Where the widget reads from, or nil when this build carries no widget
    /// (a `swift build` run, an ad-hoc package): with nothing to read the feed,
    /// there is no reason to reach into the app-group container at all.
    static let widgetFeedStore: NowPlayingFeedStore? = {
        guard let plugIns = Bundle.main.builtInPlugInsURL,
              FileManager.default.fileExists(atPath: plugIns.appendingPathComponent("CrateDiggerWidget.appex").path),
              let container = NowPlayingFeed.containerURL()
        else { return nil }
        return NowPlayingFeedStore(directory: container)
    }()

    /// At launch, once All Records is loaded: pick the idle covers from it,
    /// carry the last album over from the feed on disk, and follow Settings.
    func startWidgetFeed() {
        guard let store = Self.widgetFeedStore else { return }
        widgetFeedState.lastCover = store.read().lastCover
        widgetFeedState.idlePool = pickIdleCovers()
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("CrateDiggerWidgetModesChanged"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.publishWidgetFeed() }
        }
        publishWidgetFeed()
    }

    /// Random albums with art from All Records, each captioned with its album,
    /// artist, year and the most specific crate holding it. The crates are
    /// already resolved and cached by the All Records load this follows.
    private func pickIdleCovers() -> [(slide: WidgetSlide, cover: NowPlayingFeed.Cover)] {
        let albums = localIndex.artists
            .flatMap(\.albums)
            .filter { $0.artworkHash != nil }
            .shuffled()
            .prefix(Self.widgetIdlePoolSize)
        guard !albums.isEmpty else { return [] }

        let crates = availableCrates.map { name in
            (name: name, paths: Set(loadCrateTracks(name: name).map { $0.track.fileURL.standardizedFileURL.path }))
        }
        return albums.compactMap { album in
            guard let hash = album.artworkHash else { return nil }
            let slide = WidgetSlide.artwork(hash: hash)
            let crate = album.tracks.first.flatMap {
                WidgetCaption.crate(containing: $0.track.fileURL.standardizedFileURL.path, in: crates)
            }
            let cover = NowPlayingFeed.Cover(file: slide.fileName, album: album.title, artist: album.artistName,
                                             year: album.originalYear ?? album.year, crate: crate)
            return (slide, cover)
        }
    }

    /// Hand the widget what is playing. Called wherever the system's
    /// now-playing info is pushed, after the elapsed anchor moves, when a
    /// stream changes state, and when a background render lands. The playhead
    /// is the anchor rather than the clock, so a track that just plays on
    /// writes nothing: the widget extrapolates from (playhead, playheadAt)
    /// itself. The store drops identical feeds, and only a real change reloads
    /// the widget.
    func publishWidgetFeed() {
        // A load in progress is on its way to playing or paused; publishing it
        // would flash a paused widget between every track.
        guard playbackState != .loading else { return }
        writeWidgetFeed(makeWidgetFeed(nowPlayingWidgetFeed()))
    }

    /// At quit, so the widget does not go on showing a track nobody is playing.
    /// Every picture the idle feed names is already on disk, so this only
    /// writes the JSON.
    func clearWidgetFeed() {
        writeWidgetFeed(makeWidgetFeed(.idle))
    }

    /// The track, or stream, as the widget should draw it.
    private func nowPlayingWidgetFeed() -> NowPlayingFeed {
        let state: NowPlayingFeed.State = playbackState == .playing ? .playing : .paused
        if isStreamActive, let stream = selectedStream {
            return NowPlayingFeed(state: state, title: stream.title, artist: stream.channel, isLive: true)
        }
        guard let track = nowPlayingTrack, playbackState != .idle, let anchor = nowPlayingElapsedAnchor else {
            return .idle
        }
        // The tag duration, not the player's: that one arrives a moment after
        // the track does, and the tick that brings it does not publish.
        let duration = track.track.durationSeconds > 0 ? track.track.durationSeconds : playbackDuration
        return NowPlayingFeed(
            state: state,
            title: track.track.title,
            artist: track.track.artist,
            album: track.track.album,
            duration: duration,
            playhead: anchor.elapsed,
            playheadAt: anchor.wall,
            artworkFile: track.track.artworkHash.map { WidgetSlide.artwork(hash: $0).fileName }
        )
    }

    /// Dress a feed in the Settings modes and the pictures they call for. Only
    /// what the chosen modes show is named, so the library covers and booklet
    /// pages are never rendered for a widget that will not draw them.
    private func makeWidgetFeed(_ base: NowPlayingFeed) -> NowPlayingFeed {
        var feed = base
        feed.idleMode = prefs.widgetIdleMode
        feed.playingMode = prefs.widgetPlayingMode

        let isPlayingRecord = feed.state == .playing && !feed.isLive
        if let file = feed.artworkFile, widgetFeedState.lastCover?.file != file {
            widgetFeedState.lastCover = NowPlayingFeed.Cover(file: file, album: feed.album, artist: feed.artist)
        }
        // "Last played" counts from when the music stopped: stamped on every
        // publish while a record plays, and once more on the first after.
        if isPlayingRecord || widgetFeedState.wasPlaying {
            widgetFeedState.lastCover?.playedAt = Date()
        }
        widgetFeedState.wasPlaying = isPlayingRecord
        feed.lastCover = widgetFeedState.lastCover

        if feed.idleMode == .librarySlideshow {
            feed.idleSlides = widgetFeedState.idlePool.map(\.cover)
        }
        if feed.playingMode == .coverAndBooklet, feed.state != .idle, !feed.isLive, let track = nowPlayingTrack {
            refreshAlbumSlides(for: track)
            feed.slides = widgetFeedState.albumSlides.map(\.fileName)
        }
        return feed
    }

    private func writeWidgetFeed(_ feed: NowPlayingFeed) {
        guard let store = Self.widgetFeedStore else { return }
        let coverHash = feed.state == .idle ? nil : nowPlayingTrack?.track.artworkHash
        do {
            let changed = try store.write(feed) { [artworkService] name in
                // Only the playing cover is made here, from the 480 px
                // thumbnail the system now-playing info uses, so it is usually
                // already cached. Everything else renders in the background.
                guard let coverHash, name == WidgetSlide.artwork(hash: coverHash).fileName,
                      let image = artworkService.generateThumbnail(artworkHash: coverHash, size: CGSize(width: 480, height: 480)),
                      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                else { return nil }
                return NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
            }
            if changed {
                WidgetCenter.shared.reloadTimelines(ofKind: NowPlayingFeed.widgetKind)
            }
        } catch {
            AppLog.ui.error("Now Playing widget feed not written: \(error.localizedDescription, privacy: .public)")
        }
        renderMissingWidgetPictures(named: feed, in: store)
    }

    /// Render, off the main thread, the library covers and booklet pages the
    /// feed names but the container does not hold yet, then publish again so
    /// they join it.
    private func renderMissingWidgetPictures(named feed: NowPlayingFeed, in store: NowPlayingFeedStore) {
        let named = Set(feed.pictureNames)
        var queued = Set<String>()
        let slides = (widgetFeedState.idlePool.map(\.slide) + widgetFeedState.albumSlides).filter { slide in
            let name = slide.fileName
            return named.contains(name)
                && !widgetFeedState.rendering.contains(name)
                && !store.hasPicture(named: name)
                && queued.insert(name).inserted
        }
        guard !slides.isEmpty else { return }
        widgetFeedState.rendering.formUnion(queued)

        let maxPixel = Self.widgetPictureMaxPixel
        Task.detached(priority: .utility) { [weak self] in
            let artwork = ArtworkStore(directory: ArtworkStore.defaultDirectory)
            for slide in slides {
                guard let data = slide.renderJPEG(maxPixel: maxPixel, artworkData: { artwork.data(for: $0) }) else { continue }
                do {
                    try store.writePicture(data, named: slide.fileName)
                } catch {
                    AppLog.ui.error("Now Playing widget picture not written: \(error.localizedDescription, privacy: .public)")
                }
            }
            await self?.publishWidgetFeed()
        }
    }

    /// The playing album's slides: its cover straight away, then the booklet
    /// pages once the folder has been read off the main thread. Read once per
    /// album folder and cover, not once per track.
    private func refreshAlbumSlides(for track: LoadedTrack) {
        let cover = track.track.artworkHash
        let coverOnly = WidgetSlide.albumSlides(coverHash: cover, booklet: nil, pdfPageCount: { _ in 0 })
        let file = track.track.fileURL
        guard file.isFileURL else {
            widgetFeedState.albumSlidesKey = nil
            widgetFeedState.albumSlides = coverOnly
            return
        }
        let folder = file.deletingLastPathComponent()
        let key = folder.path + "|" + (cover ?? "")
        guard widgetFeedState.albumSlidesKey != key else { return }
        widgetFeedState.albumSlidesKey = key
        widgetFeedState.albumSlides = coverOnly

        Task.detached(priority: .utility) { [weak self] in
            // The same scan LibraryIndex runs for the album's booklet button.
            let booklet = AlbumBooklet.scan(in: folder, manifest: ArtworkManifest.load(from: folder))
            let slides = WidgetSlide.albumSlides(coverHash: cover, booklet: booklet, pdfPageCount: WidgetSlide.pdfPageCount)
            await self?.applyAlbumSlides(slides, key: key)
        }
    }

    private func applyAlbumSlides(_ slides: [WidgetSlide], key: String) {
        guard widgetFeedState.albumSlidesKey == key, slides != widgetFeedState.albumSlides else { return }
        widgetFeedState.albumSlides = slides
        publishWidgetFeed()
    }
}

extension PreferencesStore {
    /// Settings ▸ Interface ▸ When nothing is playing.
    var widgetIdleMode: NowPlayingFeed.IdleMode {
        get { widgetIdleModeRaw.flatMap(NowPlayingFeed.IdleMode.init(rawValue:)) ?? .librarySlideshow }
        set { widgetIdleModeRaw = newValue.rawValue }
    }

    /// Settings ▸ Interface ▸ While playing.
    var widgetPlayingMode: NowPlayingFeed.PlayingMode {
        get { widgetPlayingModeRaw.flatMap(NowPlayingFeed.PlayingMode.init(rawValue:)) ?? .albumCover }
        set { widgetPlayingModeRaw = newValue.rawValue }
    }
}
