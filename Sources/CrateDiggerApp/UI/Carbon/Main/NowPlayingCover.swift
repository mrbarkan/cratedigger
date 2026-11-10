import AppKit
import CrateDiggerCore
import SwiftUI

/// The picture of whatever is playing: a stream's thumbnail, else the album's
/// cover — the cover file on disk, then cached bytes by hash, then the audio
/// file's own art (same order as AlbumPoster). Shared by the Mini Player and
/// the compact player so the two can never disagree about which picture is on.
///
/// With a `screen` spec (the theme has a cover screen look) it draws the LCD
/// picture instead: the same cover run through `CoverScreenImage`, at its
/// natural size, for a `CoverScreenBezel` to house. Without one it is exactly
/// the view it always was.
struct NowPlayingCover<Placeholder: View>: View {
    @ObservedObject var model: LibraryViewModel
    var maxPixel: Int = 480
    var screen: CoverScreenSpec? = nil
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var coverImage: NSImage?
    /// The screen's current picture; only used with a `screen` spec.
    @State private var lcdPicture: LCDPicture?

    /// One rendered LCD picture and what it was rendered for, so a picture
    /// made for another layout (a scale change mid-flight) is never drawn at
    /// the wrong size, and so a crossfade has an identity to fade between.
    private struct LCDPicture {
        let key: String
        let image: CGImage
        let layout: CoverScreenLayout
        let scale: CGFloat
    }

    /// The `.task(id:)` key with a screen: what is playing, plus everything
    /// the picture is rendered from, so a theme edit or a scale change
    /// re-renders once.
    private struct ScreenTaskKey: Equatable {
        let cover: String
        let spec: CoverScreenSpec
    }

    var body: some View {
        if let screen {
            screenBody(screen)
        } else {
            // The picture fills whatever space it is offered and never asks for
            // more. A cover that is not square (a 1.12:1 scan, a 16:9 stream
            // thumbnail) drawn `.fill` reports a size wider than the square, and a
            // flexible frame around it, like the compact player's art well, grows
            // to match: the well spilled past its column into the display.
            Color.clear
                .overlay { picture }
                .clipped()
                .task(id: coverKey) { await loadCoverImage() }
        }
    }

    @ViewBuilder
    private var picture: some View {
        Group {
            if model.isStreamActive, let stream = model.selectedStream {
                StreamThumbnail(stream: stream)
            } else {
                // A ZStack, so the outgoing picture is still there to dissolve
                // into the incoming one: each image is its own identity, and a
                // track change crossfades the sleeves instead of cutting. The
                // cover loads after the title has already changed, and the cut
                // made the art look late; a dissolve reads as the art arriving.
                ZStack {
                    if let image = coverImage {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                            .id(ObjectIdentifier(image))
                            .transition(.opacity)
                    } else {
                        placeholder()
                            .transition(.opacity)
                    }
                }
            }
        }
    }

    /// Opacity only, so Reduce Motion keeps it.
    private func show(_ image: NSImage?) {
        withAnimation(CarbonMotion.state) { coverImage = image }
    }

    /// Reload key: track change or a freshly committed cover (hash change),
    /// or for a stream its id and thumbnail URL (see `NowPlayingCoverKey`).
    private var coverKey: String {
        #if DEBUG
        if Self.debugCoverURL != nil { return "debug-cover" }
        #endif
        if model.isStreamActive {
            let stream = model.selectedStream
            return NowPlayingCoverKey.stream(id: model.selectedStreamID, thumbnailURL: stream?.thumbnailURL)
        }
        let track = model.nowPlayingTrack?.track
        return NowPlayingCoverKey.track(id: track?.id, artworkHash: track?.artworkHash)
    }

    private func loadCoverImage() async {
        #if DEBUG
        if let url = Self.debugCoverURL {
            show(await loadThumbnail(url: url, maxPixelSize: maxPixel))
            return
        }
        #endif
        show(await loadCover(maxPixel: maxPixel))
    }

