import CrateDiggerCore
import SwiftUI

/// The five Busy Signals inks, resolved against one glass theme (spec §2.2).
///
/// Built from the theme the environment hands the glass, never from the
/// `ActiveOLEDPalette` globals, so a snapshot renders the same colours on
/// every run. Monochrome needs no branch here: `OLEDDisplay` gives a
/// monochrome glass `CarbonTheme.monochromeGlass`, whose cyan and Meter High
/// already *are* the phosphor, so cool, hot and foreground resolve to one
/// colour and the dim print and intensity are what tell them apart.
struct BusyInkPalette: Equatable {
    var foreground, cool, hot, dim, background: Color

    /// How bright the `.dim` ink is: the sketch's `pal.dim`.
    static let dimOpacity: Double = 0.26

    init(theme: CarbonTheme) {
        foreground = theme.oledForeground
        cool = theme.cyan
        hot = theme.meterHot
        dim = theme.oledForeground.opacity(Self.dimOpacity)
        background = theme.oledSurface
    }

    func color(_ ink: BusyInk) -> Color {
        switch ink {
        case .foreground: return foreground
        case .cool: return cool
        case .hot: return hot
        case .dim: return dim
        case .background: return background
        }
    }
}

/// The one Busy Signals renderer: replays a Core `BusyDrawing` into a
/// SwiftUI `Canvas`, for both the pane picture and the rail minis.
///
/// - **Fit.** The drawing's unit space is scaled uniformly to the frame,
///   centred and letterboxed, never stretched (html:943). Everything is
///   clipped to the view's whole frame, *not* to the letterboxed rect: the
///   sketch's canvas was the 220 × 84 frame, so the scan's sliding crates
///   ran on into the margins beside the 201.6-wide scene and were cut only
///   at the canvas edge. Clipping to the letterbox cut them with a hard
///   vertical edge inside the frame (19 pt a side at the 220 × 76 band). No
///   other picture or mini draws outside its unit space (`BusySceneTests`),
///   so for them the two clips are the same; only the glow's fringe at the
///   scene's edge now reaches into the margin, as it did in the sketch.
/// - **Points, not units.** Geometry is transformed into view points before
///   it is stroked, so `lineWidth` and `glowRadius` are screen points at any
///   size. Caps and joins are round.
/// - **Order is kept.** `.background` fills occlude what is under them, so
///   shapes are never regrouped by ink; only *consecutive* passes that share
///   ink, style, glow and weight are batched (`batches(_:)`). A glowing batch
///   is drawn in one layer with a shadow in its own ink.
/// - **Glow** follows the sketch's pen (html:187-215): strokes glow, fills
///   with no stroke glow (`dot`, `block`, note heads), a fill under a stroke
///   does not, a `.background` fill never does, and text never does.
/// - **Background fills on the real glass: flat `oledSurface`, kept.** The
///   glass behind is a gradient (OLEDDisplay's white → clear →
///   `oledSurfaceShade` rake), so an occluder can differ from the glass
///   beside it. Measured on the Task 14 contact sheets (a picture-sized
///   window at the centre of a 720 × 150 glass): Carbon's black rake on a
///   near-black surface is a no-op, and the glass varies by at most 3/255
///   across the picture, so the cassette, crate, records, file and iPod
///   bodies are indistinguishable from it. On the pale BACKLIT preset the
///   glass runs from 1/255 lighter to 7/255 darker than `oledSurface`
///   across the window, so an occluder's far corner reads at most ~6/255
///   lighter than the glass just outside its outline, which the outline
///   itself hides. The spec's fallback (`oledSurface` composited with the
///   gradient sampled at the picture's centre) would change nothing here:
///   the rake's middle stop is clear, and a pane's picture sits near the
///   middle of the glass. Revisit only if a picture moves to an edge of the
///   glass, or a theme's rake gets much stronger.
/// - **Text** is set with `CarbonFont.monoExact`, not `mono`:
///   `Font.custom(_:size:relativeTo:)` snaps to whole points, which drew the
///   5.5-unit labels (4.62 pt in a 220 × 84 frame) at 5 pt, 8 % larger than
///   the sketch. The sheets confirm size and baseline now match.
///
/// `Equatable` on `(drawing, lineWidth)` and used with `.equatable()`: a
/// timeline tick that lands in the same animation step builds an equal
/// drawing and redraws nothing. The theme is an environment dependency, so a
/// theme change still redraws.
struct BusyCanvas: View, Equatable {
    let drawing: BusyDrawing
    /// Screen points: 1.15 for a picture, 0.95 for a mini (html:950, :962).
    let lineWidth: CGFloat

