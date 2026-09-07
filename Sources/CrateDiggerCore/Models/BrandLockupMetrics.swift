import CoreGraphics

/// How the brand glyph is sized and placed beside the word "CrateDigger".
///
/// The mark reads as a letter in the word rather than a picture next to it,
/// and that only works if its ink spans exactly the capitals: the disc's top
/// on the cap line, the crate's underside on the baseline. Eyeballing that is
/// what makes a lockup look almost-right, so it is computed here instead.
///
/// Two things make it hold at any size and in any theme:
///
/// - the glyph is sized so its **ink** — not its box — equals the cap height
///   of whichever face is actually drawing the name;
/// - it is then hung from the text's own baseline, so nothing here has to
///   model a line box, its leading, or where SwiftUI centres it.
///
/// A theme may name its own display face, and the wordmark follows it like
/// every other label in the app. That is why `capHeight` is a parameter: pin
/// it to one face's number and the mark quietly misaligns the moment somebody
/// picks a different one.
public enum BrandLockupMetrics {
    /// Cap height of the shipped display face, Major Mono Display, in ems.
    /// Read from its `OS/2` table. Callers that can resolve the face actually
    /// in use should pass its own instead.
    public static let majorMonoCapHeight: CGFloat = 0.696

    // MARK: - The mark, in its own 24-unit grid

    /// The mark's geometry, and the only place it is written down: the views
    /// draw from these numbers and the metrics below are derived from them, so
    /// redrawing the mark cannot leave the lockup silently misaligned.
    public enum Glyph {
        public static let grid: CGFloat = 24
        public static let discCentre = CGPoint(x: 12, y: 10.5)
        public static let discRadius: CGFloat = 9
        /// The spindle hole, in the accent.
        public static let spindleRadius: CGFloat = 3.1
        public static let crate = CGRect(x: 1, y: 16.6, width: 22, height: 5.6)
        public static let crateCornerRadius: CGFloat = 1.6
        /// Air between the disc and the crate. Masked out of the disc, never
        /// painted in the surface colour: a painted gap haloes the moment the
        /// mark sits on a gradient, which is where it lives.
        public static let gapAboveCrate: CGFloat = 1.6

        /// Where the disc stops, leaving the gap above the crate.
        public static var discCut: CGFloat { crate.minY - gapAboveCrate }
        /// How much of the disc survives the cut, measured from its own top.
        public static var discVisibleHeight: CGFloat { discCut - (discCentre.y - discRadius) }
    }

    /// Top of the disc, as a fraction of the glyph's box.
    public static var inkTop: CGFloat { (Glyph.discCentre.y - Glyph.discRadius) / Glyph.grid }
    /// Underside of the crate, as a fraction of the glyph's box.
    public static var inkBottom: CGFloat { Glyph.crate.maxY / Glyph.grid }
    /// How much of the box is actually ink.
    public static var inkSpan: CGFloat { inkBottom - inkTop }

    // MARK: - The lockup

    /// The glyph's box, sized so its ink matches the capitals of the face
    /// drawing the name.
    public static func glyphSize(
        forTypeSize typeSize: CGFloat,
        capHeight: CGFloat = majorMonoCapHeight
    ) -> CGFloat {
        typeSize * capHeight / inkSpan
    }

    /// Where the glyph's own baseline sits, measured down from the top of its
    /// box: the underside of the crate. Handing this to SwiftUI as the glyph's
    /// text-baseline guide is what seats the mark on the same line as the
    /// word, with no line-box arithmetic anywhere.
    public static func baselineGuide(glyphSize: CGFloat) -> CGFloat {
        inkBottom * glyphSize
    }

    /// The space between the mark and the word: a third of the type size,
    /// which is about one stroke wider than the face's own letter gaps, so the
    /// mark reads as a mark rather than as a sixth letter.
    public static func gap(forTypeSize typeSize: CGFloat) -> CGFloat {
        typeSize / 3
    }

    /// Height of the mark's ink — what should equal the cap height.
    public static func inkHeight(glyphSize: CGFloat) -> CGFloat {
        inkSpan * glyphSize
    }
}