    /// The playing track's cover, in the order the header comment gives.
    private func loadCover(maxPixel: Int) async -> NSImage? {
        guard let loaded = model.nowPlayingTrack else { return nil }
        if let album = model.album(containing: loaded.track.id),
           let coverURL = album.booklet?.frontCoverURL,
           let image = await loadThumbnail(url: coverURL, maxPixelSize: maxPixel) {
            return image
        }
        if let hash = loaded.track.artworkHash,
           let image = await model.artworkService.thumbnailAsync(artworkHash: hash, maxPixel: maxPixel) {
            return image
        }
        if loaded.track.fileURL.isFileURL,
           let asset = await model.artworkService.resolveArtwork(trackURL: loaded.track.fileURL) {
            return await model.artworkService.thumbnailAsync(artworkHash: asset.hash, maxPixel: maxPixel)
        }
        return nil
    }

    // MARK: - The cover screen

    private func screenBody(_ spec: CoverScreenSpec) -> some View {
        ZStack(alignment: .topLeading) {
            if let lcd = lcdPicture, lcd.layout == spec.layout, lcd.scale == spec.scale {
                // Natural size, never `.resizable()`: `lcdSide` image pixels
                // are `lcdSide / scale` points, one per device pixel. The
                // interpolation setting is only a backstop.
                Image(decorative: lcd.image, scale: spec.scale)
                    .interpolation(.none)
                    .id(lcd.key)
                    .transition(.opacity)
            } else {
                // Until the first picture lands (a few milliseconds, once per
                // track): the panel's own colour, without its grid.
                spec.unlitColor
                    .transition(.opacity)
            }
        }
        .frame(width: spec.lcdPoints, height: spec.lcdPoints, alignment: .topLeading)
        .task(id: ScreenTaskKey(cover: coverKey, spec: spec)) { await loadScreen(spec) }
    }

    private func showScreen(_ image: CGImage, key: String, spec: CoverScreenSpec) {
        if let current = lcdPicture, current.key == key, current.layout == spec.layout,
           current.scale == spec.scale { return }
        withAnimation(CarbonMotion.state) {
            lcdPicture = LCDPicture(key: key, image: image, layout: spec.layout, scale: spec.scale)
        }
    }

    /// Finds or renders the screen's picture. The cache is checked before the
    /// cover is even loaded, so a fold back and forth, or the other player
    /// showing the same track, costs nothing. Rendering runs off the main
    /// thread; the previous picture stays up until the new one lands, except
    /// when a stream takes over (below).
    private func loadScreen(_ spec: CoverScreenSpec) async {
        let cover = coverKey
        let key = "\(cover)|\(frontCoverStamp())|\(spec.renderKey)"
        if let cached = CoverScreenCache.image(forKey: key) {
            showScreen(cached, key: key, spec: spec)
            return
        }
        // A stream's thumbnail comes over the network and can take seconds,
        // and the picture still up is the last track's cover, which reads as
        // that album playing. Go dark first, unless the picture up is already
        // this stream's (a theme edit or a scale change re-rendering it).
        if isStreamScreen, lcdPicture?.key.hasPrefix(cover + "|") != true {
            await showUnlit(spec)
            guard !Task.isCancelled else { return }
        }
        if let source = await screenSource(maxPixel: max(600, spec.layout.lcdSide)) {
            guard !Task.isCancelled else { return }
            let rendered = await Self.renderOffMain { CoverScreenImage.render(source, spec: spec) }
            guard !Task.isCancelled else { return }
            if let rendered {
                CoverScreenCache.store(rendered, forKey: key)
                showScreen(rendered, key: key, spec: spec)
                return
            }
        }
        guard !Task.isCancelled else { return }
        await showUnlit(spec)
    }

    /// Anything that is not a real picture (nothing playing, a track with no
    /// art, a stream whose thumbnail is missing, unreachable or still on its
    /// way) is the unlit panel. Cached under its own key, not the cover's, so
    /// a stream whose thumbnail failed once is fetched again next time.
    private func showUnlit(_ spec: CoverScreenSpec) async {
        let unlitKey = "unlit|\(spec.renderKey)|\(spec.unlit.r),\(spec.unlit.g),\(spec.unlit.b)"
        if let cached = CoverScreenCache.image(forKey: unlitKey) {
            showScreen(cached, key: unlitKey, spec: spec)
            return
        }
        let unlit = await Self.renderOffMain { CoverScreenImage.renderUnlit(spec: spec) }
        guard !Task.isCancelled, let unlit else { return }
        CoverScreenCache.store(unlit, forKey: unlitKey)
        showScreen(unlit, key: unlitKey, spec: spec)
    }

    /// Whether the screen shows a stream's thumbnail rather than a cover.
    private var isStreamScreen: Bool {
        #if DEBUG
        if Self.debugCoverURL != nil { return false }
        #endif
        return model.isStreamActive
    }