    /// The glow's blur, in screen points. The sketch's `shadowBlur 3` device
    /// pixels at 2× is 1.5 pt of canvas blur, but canvas blur is twice its
    /// Gaussian σ while GraphicsContext's `.shadow(radius:)` spreads about as
    /// wide as its radius: at 1.5 the halo was twice the sketch's and filled
    /// the spindle hole grey. Tuned on the Task 14 contact sheets against the
    /// sketch rendered headless at the same scale (blur scaled to match):
    /// 0.75 pt reproduces the sketch's halo width and intensity.
    static let glowRadius: CGFloat = 0.75

    @Environment(\.carbon) private var theme

    nonisolated static func == (lhs: BusyCanvas, rhs: BusyCanvas) -> Bool {
        lhs.drawing == rhs.drawing && lhs.lineWidth == rhs.lineWidth
    }

    var body: some View {
        let drawing = drawing
        let lineWidth = lineWidth
        let palette = BusyInkPalette(theme: theme)
        Canvas { context, size in
            Self.render(drawing, lineWidth: lineWidth, palette: palette, into: &context, size: size)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Fit

extension BusyCanvas {
    /// How a unit space sits in a frame: the uniform scale `k`, the
    /// letterboxed rect it occupies, and the unit → point transform.
    struct Fit: Equatable {
        var scale: CGFloat
        var rect: CGRect
        var transform: CGAffineTransform
    }

    /// `k = min(w / unit.w, h / unit.h)`, centred. A degenerate frame or unit
    /// space (zero, negative or non-finite) fits nothing: scale 0 and an
    /// empty rect, which the renderer treats as "draw nothing".
    static func fit(_ unit: CGSize, into frame: CGSize) -> Fit {
        let none = Fit(scale: 0, rect: .zero, transform: .identity)
        guard unit.width > 0, unit.height > 0, frame.width > 0, frame.height > 0,
              unit.width.isFinite, unit.height.isFinite,
              frame.width.isFinite, frame.height.isFinite else { return none }
        let k = min(frame.width / unit.width, frame.height / unit.height)
        let size = CGSize(width: unit.width * k, height: unit.height * k)
        let origin = CGPoint(x: (frame.width - size.width) / 2, y: (frame.height - size.height) / 2)
        let transform = CGAffineTransform(translationX: origin.x, y: origin.y).scaledBy(x: k, y: k)
        return Fit(scale: k, rect: CGRect(origin: origin, size: size), transform: transform)
    }
}

// MARK: - Glow and batching

extension BusyCanvas {
    /// A stroke glows unless it is in the occluding background ink (which a
    /// scene never strokes, but the rule is total).
    static func glows(stroke ink: BusyInk) -> Bool {
        ink != .background
    }

    /// A fill glows only when nothing is stroked over it and it is not a
    /// background occluder: the sketch zeroes `shadowBlur` before a fill
    /// that a stroke follows, and `dot` / `block` fill with it on.
    static func glows(fill ink: BusyInk, under stroke: BusyInk?) -> Bool {
        stroke == nil && ink != .background
    }

    /// Whether a stroke batch in this ink is stroked shape by shape rather
    /// than as one merged path. The sketch strokes every call on its own, so
    /// where two translucent strokes cross their alpha (and glow) builds up;
    /// one merged path paints a crossing once and reads lighter there. Only
    /// `.dim` is translucent, and the opaque inks keep the single stroke,
    /// which looks the same and costs one draw call.
    static func strokesShapeByShape(_ ink: BusyInk) -> Bool {
        ink == .dim
    }

    enum Mode: Equatable {
        case stroke, fill, text
    }

    /// What a run of consecutive passes must share to be drawn as one.
    struct BatchKey: Equatable {
        var ink: BusyInk
        var mode: Mode
        var glows: Bool
        /// The line-width multiplier. Always 1 for fills and text.
        var weight: CGFloat
    }

    /// One draw call: shapes painted the same way, in drawing order. A shape
    /// that both fills and strokes appears in two batches, fill first, as
    /// the sketch's pen paints it.
    struct Batch {
        var key: BatchKey
        var shapes: [BusyShape]
    }

    /// Splits a clip-free run of shapes into batches, merging only
    /// neighbours with an equal key. Text never merges (each run is placed
    /// on its own baseline). Clip markers are skipped: `draw` cuts the shape
    /// list at them before it batches.
    static func batches(_ shapes: some Sequence<BusyShape>) -> [Batch] {
        var out: [Batch] = []
        func add(_ shape: BusyShape, _ key: BatchKey) {
            if key.mode != .text, let last = out.last, last.key == key {
                out[out.count - 1].shapes.append(shape)
            } else {
                out.append(Batch(key: key, shapes: [shape]))
            }
        }
        func stroke(_ shape: BusyShape, _ ink: BusyInk, weight: CGFloat = 1) {
            add(shape, BatchKey(ink: ink, mode: .stroke, glows: glows(stroke: ink), weight: weight))
        }
        func fillThenStroke(_ shape: BusyShape, _ strokeInk: BusyInk?, _ fillInk: BusyInk?) {
            if let fillInk {
                add(shape, BatchKey(ink: fillInk, mode: .fill,
                                    glows: glows(fill: fillInk, under: strokeInk), weight: 1))
            }
            if let strokeInk { stroke(shape, strokeInk) }
        }

        for shape in shapes {
            switch shape {
            case let .line(_, _, ink, weight):
                stroke(shape, ink, weight: weight)
            case let .arc(_, _, _, _, ink), let .quadCurve(_, _, _, ink):
                stroke(shape, ink)
            case let .path(_, _, strokeInk, fillInk), let .circle(_, _, strokeInk, fillInk),
                 let .rect(_, strokeInk, fillInk), let .roundedRect(_, _, strokeInk, fillInk):
                fillThenStroke(shape, strokeInk, fillInk)
            case let .ellipse(_, _, _, ink):
                fillThenStroke(shape, nil, ink)
            case let .text(_, _, _, _, ink):
                add(shape, BatchKey(ink: ink, mode: .text, glows: false, weight: 1))
            case .clipBegin, .clipEnd:
                continue
            }
        }
        return out
    }
}

// MARK: - Rendering

extension BusyCanvas {
    static func render(_ drawing: BusyDrawing, lineWidth: CGFloat, palette: BusyInkPalette,
                       into context: inout GraphicsContext, size: CGSize) {
        let fit = fit(drawing.size, into: size)
        guard fit.scale > 0 else { return }
        var scene = context
        scene.clip(to: Path(CGRect(origin: .zero, size: size)))
        let pen = Pen(fit: fit, lineWidth: lineWidth, palette: palette)
        pen.draw(drawing.shapes[...], into: &scene)
    }

    /// Everything one render needs, so the recursive walk passes one value.
    private struct Pen {
        let fit: Fit
        let lineWidth: CGFloat
        let palette: BusyInkPalette

        /// Draws `shapes` in order. A `clipBegin` cuts the list: what precedes
        /// it is batched and drawn, the slice up to its matching `clipEnd` is
        /// drawn recursively into a copy of the context clipped to the
        /// transformed rounded rect (a copy shares the destination, so order
        /// holds, and the clip ends with the copy), and the walk resumes after
        /// it. An unmatched `clipBegin` clips to the end of the drawing; a
        /// stray `clipEnd` is ignored.
        func draw(_ shapes: ArraySlice<BusyShape>, into context: inout GraphicsContext) {
            var runStart = shapes.startIndex
            var index = shapes.startIndex
            while index < shapes.endIndex {
                switch shapes[index] {
                case let .clipBegin(rect, radius):
                    paint(shapes[runStart..<index], into: &context)
                    let close = matchingEnd(in: shapes, after: index)
                    var clipped = context
                    let box = rect.standardized.applying(fit.transform)
                    let corner = max(0, radius * fit.scale)
                    clipped.clip(to: Path(roundedRect: box, cornerRadius: corner, style: .circular))
                    draw(shapes[(index + 1)..<close], into: &clipped)
                    index = close < shapes.endIndex ? close + 1 : close
                    runStart = index
                case .clipEnd:
                    paint(shapes[runStart..<index], into: &context)
                    index += 1
                    runStart = index
                default:
                    index += 1
                }
            }
            paint(shapes[runStart..<shapes.endIndex], into: &context)
        }

        /// The index of the `clipEnd` that closes the `clipBegin` at `open`,
        /// or `endIndex` when it is never closed.
        private func matchingEnd(in shapes: ArraySlice<BusyShape>, after open: Int) -> Int {
            var depth = 0
            var index = open + 1
            while index < shapes.endIndex {
                switch shapes[index] {
                case .clipBegin: depth += 1
                case .clipEnd:
                    if depth == 0 { return index }
                    depth -= 1
                default: break
                }
                index += 1
            }
            return shapes.endIndex
        }

        private func paint(_ shapes: ArraySlice<BusyShape>, into context: inout GraphicsContext) {
            guard !shapes.isEmpty else { return }
            for batch in BusyCanvas.batches(shapes) {
                let color = palette.color(batch.key.ink)
                if batch.key.glows {
                    context.drawLayer { layer in
                        layer.addFilter(.shadow(color: color, radius: BusyCanvas.glowRadius))
                        paint(batch, color, into: &layer)
                    }
                } else {
                    paint(batch, color, into: &context)
                }
            }
        }

        private func paint(_ batch: Batch, _ color: Color, into context: inout GraphicsContext) {
            switch batch.key.mode {
            case .stroke:
                let style = StrokeStyle(lineWidth: lineWidth * batch.key.weight,
                                        lineCap: .round, lineJoin: .round)
                if BusyCanvas.strokesShapeByShape(batch.key.ink) {
                    // One stroke per shape, so translucent crossings build up
                    // as the sketch's do. The batch still shares one glow layer.
                    for shape in batch.shapes {
                        var path = Path()
                        BusyCanvas.addOutline(of: shape, to: &path)
                        context.stroke(path.applying(fit.transform), with: .color(color), style: style)
                    }
                } else {
                    var path = Path()
                    for shape in batch.shapes { BusyCanvas.addOutline(of: shape, to: &path) }
                    context.stroke(path.applying(fit.transform), with: .color(color), style: style)
                }
            case .fill:
                // One fill per shape rather than one merged path: nonzero
                // winding would cancel two overlapping polygons of opposite
                // orientation, which canvas (filling each separately) never
                // does. The batch still shares one glow layer.
                for shape in batch.shapes {
                    var path = Path()
                    BusyCanvas.addOutline(of: shape, to: &path)
                    context.fill(path.applying(fit.transform), with: .color(color))
                }
            case .text:
                for shape in batch.shapes { text(shape, color, into: &context) }
            }
        }

        /// Places a text run so that its `at` point is the alphabetic
        /// baseline, as the sketch's `fillText` does. The resolved text's own
        /// first baseline is used rather than an estimated descender, so the
        /// placement is exact for whichever mono face the theme supplies.
        private func text(_ shape: BusyShape, _ color: Color, into context: inout GraphicsContext) {
            guard case let .text(string, at, size, align, _) = shape, !string.isEmpty else { return }
            let pointSize = size * fit.scale
            guard pointSize > 0 else { return }
            var resolved = context.resolve(Text(string).font(CarbonFont.monoExact(pointSize, weight: .semibold)))
            resolved.shading = .color(color)
            let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            let measured = resolved.measure(in: unbounded)
            let baseline = resolved.firstBaseline(in: measured)
            let anchor = at.applying(fit.transform)
            let x: CGFloat
            switch align {
            case .left: x = anchor.x
            case .center: x = anchor.x - measured.width / 2
            case .right: x = anchor.x - measured.width
            }
            context.draw(resolved, in: CGRect(x: x, y: anchor.y - baseline,
                                              width: measured.width, height: measured.height))
        }
    }

    /// Appends one shape's outline to `path`, in unit space. Every shape
    /// opens its own subpath, so batching never joins two shapes with a
    /// stray segment (`addArc` would otherwise line from the current point).
    static func addOutline(of shape: BusyShape, to path: inout Path) {
        switch shape {
        case let .line(from, to, _, _):
            path.move(to: from)
            path.addLine(to: to)
        case let .path(points, closed, _, _):
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
            if closed { path.closeSubpath() }
        case let .circle(center, radius, _, _):
            let r = abs(radius)
            path.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        case let .arc(center, radius, start, end, _):
            addArc(center: center, radius: abs(radius), start: start, end: end, to: &path)
        case let .ellipse(center, radii, rotation, _):
            let box = CGRect(x: -radii.width, y: -radii.height,
                             width: 2 * radii.width, height: 2 * radii.height).standardized
            let place = CGAffineTransform(rotationAngle: CGFloat(rotation))
                .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
            path.addPath(Path(ellipseIn: box), transform: place)
        case let .quadCurve(from, control, to, _):
            path.move(to: from)
            path.addQuadCurve(to: to, control: control)
        case let .rect(rect, _, _):
            path.addRect(rect.standardized)
        case let .roundedRect(rect, radius, _, _):
            let rect = rect.standardized
            let r = min(max(0, radius), rect.width / 2, rect.height / 2)
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: r, height: r), style: .circular)
        case .text, .clipBegin, .clipEnd:
            return
        }
    }

    /// Canvas `arc(x, y, r, a0, a1)` with `anticlockwise` false: the sweep
    /// runs towards increasing angles (clockwise on a y-down screen), an
    /// `end` below `start` wraps forward by 2π, and a sweep of 2π or more is
    /// the whole circle. In y-down space `clockwise: false` is the
    /// increasing-angle direction, so it matches canvas without flipping.
    private static func addArc(center: CGPoint, radius: CGFloat, start: Double, end: Double,
                               to path: inout Path) {
        let twoPi = 2 * Double.pi
        var sweep = end - start
        if sweep >= twoPi {
            sweep = twoPi
        } else {
            sweep = sweep.truncatingRemainder(dividingBy: twoPi)
            if sweep < 0 { sweep += twoPi }
        }
        guard sweep > 0 else { return }
        if sweep >= twoPi {
            path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                       width: 2 * radius, height: 2 * radius))
            return
        }
        path.move(to: CGPoint(x: center.x + CGFloat(cos(start)) * radius,
                              y: center.y + CGFloat(sin(start)) * radius))
        path.addArc(center: center, radius: radius,
                    startAngle: .radians(start), endAngle: .radians(start + sweep), clockwise: false)
    }
}
