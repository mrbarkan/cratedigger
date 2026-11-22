import Foundation

/// The numbers behind `SimplePaletteRecipe`: one table per appearance, each measured
/// from Carbon's own tokens of that appearance (`Carbon.cdtheme` over
/// `CarbonTheme.carbon` / `.linen`) against Carbon's six job colours. Offsets are OKLCH
/// lightness relative to the job colour; chroma is a multiple of the job's.
///
/// Which job each token follows:
/// - Frame: the chassis and its bevel, the keys (`metal…`), the desktop backdrop.
/// - Panels: the lists (`paper…`), the recessed well, the divider lines.
/// - Text: the four inks.
/// - Accent: the accent trio and the selected row's light (`selectionLedCore`,
///   `selectionGlow`, `selectionSpread`).
/// - Screen Glass / Screen Text: the display.
/// - Meaning colours keep Carbon's hue and chroma; only their lightness follows the
///   panels (or, for ON AIR, the glass).
/// - `selectionInk` is not in the table: it is chosen against the selection fills
///   once they exist (`SimplePaletteRecipe.selectionInk`).
/// - `rowAlt` stays clear, as in every built-in.
///
/// Where the numbers are not a measurement:
/// - `oledForegroundMuted` is the phosphor itself at Carbon's 55%, not white: a green
///   or amber screen should dim to green or amber.
/// - The light frame's highlights (`chassisHi`, `metalHi`) sit 0.06 above the frame
///   and keep half its chroma. Carbon's are white because its frame is nearly white;
///   measured literally, a cream or grey frame would get a grey highlight barely
///   lighter than itself. On Carbon's own frame they still come out white.
/// - The dark selection keeps the accent's hue rather than Carbon's teal (above).
///
/// The bands are wide enough to keep the hand-made themes' own choices (Nord-style
/// panels lighter than the frame, Pocket's violet frame) and narrow enough that text,
/// accent and surfaces always land where the appearance needs them. Pure black text in
/// light is lifted to Carbon's ink so the secondary inks still have room below it.
struct SimplePaletteRecipeTable: Sendable {
    let ranges: [ThemeJob: JobRange]
    let tokens: [String: TokenTransform]
    /// Which side of the frame the panels sit on when the palette does not say:
    /// darker (-1) or lighter (+1).
    let panelsSide: Double

    // MARK: Dark

