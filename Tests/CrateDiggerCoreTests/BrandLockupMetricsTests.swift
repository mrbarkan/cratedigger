import CoreGraphics
import XCTest
@testable import CrateDiggerCore

/// The lockup's one promise: the mark's ink spans the capitals exactly — at
/// any size, and in any face a theme names. Everything in
/// `BrandLockupMetrics` exists to make that true, so that is what is tested
/// rather than the individual constants.
final class BrandLockupMetricsTests: XCTestCase {
    private let sizes: [CGFloat] = [11, 13, 16, 20, 26, 28, 40, 96]

    /// Major Mono Display as shipped, plus faces a theme might reasonably
    /// name. Helvetica Neue and SF Pro are both already used by themes in the
    /// wild; the extremes are there to prove nothing is tuned to one number.
    private let capHeights: [(String, CGFloat)] = [
        ("Major Mono Display", BrandLockupMetrics.majorMonoCapHeight),
        ("Helvetica Neue", 0.714),
        ("SF Pro", 0.700),
        ("a very small-capped face", 0.520),
        ("a very large-capped face", 0.780)
    ]

    func testTheMarksInkAlwaysEqualsTheCapHeight() {
        for size in sizes {
            for (face, capHeight) in capHeights {
                let glyph = BrandLockupMetrics.glyphSize(forTypeSize: size, capHeight: capHeight)
                XCTAssertEqual(
                    BrandLockupMetrics.inkHeight(glyphSize: glyph),
                    size * capHeight,
                    accuracy: 0.0001,
                    "the mark should be exactly cap height at \(size)pt in \(face)"
                )
            }
        }
    }

    /// The crate's underside is the glyph's baseline, so seating it on the
    /// text baseline puts the disc's top on the cap line for free. This checks
    /// the other half of that: the ink above the baseline guide is the cap
    /// height, which is what makes the two line up.
    func testTheDiscTopLandsOnTheCapLine() {
        for size in sizes {
            for (face, capHeight) in capHeights {
                let glyph = BrandLockupMetrics.glyphSize(forTypeSize: size, capHeight: capHeight)
                let baseline = BrandLockupMetrics.baselineGuide(glyphSize: glyph)
                let inkTop = BrandLockupMetrics.inkTop * glyph
                XCTAssertEqual(
                    baseline - inkTop,
                    size * capHeight,
                    accuracy: 0.0001,
                    "the disc should start a cap height above the baseline at \(size)pt in \(face)"
                )
            }
        }
    }

    /// Nothing below the crate: its underside *is* the baseline, so the mark
    /// never dips into the descender space where a lockup starts to look like
    /// it is falling off the line.
    func testTheMarkSitsEntirelyOnOrAboveTheBaseline() {
        let glyph = BrandLockupMetrics.glyphSize(forTypeSize: 40)
        XCTAssertEqual(BrandLockupMetrics.baselineGuide(glyphSize: glyph),
                       BrandLockupMetrics.inkBottom * glyph, accuracy: 0.0001)
        XCTAssertEqual(BrandLockupMetrics.inkBottom * BrandLockupMetrics.Glyph.grid,
                       BrandLockupMetrics.Glyph.crate.maxY, accuracy: 0.0001)
    }

    func testEverythingScalesLinearly() {
        let single = BrandLockupMetrics.glyphSize(forTypeSize: 1)
        XCTAssertEqual(BrandLockupMetrics.glyphSize(forTypeSize: 40), single * 40, accuracy: 0.0001)
        XCTAssertEqual(BrandLockupMetrics.gap(forTypeSize: 30), 10, accuracy: 0.0001)
    }

    /// The ratio the brand sheet documents, so a change to the mark's grid
    /// shows up here as a deliberate edit rather than a drifting lockup.
    func testTheDocumentedRatioHolds() {
        XCTAssertEqual(BrandLockupMetrics.glyphSize(forTypeSize: 1), 0.807, accuracy: 0.001)
    }

    /// The disc is cut where the gap starts, not at the crate's edge.
    func testTheGapIsCutOutOfTheDisc() {
        XCTAssertEqual(BrandLockupMetrics.Glyph.discCut, 15, accuracy: 0.0001)
        XCTAssertEqual(BrandLockupMetrics.Glyph.discVisibleHeight, 13.5, accuracy: 0.0001)
    }
}
