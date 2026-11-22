#if canImport(XCTest)
import CoreGraphics
import CrateDiggerCore
import SwiftUI
import XCTest
@testable import CrateDiggerApp

/// The cover screen's app half: when a player gets a screen at all, and the
/// picture `CoverScreenImage` makes from a cover. The grid maths is Core's
/// and tested there; what is pinned here is that no look means the old view
/// (nil spec), that the shipped geometry plans the screen the spec promises,
/// and that the picture handed to the view is opaque, the LCD's size, and
/// cropped like the well.
final class CoverScreenTests: XCTestCase {

    private var themes: [String: ThemeDefinition] = [:]

    override func setUpWithError() throws {
        try super.setUpWithError()
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CrateDiggerAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/CrateDiggerApp/Resources/Themes", isDirectory: true)
        let result = ThemeLoaderService(bundles: [], userThemesDirectoryOverride: directory).discoverThemes()
        themes = Dictionary(uniqueKeysWithValues: result.themes.map { ($0.id, $0.definition) })
    }

    private func render(_ id: String, _ appearance: ThemeDefinition.BaseAppearance) throws -> CarbonTheme {
        let definition = try XCTUnwrap(themes[id], "\(id) is not bundled").resolved(for: appearance)
        return CarbonTheme(definition: definition,
                           resolvedBase: definition.baseAppearance == .dark ? .carbon : .linen)
    }

    // MARK: - When there is a screen

    /// No look, no spec: both players then draw exactly what they drew
    /// before the cover screen existed.
    func testThemesWithoutALookGetNoScreen() throws {
        for id in ["carbon", "cobalt", "llama-97"] {
            for appearance in [ThemeDefinition.BaseAppearance.light, .dark] {
                let theme = try render(id, appearance)
                XCTAssertNil(CoverScreenSpec(theme: theme, side: 230, scale: 2), "\(id) \(appearance)")
                XCTAssertNil(CoverScreenSpec(theme: theme, side: 246, scale: 2), "\(id) \(appearance)")
            }
        }
    }

    func testPocketPlansTheCompactAndMiniScreens() throws {
        let theme = try render("pocket", .light)
        let compact = try XCTUnwrap(CoverScreenSpec(theme: theme, side: 230, scale: 2))
        XCTAssertEqual(compact.look, .pixel)
        XCTAssertEqual(compact.strength, 0.55, accuracy: 0.000001)
        XCTAssertEqual(compact.layout, CoverScreenLayout(cell: 3, count: 145, lcdSide: 435, band: 12))
        XCTAssertEqual(compact.lcdPoints, 217.5)
        XCTAssertEqual(compact.bandPoints, 6)
        XCTAssertEqual(compact.sourceSide, 145, "pixel resamples to one pixel per LCD pixel")

        let mini = try XCTUnwrap(CoverScreenSpec(theme: theme, side: 246, scale: 2))
        XCTAssertEqual(mini.layout, CoverScreenLayout(cell: 3, count: 156, lcdSide: 468, band: 12))

        let oneX = try XCTUnwrap(CoverScreenSpec(theme: theme, side: 230, scale: 1))
        XCTAssertEqual(oneX.layout, CoverScreenLayout(cell: 3, count: 72, lcdSide: 216, band: 7))
        XCTAssertNotEqual(oneX, compact, "a scale change is a new spec, so the task re-renders")
    }

    func testTooSmallASideFallsBackToThePlainCover() throws {
        let theme = try render("pocket", .light)
        XCTAssertNil(CoverScreenSpec(theme: theme, side: 20, scale: 1))
    }

    /// Pocket light's glass is pale and is kept; dark's is near-black and is
    /// taken 40% toward black.
    func testUnlitPanelFollowsTheGlass() throws {
        let light = try XCTUnwrap(CoverScreenSpec(theme: try render("pocket", .light), side: 230, scale: 2))
        XCTAssertEqual(light.unlit, .init(r: 0xB7, g: 0xBB, b: 0xB0))
        let dark = try XCTUnwrap(CoverScreenSpec(theme: try render("pocket", .dark), side: 230, scale: 2))
        XCTAssertEqual(dark.unlit, .init(r: 4, g: 3, b: 7), "#06050C at 60%")
    }

    /// The grid look keeps the sharp cover, so it resamples at the LCD's full
    /// device resolution.
    func testGridLookResamplesAtTheLCDsSide() {
        let layout = CoverScreenLayout.plan(side: 230, scale: 2, pixelSize: 1.5)
        let spec = CoverScreenSpec(look: .grid, strength: 0.5, layout: layout, scale: 2,
                                   unlit: .init(r: 0, g: 0, b: 0))
        XCTAssertEqual(spec.sourceSide, layout.lcdSide)
    }

    func testMiniPlayerScreenIsForPicturesNeverTheRecord() {
        XCTAssertTrue(MiniPlayerArtMode.cover.showsScreen(streamPlaying: false))
        XCTAssertFalse(MiniPlayerArtMode.disc.showsScreen(streamPlaying: false), "the spinning record")
        // A stream shows its thumbnail whatever the mode.
        XCTAssertTrue(MiniPlayerArtMode.disc.showsScreen(streamPlaying: true))
        XCTAssertTrue(MiniPlayerArtMode.cover.showsScreen(streamPlaying: true))
    }

    // MARK: - The picture