    static let dark = SimplePaletteRecipeTable(
        ranges: [
            .frame: JobRange(0.12...0.45, reference: 0.2240, fallback: "#171C22"),
            .panels: JobRange(0.10...0.40, reference: 0.2059, fallback: "#111820"),
            .text: JobRange(0.85...1.00, reference: 0.9731, fallback: "#F3F7F7"),
            .accent: JobRange(0.55...0.90, reference: 0.7080, fallback: "#FF6D3F"),
            .glass: JobRange(0.00...0.30, reference: 0.1142, fallback: "#050504"),
            .screenText: JobRange(0.80...1.00, reference: 0.9582, fallback: "#F5F1E6"),
        ],
        tokens: [
            "chassis": .derived(.frame, dL: 0, chroma: 1),
            "chassisHi": .derived(.frame, dL: 0.1004, chroma: 1.714),
            "chassisLo": .derived(.frame, dL: -0.0570, chroma: 0.698),
            "chassisDeep": .derived(.frame, dL: -0.0969, chroma: 0.633),
            "metalHi": .derived(.frame, dL: 0.2651, chroma: 1.486),
            "metal": .derived(.frame, dL: 0.1189, chroma: 1.488),
            "metalLo": .derived(.frame, dL: -0.0087, chroma: 1.010),
            "metalDeep": .derived(.frame, dL: -0.0969, chroma: 0.633),
            "backgroundBase": .derived(.frame, dL: -0.0797, chroma: 0.677),
            "backgroundGradientStart": .derived(.frame, dL: 0.0260, chroma: 1.660),
            "backgroundGradientEnd": .derived(.frame, dL: -0.1180, chroma: 0.566),

            "paper": .derived(.panels, dL: 0, chroma: 1),
            "paper2": .derived(.panels, dL: -0.0440, chroma: 0.648),
            "well": .derived(.panels, dL: 0.0078, chroma: 1.033),
            "wellDeep": .derived(.panels, dL: -0.0628, chroma: 0.540),
            "hair": .derived(.panels, dL: 0.1073, chroma: 1.240),
            "rowAlt": .constant("#00000000"),

            "ink": .derived(.text, dL: 0, chroma: 1),
            "ink2": .derived(.text, dL: -0.1108, chroma: 3.477, hierarchy: true),
            "ink3": .derived(.text, dL: -0.3230, chroma: 5.365, hierarchy: true),
            "ink4": .derived(.text, dL: -0.4812, chroma: 5.067, hierarchy: true),

            "orange": .derived(.accent, dL: 0, chroma: 1),
            "orangeHi": .derived(.accent, dL: 0.0861, chroma: 0.658, hue: 3.7),
            "orangeLo": .derived(.accent, dL: -0.1024, chroma: 0.976, hue: -1.9),
            // Carbon's dark selection is a cool teal against its warm accent. Its
            // lightness, chroma and alpha are kept; its 156° hue offset is not, or a
            // blue accent would get an orange selection.
            "selectionLedCore": .derived(.accent, dL: 0.2065, chroma: 0.723),
            "selectionGlow": .derived(.accent, dL: 0.0489, chroma: 0.598),
            "selectionSpread": .derived(.accent, dL: 0.2065, chroma: 0.723, alpha: 0.553),

            "sun": .meaning(l: 0.8542, c: 0.1417, h: 89.3, on: .panels, follow: 0.3),
            "sunHi": .meaning(l: 0.9315, c: 0.1067, h: 94.6, on: .panels, follow: 0.3),
            "sunLo": .meaning(l: 0.7164, c: 0.1305, h: 86.6, on: .panels, follow: 0.3),
            "cyan": .meaning(l: 0.7570, c: 0.1127, h: 187.8, on: .panels, follow: 0.3),
            "cyanGlow": .meaning(l: 0.9288, c: 0.0552, h: 189.2, on: .panels, follow: 0.3),
            "red": .meaning(l: 0.6477, c: 0.1860, h: 27.0, on: .panels, follow: 0.3),
            "indigo": .meaning(l: 0.6413, c: 0.1528, h: 274.6, on: .panels, follow: 0.3),

            "oledSurface": .derived(.glass, dL: 0, chroma: 1),
            "oledStrokeInner": .derived(.glass, dL: 0.0487, chroma: 1.148),
            "oledSurfaceShade": .constant("#00000047"),
            "oledForeground": .derived(.screenText, dL: 0, chroma: 1),
            "oledForegroundMuted": .derived(.screenText, dL: 0, chroma: 1, alpha: 0.549),
            "onAir": .meaning(l: 0.6872, c: 0.2023, h: 29.2, on: .glass, follow: 0.3),
        ],
        panelsSide: -1
    )

    // MARK: Light

