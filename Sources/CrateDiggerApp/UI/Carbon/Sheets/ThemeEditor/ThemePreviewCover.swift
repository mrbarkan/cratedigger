import AppKit
import CrateDiggerCore
import ImageIO
import SwiftUI

// The album art in the theme preview: the bundled starter album's cover,
// drawn the way the draft would draw it. In the mini and compact players that
// is the cover screen when the draft turns a look on, through the same Core
// renderer and the same housing the real players use (`CoverScreenSpec`,
// `CoverScreenImage`, `CoverScreenBezel`), at the size the preview shows it and
// at the display's real backing scale, so the LCD is pixel-true. The full
// window's inspector never takes a look (nor does the real one); it gets the
// plain cover.

// MARK: - The pictures

/// The sample cover and every picture made from it, rendered off the main
/// thread and kept by what they depend on. Separate from `CoverScreenCache`
/// so dragging through themes in the editor never evicts the players' own
/// pictures.
enum ThemePreviewCoverStore {
    /// What one picture depends on: the look and its strength, the pixel size,
    /// and the side and scale the layout is planned for. nil `look` is the
    /// plain cover, which depends on nothing (it is resampled by SwiftUI).
    struct Request: Equatable, Sendable {
        let look: CoverScreenLook?
        let strength: Double
        let pixelSize: Double
        let side: CGFloat
        let scale: CGFloat

        /// The request for a theme at `side` points and `scale`: the theme's
        /// own resolved look, never one read from raw effects, so the preview
        /// can never show a look or a strength the app would not draw.
        init(theme: CarbonTheme, side: CGFloat, scale: CGFloat) {
            look = theme.coverScreenLook
            strength = theme.coverScreenStrength
            pixelSize = theme.coverPixelSize
            self.side = side
            self.scale = scale
        }

        var key: String {
            guard let look else { return "plain" }
            return "\(look.rawValue)|\(strength)|\(pixelSize)|\(side)|\(scale)"
        }
    }

    private final class Entry {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    /// Thread-safe (NSCache), so the detached renders can store into it.
    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 24
        return cache
    }()

    private static let sourceKey = "source" as NSString

    /// The longest side the cover is decoded at. The largest picture made
    /// from it is the mini player's LCD at 3x (about 540 pixels), so this is
    /// never upscaled, and a 1400 pixel PNG is not decoded whole.
    private static let sourceMaxPixel = 720

    /// The decoded sample cover, if it has been loaded. Never decodes: safe to
    /// call from a view body.
    static var loadedSource: CGImage? {
        cache.object(forKey: sourceKey)?.image
    }

    /// The decoded sample cover, decoding it on first use. Blocking: call it
    /// off the main thread (or from a test).
    static func source() -> CGImage? {
        if let loaded = loadedSource { return loaded }
        guard let url = sampleCoverURL(),
              let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil)
        else {
            AppLog.ui.error("Theme preview: the sample cover (StarterCrate/cover.png) is not in any resource bundle")
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: sourceMaxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            AppLog.ui.error("Theme preview: the sample cover could not be decoded")
            return nil
        }
        cache.setObject(Entry(image), forKey: sourceKey)
        return image
    }

    /// Where tests find the cover: an XCTest runner's main bundle is not the
    /// app's, so the resource bundles are not beside it. Set it before the
    /// first `source()`; the decoded cover is kept once loaded.
    nonisolated(unsafe) static var sampleCoverOverride: URL?

    /// The starter album's cover, from whichever resource bundle holds it
    /// (not `Bundle.module`, which traps in a packaged app; see
    /// `Bundle.crateDiggerResources`).
    private static func sampleCoverURL() -> URL? {
        if let sampleCoverOverride { return sampleCoverOverride }
        for bundle in Bundle.crateDiggerSearchBundles {
            if let url = bundle.url(forResource: "cover", withExtension: "png", subdirectory: "StarterCrate") {
                return url
            }
        }
        return nil
    }

    /// The picture for `request` if it has been made. Never renders: safe to
    /// call from a view body.
    static func cachedPicture(for request: Request) -> CGImage? {
        guard request.look != nil else { return loadedSource }
        return cache.object(forKey: request.key as NSString)?.image
    }

    /// The picture for `request`, decoding and rendering as needed. Blocking:
    /// call it off the main thread (`ThemePreviewCover` does) or from a test.
    /// nil when the cover is missing, the side is too small to hold a screen,
    /// or the calling task was cancelled.
    static func picture(for request: Request, spec: CoverScreenSpec?) -> CGImage? {
        if let cached = cachedPicture(for: request) { return cached }
        guard let cover = source() else { return nil }
        guard let spec else { return cover }
        guard let rendered = CoverScreenImage.render(cover, spec: spec) else { return nil }
        cache.setObject(Entry(rendered), forKey: request.key as NSString)
        return rendered
    }
}