    private func solidImage(width: Int, height: Int, rgba: (CGFloat, CGFloat, CGFloat, CGFloat),
                            leftHalf: (CGFloat, CGFloat, CGFloat)? = nil) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: rgba.0, green: rgba.1, blue: rgba.2, alpha: rgba.3))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let left = leftHalf {
            context.setFillColor(CGColor(srgbRed: left.0, green: left.1, blue: left.2, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        }
        return context.makeImage()!
    }

    private func pixel(_ bytes: [UInt8], side: Int, _ x: Int, _ y: Int) -> [UInt8] {
        let i = (y * side + x) * 4
        return Array(bytes[i..<i + 4])
    }

    /// A transparent cover comes out opaque black, as the renderer assumes.
    func testResampleFillsTransparencyWithBlack() throws {
        let clear = solidImage(width: 40, height: 40, rgba: (1, 1, 1, 0))
        let bytes = try XCTUnwrap(CoverScreenImage.resample(clear, side: 10))
        XCTAssertEqual(bytes.count, 10 * 10 * 4)
        XCTAssertEqual(pixel(bytes, side: 10, 5, 5), [0, 0, 0, 255])
    }

    /// Aspect fill, centred: a 2:1 cover, red on its left half and blue on
    /// its right, keeps only its middle square, so the left edge of the
    /// result is red and the right edge blue, with no black bars.
    func testResampleCropsANonSquareCoverLikeTheWell() throws {
        let wide = solidImage(width: 200, height: 100, rgba: (0, 0, 1, 1), leftHalf: (1, 0, 0))
        let bytes = try XCTUnwrap(CoverScreenImage.resample(wide, side: 20))
        XCTAssertEqual(pixel(bytes, side: 20, 0, 10), [255, 0, 0, 255])
        XCTAssertEqual(pixel(bytes, side: 20, 19, 10), [0, 0, 255, 255])
        XCTAssertEqual(pixel(bytes, side: 20, 10, 0)[3], 255)
        XCTAssertEqual(pixel(bytes, side: 20, 10, 19)[3], 255)
    }

    func testRenderedPictureIsTheLCDsSizeAndNotInterpolated() throws {
        let theme = try render("pocket", .light)
        let spec = try XCTUnwrap(CoverScreenSpec(theme: theme, side: 230, scale: 2))
        let cover = solidImage(width: 300, height: 300, rgba: (0.5, 0.2, 0.8, 1))
        let picture = try XCTUnwrap(CoverScreenImage.render(cover, spec: spec))
        XCTAssertEqual(picture.width, spec.layout.lcdSide)
        XCTAssertEqual(picture.height, spec.layout.lcdSide)
        XCTAssertFalse(picture.shouldInterpolate)

        let unlit = try XCTUnwrap(CoverScreenImage.renderUnlit(spec: spec))
        XCTAssertEqual(unlit.width, spec.layout.lcdSide)
        XCTAssertFalse(unlit.shouldInterpolate)
    }

    /// The unlit panel of the grid look goes through the pixel renderer (a
    /// flat colour is the same either way); it must still come out whole.
    func testUnlitPanelForTheGridLook() throws {
        let layout = CoverScreenLayout.plan(side: 246, scale: 2, pixelSize: 1.5)
        let spec = CoverScreenSpec(look: .grid, strength: 0.55, layout: layout, scale: 2,
                                   unlit: .init(r: 100, g: 100, b: 100))
        let unlit = try XCTUnwrap(CoverScreenImage.renderUnlit(spec: spec))
        XCTAssertEqual(unlit.width, layout.lcdSide)
    }

    func testMakeImageRefusesTheWrongByteCount() {
        XCTAssertNil(CoverScreenImage.makeImage(rgba: [0, 0, 0, 255], side: 2))
        XCTAssertNil(CoverScreenImage.makeImage(rgba: [], side: 0))
    }

    func testCacheHandsBackWhatItWasGiven() {
        let image = solidImage(width: 4, height: 4, rgba: (1, 0, 0, 1))
        let key = "test-\(UUID().uuidString)"
        XCTAssertNil(CoverScreenCache.image(forKey: key))
        CoverScreenCache.store(image, forKey: key)
        XCTAssertTrue(CoverScreenCache.image(forKey: key) === image)
    }

    // MARK: - What the cover reloads on

    /// A pasted link plays before its metadata names a thumbnail. The key
    /// has to change when the URL arrives, or the screen stays unlit; and
    /// again if the URL changes, or the cache serves the old picture.
    func testStreamKeyFollowsItsThumbnailURL() {
        let none = NowPlayingCoverKey.stream(id: "u1", thumbnailURL: nil)
        let first = NowPlayingCoverKey.stream(id: "u1", thumbnailURL: "https://i.ytimg.com/vi/a/hq.jpg")
        let second = NowPlayingCoverKey.stream(id: "u1", thumbnailURL: "https://i.ytimg.com/vi/a/max.jpg")
        XCTAssertNotEqual(none, first)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first, NowPlayingCoverKey.stream(id: "u1", thumbnailURL: "https://i.ytimg.com/vi/a/hq.jpg"))
        XCTAssertNotEqual(first, NowPlayingCoverKey.stream(id: "u2", thumbnailURL: "https://i.ytimg.com/vi/a/hq.jpg"))
        XCTAssertNotEqual(NowPlayingCoverKey.stream(id: nil, thumbnailURL: nil), none)
    }

    func testTrackKeyFollowsTheTrackAndItsArtworkHash() {
        let id = UUID()
        let key = NowPlayingCoverKey.track(id: id, artworkHash: "abc")
        XCTAssertEqual(key, NowPlayingCoverKey.track(id: id, artworkHash: "abc"))
        XCTAssertNotEqual(key, NowPlayingCoverKey.track(id: id, artworkHash: "def"))
        XCTAssertNotEqual(key, NowPlayingCoverKey.track(id: UUID(), artworkHash: "abc"))
        XCTAssertNotEqual(key, NowPlayingCoverKey.stream(id: id.uuidString, thumbnailURL: nil))
    }
}
#endif
