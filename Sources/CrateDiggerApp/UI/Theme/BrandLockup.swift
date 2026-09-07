import CrateDiggerCore
import SwiftUI

/// The brand mark: a record half out of the crate.
///
/// Two shapes and one accent, which is what lets it survive the 11pt it is
/// drawn at in the header. Every number comes from `BrandLockupMetrics.Glyph`,
/// which is also what the lockup measures itself against.
///
/// The gap between the disc and the crate is masked **out of the disc** rather
/// than painted in the surface colour: a painted gap haloes the moment the
/// mark sits on a gradient, which is exactly where it lives.
struct BrandGlyph: View {
    var ink: Color
    var accent: Color

    private typealias Glyph = BrandLockupMetrics.Glyph

    var body: some View {
        GeometryReader { proxy in
            let unit = min(proxy.size.width, proxy.size.height) / Glyph.grid
            ZStack(alignment: .topLeading) {
                Circle()
                    .fill(ink)
                    .frame(width: Glyph.discRadius * 2 * unit, height: Glyph.discRadius * 2 * unit)
                    .mask(alignment: .topLeading) {
                        Rectangle()
                            .frame(height: Glyph.discVisibleHeight * unit)
                    }
                    .offset(
                        x: (Glyph.discCentre.x - Glyph.discRadius) * unit,
                        y: (Glyph.discCentre.y - Glyph.discRadius) * unit
                    )

                Circle()
                    .fill(accent)
                    .frame(width: Glyph.spindleRadius * 2 * unit, height: Glyph.spindleRadius * 2 * unit)
                    .offset(
                        x: (Glyph.discCentre.x - Glyph.spindleRadius) * unit,
                        y: (Glyph.discCentre.y - Glyph.spindleRadius) * unit
                    )

                RoundedRectangle(cornerRadius: Glyph.crateCornerRadius * unit, style: .continuous)
                    .fill(ink)
                    .frame(width: Glyph.crate.width * unit, height: Glyph.crate.height * unit)
                    .offset(x: Glyph.crate.minX * unit, y: Glyph.crate.minY * unit)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Mark plus name.
///
/// The mark is sized so its ink equals the capitals of whatever face is
/// drawing the name, then hung from the text's own baseline — so the disc's
/// top lands on the cap line and the crate sits on the baseline, in any theme
/// and at any size. `BrandLockupMetrics` owns the arithmetic.
///
/// The name is set in the display face, which ships as Major Mono Display —
/// the same one the OLED speaks — and follows a theme that names its own.
struct BrandLockup: View {
    @Environment(\.carbon) private var theme

    var typeSize: CGFloat
    /// Nil follows the theme's ink; the one-colour lockups pass a colour.
    var ink: Color?
    var accent: Color?

    init(typeSize: CGFloat, ink: Color? = nil, accent: Color? = nil) {
        self.typeSize = typeSize
        self.ink = ink
        self.accent = accent
    }

    var body: some View {
        let glyph = BrandLockupMetrics.glyphSize(
            forTypeSize: typeSize,
            capHeight: CarbonFont.displayCapHeight
        )
        HStack(alignment: .firstTextBaseline, spacing: BrandLockupMetrics.gap(forTypeSize: typeSize)) {
            BrandGlyph(ink: ink ?? theme.ink, accent: accent ?? theme.orange)
                .frame(width: glyph, height: glyph)
                // The crate's underside is the mark's baseline. Declaring it
                // as such is the whole alignment: no offsets, no line-box
                // arithmetic, and it survives a theme swapping the face.
                .alignmentGuide(.firstTextBaseline) { _ in
                    BrandLockupMetrics.baselineGuide(glyphSize: glyph)
                }
            Text("CrateDigger")
                .font(CarbonFont.display(typeSize))
                .foregroundStyle(ink ?? theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement()
        .accessibilityLabel("CrateDigger")
    }
}
