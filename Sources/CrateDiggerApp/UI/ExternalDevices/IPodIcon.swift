import SwiftUI

// Parametric iPod device icons — a faithful SwiftUI port of the mock's single
// `ipodSVG(geometry, finish)` generator (see Device Icons.html). One drawing
// routine + a 3-geometry × 14-finish catalog drives every model, so there are
// no image assets to ship.

/// Geometry for one iPod family, in native viewBox units (the mock's `GEO`).
private struct IPodGeometry {
    let w, h, radius: CGFloat
    let screenW, screenH, screenY: CGFloat
    let wheelR, wheelCY: CGFloat
}

/// Anodized finish colours (the mock's `FINISHES`), as 0xRRGGBB.
private struct IPodFinish {
    let body: [UInt32]      // 3-stop diagonal gradient
    let bezel: UInt32
    let wheelC, wheelHi, hub: UInt32
}

/// A catalog entry: id + display labels + the geometry/finish that draw it.
struct IPodIconEntry: Identifiable {
    let id: String          // e.g. "classic.black"
    let family: String      // CLASSIC / MINI / NANO
    let finishName: String  // Silver, Black, U2 …
    fileprivate let geometry: IPodGeometry
    fileprivate let finish: IPodFinish

    var displayName: String {
        "\(family) · \(finishName.uppercased())"
    }
}

enum IPodCatalog {
    private static let classic = IPodGeometry(w: 118, h: 190, radius: 16, screenW: 82, screenH: 62, screenY: 18, wheelR: 36, wheelCY: 138)
    private static let mini    = IPodGeometry(w: 88, h: 178, radius: 20, screenW: 60, screenH: 44, screenY: 16, wheelR: 29, wheelCY: 126)
    private static let nano    = IPodGeometry(w: 74, h: 168, radius: 12, screenW: 52, screenH: 42, screenY: 14, wheelR: 25, wheelCY: 122)

    // Bright "white" click-wheel shared by the anodized colours.
    private static let whiteWheelC: UInt32 = 0xDDE1E5
    private static let whiteWheelHi: UInt32 = 0xFBFCFD
    private static let whiteHub: UInt32 = 0xC6CCD2

    /// The 14 icons in the same order as the mock's picker.
    static let all: [IPodIconEntry] = [
        entry("classic.silver", "CLASSIC", "Silver", classic,
              IPodFinish(body: [0xFAFBFC, 0xD8DEE4, 0xB4BDC6], bezel: 0x9AA3AC, wheelC: whiteWheelC, wheelHi: whiteWheelHi, hub: whiteHub)),
        entry("classic.black", "CLASSIC", "Black", classic,
              IPodFinish(body: [0x43464C, 0x212328, 0x101114], bezel: 0x0B0C0E, wheelC: 0x26282D, wheelHi: 0x4A4E55, hub: 0x151619)),
        entry("classic.u2", "CLASSIC", "U2", classic,
              IPodFinish(body: [0x33343A, 0x17181C, 0x0A0B0D], bezel: 0x0B0C0E, wheelC: 0xC0121F, wheelHi: 0xE8404A, hub: 0x8E0D16)),
        entry("mini.silver", "MINI", "Silver", mini,
              IPodFinish(body: [0xF2F4F6, 0xCBD2D9, 0xA8B2BC], bezel: 0x8E979F, wheelC: whiteWheelC, wheelHi: whiteWheelHi, hub: whiteHub)),
        entry("mini.blue", "MINI", "Blue", mini,
              IPodFinish(body: [0xB4D2EC, 0x7AA8CF, 0x54819F], bezel: 0x4A7392, wheelC: whiteWheelC, wheelHi: whiteWheelHi, hub: whiteHub)),
        entry("mini.pink", "MINI", "Pink", mini,
              IPodFinish(body: [0xF6C4D8, 0xE39BB9, 0xBE7495], bezel: 0xA96684, wheelC: whiteWheelC, wheelHi: whiteWheelHi, hub: whiteHub)),
        entry("mini.green", "MINI", "Green", mini,
              IPodFinish(body: [0xCDE2BC, 0x9FC489, 0x7BA265], bezel: 0x6D9159, wheelC: whiteWheelC, wheelHi: whiteWheelHi, hub: whiteHub)),
        entry("mini.gold", "MINI", "Gold", mini,
              IPodFinish(body: [0xEFE2BE, 0xD3BC8B, 0xB29A67], bezel: 0x9E8857, wheelC: whiteWheelC, wheelHi: whiteWheelHi, hub: whiteHub)),
        entry("nano.silver", "NANO", "Silver", nano,
              IPodFinish(body: [0xF4F6F8, 0xCED5DB, 0xABB5BF], bezel: 0x8E979F, wheelC: whiteWheelC, wheelHi: whiteWheelHi, hub: whiteHub)),
        entry("nano.black", "NANO", "Black", nano,
              IPodFinish(body: [0x3E4147, 0x1E2024, 0x0E0F12], bezel: 0x0B0C0E, wheelC: 0x26282D, wheelHi: 0x4A4E55, hub: 0x151619)),
        entry("nano.blue", "NANO", "Blue", nano,
              IPodFinish(body: [0xA8CDEE, 0x699FD4, 0x4579A8], bezel: 0x3D6B95, wheelC: whiteWheelC, wheelHi: whiteWheelHi, hub: whiteHub)),
        entry("nano.green", "NANO", "Green", nano,
              IPodFinish(body: [0xC6E59C, 0x92C55C, 0x6FA340], bezel: 0x639238, wheelC: whiteWheelC, wheelHi: whiteWheelHi, hub: whiteHub)),
        entry("nano.pink", "NANO", "Pink", nano,
              IPodFinish(body: [0xF8B7CD, 0xEC86AC, 0xC96389], bezel: 0xB4587B, wheelC: whiteWheelC, wheelHi: whiteWheelHi, hub: whiteHub)),
        entry("nano.red", "NANO", "Red", nano,
              IPodFinish(body: [0xEF6B66, 0xD23131, 0xA32121], bezel: 0x8E1D1D, wheelC: whiteWheelC, wheelHi: whiteWheelHi, hub: whiteHub))
    ]