    static let light = SimplePaletteRecipeTable(
        ranges: [
            .frame: JobRange(0.78...1.00, reference: 0.9774, fallback: "#F5F8FA"),
            .panels: JobRange(0.85...1.00, reference: 0.9898, fallback: "#FAFCFD"),
            .text: JobRange(0.10...0.32, reference: 0.2017, fallback: "#12171C"),
            .accent: JobRange(0.40...0.72, reference: 0.6933, fallback: "#FF6236"),
            .glass: JobRange(0.00...0.30, reference: 0.1448, fallback: "#0A0A0A"),
            .screenText: JobRange(0.80...1.00, reference: 0.9582, fallback: "#F5F1E6"),
        ],
        tokens: [
            "chassis": .derived(.frame, dL: 0, chroma: 1),
            "chassisHi": .derived(.frame, dL: 0.0600, chroma: 0.5),
            "chassisLo": .derived(.frame, dL: -0.0741, chroma: 2.901),
            "chassisDeep": .derived(.frame, dL: -0.2485, chroma: 4.320),
            "metalHi": .derived(.frame, dL: 0.0600, chroma: 0.5),
            "metal": .derived(.frame, dL: -0.0536, chroma: 3.114),
            "metalLo": .derived(.frame, dL: -0.2004, chroma: 4.432),
            "metalDeep": .derived(.frame, dL: -0.4515, chroma: 5.063),
            "backgroundBase": .derived(.frame, dL: -0.0523, chroma: 3.471),
            "backgroundGradientStart": .derived(.frame, dL: -0.0025, chroma: 1.562),
            "backgroundGradientEnd": .derived(.frame, dL: -0.1059, chroma: 4.973),

            "paper": .derived(.panels, dL: 0, chroma: 1),
            "paper2": .derived(.panels, dL: -0.0264, chroma: 3.013),
            "well": .derived(.panels, dL: -0.0369, chroma: 3.763),
            "wellDeep": .derived(.panels, dL: -0.1252, chroma: 6.261),
            "hair": .derived(.panels, dL: -0.1330, chroma: 5.520),
            "rowAlt": .constant("#00000000"),

            "ink": .derived(.text, dL: 0, chroma: 1),
            "ink2": .derived(.text, dL: 0.1542, chroma: 1.833, hierarchy: true),
            "ink3": .derived(.text, dL: 0.3514, chroma: 2.030, hierarchy: true),
            "ink4": .derived(.text, dL: 0.5118, chroma: 1.357, hierarchy: true),

            "orange": .derived(.accent, dL: 0, chroma: 1),
            "orangeHi": .derived(.accent, dL: 0.0804, chroma: 0.691, hue: 4.2),
            "orangeLo": .derived(.accent, dL: -0.1004, chroma: 0.949, hue: -1.3),
            "selectionLedCore": .derived(.accent, dL: 0.1008, chroma: 0.620, hue: 5.3),
            "selectionGlow": .derived(.accent, dL: 0.0342, chroma: 0.866, hue: 2.8),
            "selectionSpread": .derived(.accent, dL: 0, chroma: 1),

            "sun": .meaning(l: 0.8494, c: 0.1476, h: 89.2, on: .panels, follow: 0.3),
            "sunHi": .meaning(l: 0.9240, c: 0.1147, h: 93.9, on: .panels, follow: 0.3),
            "sunLo": .meaning(l: 0.7204, c: 0.1321, h: 86.3, on: .panels, follow: 0.3),
            "cyan": .meaning(l: 0.6767, c: 0.0996, h: 208.9, on: .panels, follow: 0.3),
            "cyanGlow": .meaning(l: 0.9164, c: 0.0504, h: 202.5, on: .panels, follow: 0.3),
            "red": .meaning(l: 0.6176, c: 0.1930, h: 27.3, on: .panels, follow: 0.3),
            "indigo": .meaning(l: 0.5615, c: 0.1480, h: 265.8, on: .panels, follow: 0.3),

            "oledSurface": .derived(.glass, dL: 0, chroma: 1),
            "oledStrokeInner": .derived(.glass, dL: 0.0730, chroma: 1),
            "oledSurfaceShade": .constant("#00000047"),
            "oledForeground": .derived(.screenText, dL: 0, chroma: 1),
            "oledForegroundMuted": .derived(.screenText, dL: 0, chroma: 1, alpha: 0.549),
            "onAir": .meaning(l: 0.6872, c: 0.2023, h: 29.2, on: .glass, follow: 0.3),
        ],
        panelsSide: 1
    )

    // MARK: Pale glass

    /// A glass at or above 0.5 lightness is an LCD, measured from Pocket's light layer
    /// (the one hand-made pale screen): the bands for the glass and its dark text, and
    /// the screen tokens that replace the appearance's own.
    static let paleGlassRange = JobRange(0.70...0.95, reference: 0.7857, fallback: "#B7BBB0")
    static let paleScreenTextRange = JobRange(0.00...0.35, reference: 0.2533, fallback: "#1F2326")

    static let paleGlassTokens: [String: TokenTransform] = [
        // A dark bezel round a pale glass, as on a handheld.
        "oledStrokeInner": .derived(.glass, dL: -0.3092, chroma: 1),
        // The depth wash a pale glass gets by default in `CarbonTheme`.
        "oledSurfaceShade": .constant("#0000000F"),
        "oledForegroundMuted": .derived(.screenText, dL: 0, chroma: 1, alpha: 0.651),
        // ON AIR stays red, dark enough to read on the pale glass.
        "onAir": .meaning(l: 0.5000, c: 0.2023, h: 29.2, on: .glass, follow: 0.3),
    ]
}