// MARK: - The view

/// The sample cover at `side` points: a cover screen in its bezel when the
/// theme has a look and `allowsScreen`, else the plain cover in a sleeve.
///
/// The bezel is tagged as the glass job (its band is `oledStrokeInner`); the
/// picture itself is art, which no job paints, so it dims whenever any job is
/// highlighted.
struct ThemePreviewCover: View {
    @Environment(\.carbon) private var theme
    @Environment(\.displayScale) private var displayScale

    let side: CGFloat
    let cornerRadius: CGFloat
    /// The mini and compact players have a cover screen; the inspector never.
    var allowsScreen: Bool = true

    /// The last picture this view loaded, kept so it stays up while the next
    /// one renders. Body falls back to the store's cache first, so a picture
    /// made before (or prepared by a test) shows on the first frame.
    @State private var loaded: (key: String, image: CGImage)?

    var body: some View {
        let request = ThemePreviewCoverStore.Request(theme: theme, side: side, scale: displayScale)
        let spec = allowsScreen ? CoverScreenSpec(theme: theme, side: side, scale: displayScale) : nil
        Group {
            if let spec {
                CoverScreenBezel(spec: spec, cornerRadius: cornerRadius) {
                    lcd(spec: spec, request: request)
                }
                .previewJob(.glass)
            } else {
                sleeve
            }
        }
        .frame(width: side, height: side)
        .task(id: TaskKey(request: request, screen: spec != nil)) {
            await load(request, spec: spec)
        }
    }

    private struct TaskKey: Equatable {
        let request: ThemePreviewCoverStore.Request
        let screen: Bool
    }

    private func current(_ request: ThemePreviewCoverStore.Request, screen: Bool) -> CGImage? {
        let key = screen ? request.key : "plain"
        if let loaded, loaded.key == key { return loaded.image }
        return screen ? ThemePreviewCoverStore.cachedPicture(for: request) : ThemePreviewCoverStore.loadedSource
    }

    /// The LCD: the rendered picture at its natural size, one image pixel per
    /// device pixel (no `.resizable()`, no drawing group), or the unlit panel
    /// while it renders.
    @ViewBuilder
    private func lcd(spec: CoverScreenSpec, request: ThemePreviewCoverStore.Request) -> some View {
        if let image = current(request, screen: true) {
            Image(decorative: image, scale: spec.scale)
                .interpolation(.none)
                .previewArt()
        } else {
            spec.unlitColor
        }
    }

    /// The plain cover, as the mini player's sleeve and the inspector draw it.
    private var sleeve: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return ZStack {
            shape.fill(theme.wellDeep).previewJob(.panels)
            if let image = current(ThemePreviewCoverStore.Request(theme: theme, side: side, scale: displayScale),
                                   screen: false) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
                    .previewArt()
            }
            shape
                .fill(LinearGradient(colors: [Color.white.opacity(0.16), .clear],
                                     startPoint: .topLeading, endPoint: .center))
                .previewArt()
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.black.opacity(0.6), lineWidth: 0.75).previewArt())
    }

    private func load(_ request: ThemePreviewCoverStore.Request, spec: CoverScreenSpec?) async {
        let key = spec == nil ? "plain" : request.key
        if loaded?.key == key { return }
        let image = await CoverScreenImage.renderOffMain {
            spec == nil
                ? ThemePreviewCoverStore.source()
                : ThemePreviewCoverStore.picture(for: request, spec: spec)
        }
        guard !Task.isCancelled, let image else { return }
        loaded = (key, image)
    }
}