    static func entry(for id: String?) -> IPodIconEntry? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    private static func entry(_ id: String, _ family: String, _ name: String, _ geo: IPodGeometry, _ finish: IPodFinish) -> IPodIconEntry {
        IPodIconEntry(id: id, family: family, finishName: name, geometry: geo, finish: finish)
    }

    // MARK: - Drawing (ported from ipodSVG)

    fileprivate static func draw(_ entry: IPodIconEntry, in ctx: GraphicsContext, size: CGSize) {
        let g = entry.geometry
        let f = entry.finish
        let k = size.width / g.w                       // uniform scale (aspect preserved)
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: x * k, y: y * k, width: w * k, height: h * k)
        }
        func color(_ hex: UInt32, _ o: Double = 1) -> Color { Color(hex: hex, opacity: o) }

        let W = g.w, H = g.h, R = g.radius
        let scrW = g.screenW, scrH = g.screenH, scrY = g.screenY, scrX = (W - scrW) / 2
        let whR = g.wheelR, whY = g.wheelCY, hubR = whR * 0.36

        // Body — anodized diagonal gradient with a dark edge.
        let bodyPath = Path(roundedRect: rect(1, 1, W - 2, H - 2), cornerRadius: R * k)
        ctx.fill(bodyPath, with: .linearGradient(Gradient(colors: f.body.map { color($0) }),
                                                 startPoint: P(0, 0), endPoint: P(W, H)))
        ctx.stroke(bodyPath, with: .color(color(0x000000, 0.35)), lineWidth: 1.5 * k)

        // Inner hairline highlight.
        ctx.stroke(Path(roundedRect: rect(2.5, 2.5, W - 5, H - 5), cornerRadius: (R - 1.5) * k),
                   with: .color(.white.opacity(0.35 * 0.6)), lineWidth: 1 * k)

        // Glossy top sweep.
        var gloss = Path()
        gloss.move(to: P(R, 2))
        gloss.addLine(to: P(W - R, 2))
        gloss.addQuadCurve(to: P(W - 2, R), control: P(W - 2, 2))
        gloss.addLine(to: P(W - 2, H * 0.34))
        gloss.addQuadCurve(to: P(2, H * 0.38), control: P(W / 2, H * 0.46))
        gloss.addLine(to: P(2, R))
        gloss.addQuadCurve(to: P(R, 2), control: P(2, 2))
        gloss.closeSubpath()
        ctx.fill(gloss, with: .linearGradient(
            Gradient(stops: [.init(color: .white.opacity(0.32), location: 0), .init(color: .white.opacity(0), location: 1)]),
            startPoint: P(0, 0), endPoint: P(0, H * 0.55)))

        // Screen bezel + glass.
        let bezelPath = Path(roundedRect: rect(scrX - 4, scrY - 4, scrW + 8, scrH + 8), cornerRadius: 6 * k)
        ctx.fill(bezelPath, with: .color(color(f.bezel)))
        ctx.stroke(bezelPath, with: .color(color(0x000000, 0.4)), lineWidth: 1 * k)

        let screenPath = Path(roundedRect: rect(scrX, scrY, scrW, scrH), cornerRadius: 3.5 * k)
        ctx.fill(screenPath, with: .linearGradient(
            Gradient(colors: [color(0x1B2530), color(0x0C1218), color(0x131E28)]),
            startPoint: P(scrX, scrY), endPoint: P(scrX + scrW, scrY + scrH)))

        // Screen diagonal sheen, clipped to the glass.
        var sheen = Path()
        sheen.move(to: P(scrX, scrY + scrH * 0.72))
        sheen.addLine(to: P(scrX + scrW * 0.55, scrY))
        sheen.addLine(to: P(scrX + scrW * 0.8, scrY))
        sheen.addLine(to: P(scrX + scrW * 0.25, scrY + scrH))
        sheen.addLine(to: P(scrX, scrY + scrH))
        sheen.closeSubpath()
        var screenCtx = ctx
        screenCtx.clip(to: screenPath)
        screenCtx.fill(sheen, with: .color(.white.opacity(0.05)))

        // Click wheel — radial anodized fill (mock: cx 0.38, cy 0.30, r 0.85).
        let whBox = CGRect(x: (W / 2 - whR) * k, y: (whY - whR) * k, width: whR * 2 * k, height: whR * 2 * k)
        let wheelPath = Path(ellipseIn: whBox)
        let whCenter = CGPoint(x: whBox.minX + whBox.width * 0.38, y: whBox.minY + whBox.height * 0.30)
        ctx.fill(wheelPath, with: .radialGradient(
            Gradient(colors: [color(f.wheelHi), color(f.wheelC)]),
            center: whCenter, startRadius: 0, endRadius: whR * 0.85 * 2 * k))
        ctx.stroke(wheelPath, with: .color(color(0x000000, 0.22)), lineWidth: 1 * k)

        let ringR = (whR - 1.5) * k
        ctx.stroke(Path(ellipseIn: CGRect(x: (W / 2) * k - ringR, y: whY * k - ringR, width: ringR * 2, height: ringR * 2)),
                   with: .color(.white.opacity(0.25 * 0.7)), lineWidth: 0.8 * k)

        // Center hub + specular dot.
        let hubRR = hubR * k
        let hubPath = Path(ellipseIn: CGRect(x: (W / 2) * k - hubRR, y: whY * k - hubRR, width: hubRR * 2, height: hubRR * 2))
        ctx.fill(hubPath, with: .color(color(f.hub)))
        ctx.stroke(hubPath, with: .color(color(0x000000, 0.28)), lineWidth: 1 * k)

        let hlR = hubR * 0.5 * k
        let hlC = P(W / 2 - hubR * 0.25, whY - hubR * 0.3)
        ctx.fill(Path(ellipseIn: CGRect(x: hlC.x - hlR, y: hlC.y - hlR, width: hlR * 2, height: hlR * 2)),
                 with: .color(.white.opacity(0.12)))
    }
}