    /// Runs a render off the main thread, cancelled with the task awaiting
    /// it: a slider drag in the theme editor cancels each step's task as the
    /// next begins, and without this every intermediate picture was still
    /// drawn to the end. A cancelled render returns nil, and the callers
    /// check `Task.isCancelled` before storing or showing anything, so a
    /// stale picture is never used.
    private static func renderOffMain(_ work: @escaping @Sendable () -> CGImage?) async -> CGImage? {
        let task = Task.detached(priority: .userInitiated, operation: work)
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// The booklet front cover's identity on disk, for the screen's cache
    /// key. Saving artwork can replace that file without changing the track's
    /// `artworkHash` (the hash is the track's own art, and a SAVE leaves it
    /// alone), so the key alone would keep serving the cached picture of the
    /// old file. The plain cover re-reads the file whenever it appears; with
    /// this the screen does too. Empty when there is no booklet cover.
    private func frontCoverStamp() -> String {
        guard !isStreamScreen, let loaded = model.nowPlayingTrack,
              let url = model.album(containing: loaded.track.id)?.booklet?.frontCoverURL else { return "" }
        // FileManager rather than `URL.resourceValues`, which caches on the
        // URL object, and this URL lives in the album for as long as it does.
        let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let file = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        return "\(url.path)@\(modified)#\(file)"
    }

    /// The picture behind the screen: a stream's thumbnail, else the cover.
    private func screenSource(maxPixel: Int) async -> CGImage? {
        #if DEBUG
        if let url = Self.debugCoverURL {
            return await loadThumbnail(url: url, maxPixelSize: maxPixel)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        #endif
        if model.isStreamActive {
            // `StreamThumbnail` is an `AsyncImage`, which never hands over its
            // image, so the screen fetches the thumbnail itself. The shared
            // URL cache usually has it already from the radio list.
            guard let stream = model.selectedStream,
                  let string = stream.thumbnailURL, let url = URL(string: string) else { return nil }
            return await Self.fetchThumbnail(url: url, maxPixel: maxPixel)
        }
        return await loadCover(maxPixel: maxPixel)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// How long a stream thumbnail may take. URLSession's default is 60 s, and
    /// the screen is unlit for as long as the fetch runs.
    private static var thumbnailTimeout: TimeInterval { 10 }

    private static func fetchThumbnail(url: URL, maxPixel: Int) async -> CGImage? {
        do {
            let request = URLRequest(url: url, timeoutInterval: thumbnailTimeout)
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                NSLog("[CoverScreen] stream thumbnail %@ answered %d", url.absoluteString, http.statusCode)
                return nil
            }
            return await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel
                ]
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            }.value
        } catch {
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                NSLog("[CoverScreen] stream thumbnail %@ failed: %@", url.absoluteString, error.localizedDescription)
            }
            return nil
        }
    }

    #if DEBUG
    /// `CRATEDIGGER_COVER=<image path>`: that picture in the well in place of
    /// the playing track's art, shown even with nothing playing, so the cover
    /// (and its screen) can be captured without making a sound. See the
    /// hook list in `AppDelegate`.
    static var debugCoverURL: URL? { NowPlayingCoverKey.debugCoverURL }
    #endif
}

/// What `NowPlayingCover` reloads on. Outside the view (which is generic, so
/// it can hold no static storage) and pure, so the keys can be tested.
enum NowPlayingCoverKey {
    /// A stream: its id and its thumbnail URL. A pasted link starts playing
    /// before its metadata names a thumbnail, so without the URL the key never
    /// changed when it arrived and the screen stayed unlit for the whole play;
    /// and a thumbnail that changed later kept the old cached picture.
    static func stream(id: String?, thumbnailURL: String?) -> String {
        "stream-\(id ?? "none")|\(thumbnailURL ?? "")"
    }

    /// A track: its id and its artwork hash, so a freshly committed cover
    /// (a hash change) reloads.
    static func track(id: UUID?, artworkHash: String?) -> String {
        "\(id?.uuidString ?? "none")-\(artworkHash ?? "")"
    }

    #if DEBUG
    /// Read once: the key is computed on every body pass, and the process
    /// environment does not change while the app runs.
    static let debugCoverURL: URL? = {
        guard let path = ProcessInfo.processInfo.environment["CRATEDIGGER_COVER"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }()
    #endif
}