/// A parametric iPod icon rendered to a target height (aspect preserved).
struct IPodIcon: View {
    let id: String
    var height: CGFloat = 56

    var body: some View {
        if let entry = IPodCatalog.entry(for: id) {
            Canvas { ctx, size in IPodCatalog.draw(entry, in: ctx, size: size) }
                .frame(width: entry.aspectWidth(forHeight: height), height: height)
        } else {
            Image(systemName: "externaldrive.fill")
                .font(.system(size: height * 0.42))
                .frame(width: height * 0.62, height: height)
                .foregroundStyle(.secondary)
        }
    }
}

private extension IPodIconEntry {
    func aspectWidth(forHeight height: CGFloat) -> CGFloat {
        geometry.w / geometry.h * height
    }
}

/// The add-device sheet's icon picker: a wrapping grid of 52×64 tappable tiles,
/// orange ring + tint on the selection. Tapping the selected tile clears it.
struct DeviceIconPicker: View {
    @Binding var selection: String?

    private static let orange = Color(hex: 0xFF6D3F)
    private let columns = [GridItem(.adaptive(minimum: 52, maximum: 52), spacing: 8, alignment: .leading)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(IPodCatalog.all) { entry in
                tile(entry)
            }
        }
    }

    private func tile(_ entry: IPodIconEntry) -> some View {
        let selected = selection == entry.id
        return Button {
            selection = selected ? nil : entry.id
        } label: {
            IPodIcon(id: entry.id, height: 48)
                .frame(width: 52, height: 64)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(selected ? Self.orange.opacity(0.08) : Color.white.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(selected ? Self.orange : .clear, lineWidth: 1)
                )
                .shadow(color: selected ? Self.orange.opacity(0.35) : .clear, radius: 8)
        }
        .buttonStyle(.plain)
        .help(entry.displayName)
    }
}
