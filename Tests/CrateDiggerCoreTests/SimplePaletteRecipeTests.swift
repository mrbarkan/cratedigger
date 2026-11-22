import XCTest
@testable import CrateDiggerCore

/// The Simple recipe: six job colours in, every Simple-owned colour token out, with the
/// contrast floors holding whatever the palette. Carbon is the reference: its own job
/// colours must give back Carbon.
final class SimplePaletteRecipeTests: XCTestCase {
    typealias Appearance = ThemeDefinition.BaseAppearance

    // MARK: Carbon reference

    /// Carbon's job colours, read the way the extractor reads them (`chassis`, `paper`,
    /// `ink`, `orange`, `oledSurface`, `oledForeground`).
    static let carbonJobs: [Appearance: [ThemeJob: String]] = [
        .dark: [.frame: "#171C22", .panels: "#111820", .text: "#F3F7F7",
                .accent: "#FF6D3F", .glass: "#050504", .screenText: "#F5F1E6"],
        .light: [.frame: "#F5F8FA", .panels: "#FAFCFD", .text: "#12171C",
                 .accent: "#FF6236", .glass: "#0A0A0A", .screenText: "#F5F1E6"],
    ]

    /// Carbon's resolved colour tokens per appearance: `Carbon.cdtheme` (shared colours
    /// plus the appearance's layer) over `CarbonTheme.carbon` / `.linen`. `rowAlt` is
    /// `.clear`; `oledSurfaceShade` is black at 28%; dark `selectionGlow` comes from
    /// `CarbonTheme.carbon`, the theme file sets the rest of the selection. Carbon sets
    /// no `accentInk`, so its keys print in `selectionInk`.
    static let carbonTokens: [Appearance: [String: String]] = [
        .dark: [
            "chassis": "#171C22", "chassisHi": "#2B3540", "chassisLo": "#0C0F13", "chassisDeep": "#05070A",
            "well": "#121A22", "wellDeep": "#070A0E", "paper": "#111820", "paper2": "#0A0E13",
            "rowAlt": "#00000000",
            "ink": "#F3F7F7", "ink2": "#C8D4D9", "ink3": "#82929B", "ink4": "#56636C", "hair": "#26333C",
            "orange": "#FF6D3F", "orangeHi": "#FFA07C", "orangeLo": "#D94C25",
            "sun": "#F4CA54", "sunHi": "#FFE894", "sunLo": "#C79D30",
            "cyan": "#45C7BD", "cyanGlow": "#BEF4EF", "red": "#EA554C", "indigo": "#7282E8",
            "metalHi": "#56626B", "metal": "#303A43", "metalLo": "#151A20", "metalDeep": "#05070A",
            "backgroundBase": "#080A0E", "backgroundGradientStart": "#18232C", "backgroundGradientEnd": "#030406",
            "oledSurface": "#050504", "oledSurfaceShade": "#00000047", "oledStrokeInner": "#0E0E0C",
            "oledForeground": "#F5F1E6", "oledForegroundMuted": "#FFFFFF8C", "onAir": "#FF5B4A",
            "selectionLedCore": "#56FFFD", "selectionGlow": "#45C7BD", "selectionSpread": "#56FFFD8D",
            "selectionInk": "#FFFFFF", "accentInk": "#FFFFFF",
        ],
        .light: [
            "chassis": "#F5F8FA", "chassisHi": "#FFFFFF", "chassisLo": "#D7E1E5", "chassisDeep": "#9CAAB0",
            "well": "#E9F1F4", "wellDeep": "#C8D5DA", "paper": "#FAFCFD", "paper2": "#EEF4F7",
            "rowAlt": "#00000000",
            "ink": "#12171C", "ink2": "#313E47", "ink3": "#657580", "ink4": "#98A5AB", "hair": "#C7D2D7",
            "orange": "#FF6236", "orangeHi": "#FF956F", "orangeLo": "#D7441E",
            "sun": "#F4C84A", "sunHi": "#FFE58A", "sunLo": "#C99E2F",
            "cyan": "#3AA8B8", "cyanGlow": "#BDEEF2", "red": "#E2473F", "indigo": "#4B6FCB",
            "metalHi": "#FFFFFF", "metal": "#DDE8EC", "metalLo": "#ABB9C0", "metalDeep": "#5F6D75",
            "backgroundBase": "#DCE9EC", "backgroundGradientStart": "#F2F8F9", "backgroundGradientEnd": "#C7D8DF",
            "oledSurface": "#0A0A0A", "oledSurfaceShade": "#00000047", "oledStrokeInner": "#1A1A1A",
            "oledForeground": "#F5F1E6", "oledForegroundMuted": "#FFFFFF8C", "onAir": "#FF5B4A",
            "selectionLedCore": "#FFA07C", "selectionGlow": "#FF7A4D", "selectionSpread": "#FF6236",
            "selectionInk": "#FFFFFF", "accentInk": "#FFFFFF",
        ],
    ]

    /// Tokens Carbon itself sets in a way the recipe deliberately does not follow, each
    /// with its reason. Everything else must land within 0.06 OKLab of Carbon.
    static let closenessExceptions: [Appearance: [String: String]] = [
        .dark: [
            // Carbon's dark selection is teal against an orange accent. Simple's
            // follows the accent (keeping Carbon's lightness, chroma and alpha), or a
            // blue-accent theme would get a teal or orange selection it never chose.
            "selectionLedCore": "follows the accent's hue, not Carbon's teal",
            "selectionGlow": "follows the accent's hue, not Carbon's teal",
            "selectionSpread": "follows the accent's hue, not Carbon's teal",
            // White is 2.8:1 on Carbon's orange key fill, which never moves.
            "accentInk": "white fails 4.5 on the accent",
        ],
        .light: [
            // White is about 1:1 on the panel a selected row fades out onto, and 2.6:1
            // on Carbon's orange wash; Simple's light selectionInk is the dark end.
            "selectionInk": "white fails 4.5 on the light panel",
            // White is 3.0:1 on Carbon's orange key fill.
            "accentInk": "white fails 4.5 on the accent",
        ],
    ]

    static func jobs(_ hexes: [ThemeJob: String]) -> [ThemeJob: PaletteColor] {
        hexes.mapValues { PaletteColor(hex: $0)! }
    }

    static func carbon(_ appearance: Appearance, contrast: SimpleContrast = .standard) -> [String: String] {
        SimplePaletteRecipe.tokens(jobColors: jobs(carbonJobs[appearance]!), contrast: contrast,
                                   appearance: appearance)
    }

    // MARK: Carbon

    func testCarbonJobsReproduceCarbonAnchors() {
        for appearance in [Appearance.dark, .light] {
            let tokens = Self.carbon(appearance)
            let carbon = Self.carbonTokens[appearance]!
            for key in ["ink", "orange", "oledSurface", "oledForeground"] {
                XCTAssertEqual(tokens[key], carbon[key], "\(appearance) \(key)")
            }
            // Carbon's frame and panels are 0.019 (dark) and 0.013 (light) apart in
            // OKLab, under the 0.04 every Simple theme keeps between them. The floor
            // wins, so these two anchors move apart a little instead of exactly.
            for key in ["chassis", "paper"] {
                let d = PaletteColor(hex: tokens[key]!)!.distance(to: PaletteColor(hex: carbon[key]!)!)
                XCTAssertLessThanOrEqual(d, 0.02, "\(appearance) \(key) \(tokens[key]!) vs \(carbon[key]!)")
            }
        }
    }

    func testCarbonJobsCloseToCarbonEverywhere() {
        for appearance in [Appearance.dark, .light] {
            let tokens = Self.carbon(appearance)
            let carbon = Self.carbonTokens[appearance]!
            let exceptions = Self.closenessExceptions[appearance] ?? [:]
            XCTAssertEqual(Set(tokens.keys), Set(carbon.keys), "the reference covers every written token")
            for (key, hex) in tokens where exceptions[key] == nil {
                guard let reference = carbon[key] else { continue }
                let ours = PaletteColor(hex: hex)!, theirs = PaletteColor(hex: reference)!
                XCTAssertLessThanOrEqual(ours.distance(to: theirs), 0.06,
                                         "\(appearance) \(key): \(hex) vs Carbon \(reference)")
                XCTAssertEqual(ours.a, theirs.a, accuracy: 0.02, "\(appearance) \(key) alpha")
            }
        }
    }

    // MARK: Floors

    func testFloorsHoldForSeededPalettes() {
        var rng = SplitMix64(seed: 0x5EED)
        for _ in 0..<500 {
            var jobs: [ThemeJob: PaletteColor] = [:]
            for job in ThemeJob.allCases {
                jobs[job] = PaletteColor(r: rng.unit(), g: rng.unit(), b: rng.unit())
            }
            for appearance in [Appearance.dark, .light] {
                for contrast in SimpleContrast.allCases {
                    let tokens = SimplePaletteRecipe.tokens(jobColors: jobs, contrast: contrast,
                                                            appearance: appearance)
                    assertFloorsHold(tokens, contrast: contrast, "\(appearance) \(contrast) \(jobs.mapValues(\.hex))")
                    let table = appearance == .dark ? SimplePaletteRecipeTable.dark : SimplePaletteRecipeTable.light
                    if table.ranges[.accent]!.range.contains(jobs[.accent]!.oklch.l) {
                        XCTAssertEqual(tokens["orange"], jobs[.accent]!.hex, "the accent never moves")
                    }
                    let label = "\(appearance) \(contrast) \(jobs.mapValues(\.hex))"
                    assertFrameAndPanelsSeparate(tokens, label)
                    assertSelectedRowTitlesRead(tokens, appearance: appearance, label)
                }
            }
        }
    }

    func testHostileNearIdenticalPalette() {
        // All one hue, a hair apart; and two greys 2% apart, used for every job.
        let oneHue: [ThemeJob: String] = [.frame: "#3A5A8A", .panels: "#3B5B8B", .text: "#3A5A8C",
                                          .accent: "#3C5C8A", .glass: "#3A5A89", .screenText: "#395A8A"]
        let twoGreys: [ThemeJob: String] = [.frame: "#808080", .panels: "#858585", .text: "#808080",
                                            .accent: "#858585", .glass: "#808080", .screenText: "#858585"]
        let darkGreys: [ThemeJob: String] = [.frame: "#2A2A2A", .panels: "#2F2F2F", .text: "#2A2A2A",
                                             .accent: "#2F2F2F", .glass: "#2A2A2A", .screenText: "#2F2F2F"]
        let paleGreys: [ThemeJob: String] = [.frame: "#F0F0F0", .panels: "#F5F5F5", .text: "#F0F0F0",
                                             .accent: "#F5F5F5", .glass: "#F0F0F0", .screenText: "#F5F5F5"]
        for palette in [oneHue, twoGreys, darkGreys, paleGreys] {
            assertHostileSurvives(Self.jobs(palette))
        }
    }

    func testHostileBlackWhite() {
        let black = "#000000", white = "#FFFFFF"
        let palettes: [[ThemeJob: String]] = [
            [.frame: black, .panels: white, .text: black, .accent: white, .glass: black, .screenText: white],
            [.frame: white, .panels: black, .text: white, .accent: black, .glass: white, .screenText: black],
            [.frame: black, .panels: black, .text: black, .accent: black, .glass: black, .screenText: black],
            [.frame: white, .panels: white, .text: white, .accent: white, .glass: white, .screenText: white],
        ]
        for palette in palettes { assertHostileSurvives(Self.jobs(palette)) }
    }

    func testHostileNeon() {
        let palettes: [[ThemeJob: String]] = [
            [.frame: "#FF00FF", .panels: "#00FFFF", .text: "#FFFF00",
             .accent: "#39FF14", .glass: "#FF0000", .screenText: "#0000FF"],
            [.frame: "#39FF14", .panels: "#FF00FF", .text: "#0000FF",
             .accent: "#FFFF00", .glass: "#00FFFF", .screenText: "#FF0000"],
            [.frame: "#FF00FF", .panels: "#FF00FF", .text: "#FF00FF",
             .accent: "#FF00FF", .glass: "#FF00FF", .screenText: "#FF00FF"],
        ]
        for palette in palettes { assertHostileSurvives(Self.jobs(palette)) }
    }

    // MARK: Meaning colours, overrides, determinism

    func testMeaningColoursKeepHue() {
        var rng = SplitMix64(seed: 7)
        let meaning = ["red", "sun", "sunHi", "sunLo", "cyan", "cyanGlow", "indigo", "onAir"]
        for _ in 0..<300 {
            var jobs: [ThemeJob: PaletteColor] = [:]
            for job in ThemeJob.allCases { jobs[job] = PaletteColor(r: rng.unit(), g: rng.unit(), b: rng.unit()) }
            for appearance in [Appearance.dark, .light] {
                let tokens = SimplePaletteRecipe.tokens(jobColors: jobs, contrast: .standard, appearance: appearance)
                for key in meaning {
                    let ours = PaletteColor(hex: tokens[key]!)!.oklch
                    let carbon = PaletteColor(hex: Self.carbonTokens[appearance]![key]!)!.oklch
                    XCTAssertGreaterThan(ours.c, 0.03, "\(appearance) \(key) keeps its colour")
                    XCTAssertLessThanOrEqual(hueDistance(ours.h, carbon.h), 20, "\(appearance) \(key)")
                }
            }
        }
    }

    func testNoOverrideTokensWritten() {
        let overrides: Set<String> = [
            "lampNow", "lampConvert", "lampScan", "lampSync", "lampCD", "lampDevices", "lampSearch",
            "lampStats", "transportLamp", "keyLamp", "meterHot", "chassisInk", "columnHeaderInk",
        ]
        XCTAssertTrue(SimplePaletteRecipe.simpleWrittenTokens.isDisjoint(with: overrides))
        // Non-optional tokens are written, or an inherited theme's selection shows through.
        // `accentInk` is an override written on purpose: accent keys need their own print.
        XCTAssertTrue(SimplePaletteRecipe.simpleWrittenTokens.isSuperset(of: [
            "selectionLedCore", "selectionGlow", "selectionSpread", "selectionInk", "accentInk",
        ]))
        for key in SimplePaletteRecipe.simpleWrittenTokens {
            XCTAssertFalse(key.hasPrefix("lamp"), key)
            XCTAssertFalse(key.hasSuffix("Lamp"), key)
        }
        for appearance in [Appearance.dark, .light] {
            XCTAssertTrue(Set(Self.carbon(appearance).keys).isDisjoint(with: overrides))
        }
    }

    func testWrittenKeysAreExactlySimpleWrittenTokens() {
        var rng = SplitMix64(seed: 11)
        for _ in 0..<50 {
            var jobs: [ThemeJob: PaletteColor] = [:]
            for job in ThemeJob.allCases { jobs[job] = PaletteColor(r: rng.unit(), g: rng.unit(), b: rng.unit()) }
            for appearance in [Appearance.dark, .light] {
                let tokens = SimplePaletteRecipe.tokens(jobColors: jobs, contrast: .high, appearance: appearance)
                XCTAssertEqual(Set(tokens.keys), SimplePaletteRecipe.simpleWrittenTokens)
                for hex in tokens.values { XCTAssertNotNil(PaletteColor(hex: hex), hex) }
            }
        }
    }

    func testReviewCaseLightRowTitleOnBlueWash() {
        // A deep blue accent over grey surfaces put light-mode `ink` at 3.8:1 on the wash.
        let jobs = Self.jobs([.frame: "#9A9A9A", .panels: "#B5B5B5", .text: "#2A2A2A",
                              .accent: "#2F6BEA", .glass: "#101010", .screenText: "#F0F0F0"])
        for contrast in SimpleContrast.allCases {
            let tokens = SimplePaletteRecipe.tokens(jobColors: jobs, contrast: contrast, appearance: .light)
            assertSelectedRowTitlesRead(tokens, appearance: .light, "\(contrast)")
            assertFloorsHold(tokens, contrast: contrast, "\(contrast)")
        }
    }

    func testReviewCaseSeparationSurvivesTheFloors() {
        // High contrast pushes this dark panel toward the frame; the frame steps away again.
        // (#464646 sits just inside the dark panel band; #484848 would be snapped down.)
        let jobs = Self.jobs([.frame: "#3A3A3A", .panels: "#464646", .text: "#E8E8E8",
                              .accent: "#FF6D3F", .glass: "#050504", .screenText: "#F5F1E6"])
        for contrast in SimpleContrast.allCases {
            let tokens = SimplePaletteRecipe.tokens(jobColors: jobs, contrast: contrast, appearance: .dark)
            assertFrameAndPanelsSeparate(tokens, "\(contrast)")
            assertFloorsHold(tokens, contrast: contrast, "\(contrast)")
        }
    }

    /// One fixed palette, every token pinned, so a change to the table or the rules
    /// shows up as a diff here rather than unnoticed. Update deliberately.
    func testGoldenTokens() {
        let jobs = Self.jobs([.frame: "#2E3440", .panels: "#3B4252", .text: "#ECEFF4",
                              .accent: "#88C0D0", .glass: "#1B1F27", .screenText: "#A3BE8C"])
        let golden: [Appearance: [String: String]] = [
            .dark: [
                "accentInk": "#090D16", "backgroundBase": "#1D2028", "backgroundGradientEnd": "#14171E",
                "backgroundGradientStart": "#313B4D", "chassis": "#2E3440", "chassisDeep": "#191C23",
                "chassisHi": "#454E62", "chassisLo": "#22262E", "cyan": "#59D8CE", "cyanGlow": "#D6FFFB",
                "hair": "#565F74", "indigo": "#8192FA", "ink": "#ECEFF4", "ink2": "#C4CBD8", "ink3": "#868D99",
                "ink4": "#555B66", "metal": "#4A5467", "metalDeep": "#191C23", "metalHi": "#737D92",
                "metalLo": "#2C323E", "oledForeground": "#E0FCC8", "oledForegroundMuted": "#E0FCC88C",
                "oledStrokeInner": "#262B34", "oledSurface": "#1B1F27", "oledSurfaceShade": "#00000047",
                "onAir": "#FF7664", "orange": "#88C0D0", "orangeHi": "#B5D8E4", "orangeLo": "#69A0AE",
                "paper": "#3B4252", "paper2": "#323741", "red": "#FD665C", "rowAlt": "#00000000",
                "selectionGlow": "#ABCCD5", "selectionInk": "#FFFFFF", "selectionLedCore": "#EFFBFF",
                "selectionSpread": "#A2ADB18D", "sun": "#FFDD81", "sunHi": "#FFF5D2", "sunLo": "#D8AD44",
                "well": "#3D4455", "wellDeep": "#2E323A",
            ],
            .light: [
                "accentInk": "#090D16", "backgroundBase": "#D5E1F9", "backgroundGradientEnd": "#C4CFE7",
                "backgroundGradientStart": "#EAF1FF", "chassis": "#EBF2FF", "chassisDeep": "#97A2B8",
                "chassisHi": "#FFFFFF", "chassisLo": "#CEDAF1", "cyan": "#3BA9B9", "cyanGlow": "#BEEFF3",
                "hair": "#C7D3EF", "indigo": "#4C70CC", "ink": "#14161A", "ink2": "#383C43", "ink3": "#6D737C",
                "ink4": "#9FA3A9", "metal": "#D4E0F8", "metalDeep": "#5C667A", "metalHi": "#FFFFFF",
                "metalLo": "#A6B1C8", "oledForeground": "#E0FCC8", "oledForegroundMuted": "#E0FCC88C",
                "oledStrokeInner": "#2D3139", "oledSurface": "#1B1F27", "oledSurfaceShade": "#00000047",
                "onAir": "#FF705E", "orange": "#6FA6B6", "orangeHi": "#98BCC9", "orangeLo": "#538795",
                "paper": "#FFFFFF", "paper2": "#F2F6FF", "red": "#E34840", "rowAlt": "#00000000",
                "selectionGlow": "#81AFBF", "selectionInk": "#101215", "selectionLedCore": "#A2C2CE",
                "selectionSpread": "#6FA6B6", "sun": "#F5C94B", "sunHi": "#FFE690", "sunLo": "#CA9F30",
                "well": "#EDF3FF", "wellDeep": "#C9D6F2",
            ],
        ]
        for appearance in [Appearance.dark, .light] {
            let tokens = SimplePaletteRecipe.tokens(jobColors: jobs, contrast: .standard, appearance: appearance)
            let expected = golden[appearance]!
            XCTAssertEqual(Set(tokens.keys), Set(expected.keys))
            for key in expected.keys.sorted() {
                XCTAssertEqual(tokens[key], expected[key], "\(appearance) \(key)")
            }
        }
    }

    func testDeterministic() {
        let jobs = Self.jobs([.frame: "#2E3440", .panels: "#3B4252", .text: "#ECEFF4",
                              .accent: "#88C0D0", .glass: "#1B1F27", .screenText: "#A3BE8C"])
        for appearance in [Appearance.dark, .light] {
            for contrast in SimpleContrast.allCases {
                let a = SimplePaletteRecipe.tokens(jobColors: jobs, contrast: contrast, appearance: appearance)
                let b = SimplePaletteRecipe.tokens(jobColors: jobs, contrast: contrast, appearance: appearance)
                XCTAssertEqual(a, b)
            }
        }
    }

    func testMissingJobFallsBackWithoutCrashing() {
        for appearance in [Appearance.dark, .light] {
            let tokens = SimplePaletteRecipe.tokens(jobColors: [:], contrast: .standard, appearance: appearance)
            XCTAssertEqual(Set(tokens.keys), SimplePaletteRecipe.simpleWrittenTokens)
            assertFloorsHold(tokens, contrast: .standard, "\(appearance) empty")
        }
    }

    // MARK: Appearance and glass

    func testOneColourBuildsBothAppearances() {
        // A cream panel colour is the panel in Light and a deep cream-tinted panel in Dark.
        let jobs = Self.jobs([.frame: "#D8D0BC", .panels: "#F2EAD3", .text: "#2B2620",
                              .accent: "#C8553D", .glass: "#141210", .screenText: "#F2EAD3"])
        let light = SimplePaletteRecipe.tokens(jobColors: jobs, contrast: .standard, appearance: .light)
        let dark = SimplePaletteRecipe.tokens(jobColors: jobs, contrast: .standard, appearance: .dark)
        XCTAssertEqual(light["paper"], "#F2EAD3")
        let darkPaper = PaletteColor(hex: dark["paper"]!)!.oklch
        let cream = PaletteColor(hex: "#F2EAD3")!.oklch
        XCTAssertLessThan(darkPaper.l, 0.35)
        XCTAssertLessThanOrEqual(hueDistance(darkPaper.h, cream.h), 5)
    }

    func testPaleGlassKeepsDarkScreenText() {
        // An LCD-style screen (Pocket's light layer): pale glass, dark phosphor.
        let jobs = Self.jobs([.frame: "#C9C6BE", .panels: "#E4E1DA", .text: "#1B1B22",
                              .accent: "#A12A5E", .glass: "#B7BBB0", .screenText: "#1F2326"])
        for appearance in [Appearance.dark, .light] {
            let tokens = SimplePaletteRecipe.tokens(jobColors: jobs, contrast: .standard, appearance: appearance)
            XCTAssertEqual(tokens["oledSurface"], "#B7BBB0", "\(appearance)")
            XCTAssertEqual(tokens["oledForeground"], "#1F2326", "\(appearance)")
            let glass = PaletteColor(hex: tokens["oledSurface"]!)!
            let bezel = PaletteColor(hex: tokens["oledStrokeInner"]!)!
            XCTAssertLessThan(bezel.oklch.l, glass.oklch.l, "a pale glass gets a darker bezel")
            XCTAssertEqual(PaletteColor(hex: tokens["oledSurfaceShade"]!)!.a, 0.06, accuracy: 0.005)
            assertFloorsHold(tokens, contrast: .standard, "\(appearance) pale glass")
        }
    }

    func testHighContrastTightensTheTextHierarchy() {
        for appearance in [Appearance.dark, .light] {
            func gap(_ contrast: SimpleContrast) -> Double {
                let tokens = Self.carbon(appearance, contrast: contrast)
                return abs(PaletteColor(hex: tokens["ink"]!)!.oklch.l - PaletteColor(hex: tokens["ink3"]!)!.oklch.l)
            }
            XCTAssertLessThan(gap(.high), gap(.standard), "\(appearance)")
            XCTAssertGreaterThan(gap(.soft), gap(.standard), "\(appearance)")
        }
    }

    func testSelectionFollowsTheAccent() {
        // A blue accent over Carbon's other jobs: no orange or teal selection left over.
        for appearance in [Appearance.dark, .light] {
            var hexes = Self.carbonJobs[appearance]!
            hexes[.accent] = appearance == .dark ? "#4C8DFF" : "#2F6BEA"
            let tokens = SimplePaletteRecipe.tokens(jobColors: Self.jobs(hexes), contrast: .standard,
                                                    appearance: appearance)
            let accentHue = PaletteColor(hex: hexes[.accent]!)!.oklch.h
            for key in ["selectionLedCore", "selectionGlow", "selectionSpread"] {
                let lch = PaletteColor(hex: tokens[key]!)!.oklch
                XCTAssertLessThanOrEqual(hueDistance(lch.h, accentHue), 15, "\(appearance) \(key) \(tokens[key]!)")
            }
        }
    }

    func testSelectionInkFollowsTheAppearance() {
        // The light end of the text in dark (Carbon's own white stays white), the dark
        // end in light: a selected row fades out onto the panel, so it must read there.
        XCTAssertEqual(Self.carbon(.dark)["selectionInk"], "#FFFFFF")
        let light = PaletteColor(hex: Self.carbon(.light)["selectionInk"]!)!
        XCTAssertLessThan(light.oklch.l, 0.3)
        for appearance in [Appearance.dark, .light] {
            let tokens = Self.carbon(appearance)
            let ink = PaletteColor(hex: tokens["selectionInk"]!)!
            XCTAssertGreaterThanOrEqual(PaletteColor.contrast(ink, PaletteColor(hex: tokens["paper"]!)!), 4.5)
        }
    }

    func testAccentInkTakesTheSideThatReadsOnTheAccent() {
        for appearance in [Appearance.dark, .light] {
            var hexes = Self.carbonJobs[appearance]!
            // Carbon's bright orange takes dark print; a deep blue takes white.
            let bright = Self.carbon(appearance)
            XCTAssertLessThan(PaletteColor(hex: bright["accentInk"]!)!.oklch.l, 0.2, "\(appearance)")
            hexes[.accent] = appearance == .dark ? "#2F6BEA" : "#1F4FC4"
            let deep = SimplePaletteRecipe.tokens(jobColors: Self.jobs(hexes), contrast: .standard,
                                                  appearance: appearance)
            XCTAssertEqual(deep["accentInk"], "#FFFFFF", "\(appearance)")
            for tokens in [bright, deep] {
                let ratio = PaletteColor.contrast(PaletteColor(hex: tokens["accentInk"]!)!,
                                                  PaletteColor(hex: tokens["orange"]!)!)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(appearance)")
            }
        }
    }

    // MARK: ContrastFloors

    func testEnforceNeverMovesTheAccentKeyFill() {
        // White on Carbon's orange is 2.8:1 and the orange may not give way: the print crosses over.
        let tokens = ["accentInk": "#FFFFFF", "orange": "#FF6D3F"]
        let fixed = ContrastFloors.enforce(tokens, contrast: .standard)
        XCTAssertEqual(fixed["orange"], "#FF6D3F")
        let ink = PaletteColor(hex: fixed["accentInk"]!)!
        XCTAssertGreaterThanOrEqual(PaletteColor.contrast(ink, PaletteColor(hex: "#FF6D3F")!), 4.5)
    }

    func testUnsetAccentInkIsEnforcedThroughSelectionInk() {
        let tokens = ["selectionInk": "#FFFFFF", "orange": "#FF6D3F"]
        let fixed = ContrastFloors.enforce(tokens, contrast: .standard)
        XCTAssertNil(fixed["accentInk"])
        XCTAssertEqual(fixed["orange"], "#FF6D3F")
        XCTAssertGreaterThanOrEqual(PaletteColor.contrast(PaletteColor(hex: fixed["selectionInk"]!)!,
                                                          PaletteColor(hex: "#FF6D3F")!), 4.5)
    }

    func testRowFillIsTheSpreadOverThePanel() {
        // White text on a pale wash over a dark panel: the wash has to get darker.
        let tokens = ["selectionInk": "#FFFFFF", "selectionSpread": "#E0D0C0B3", "paper": "#141414"]
        let pair = ContrastFloors.pairs(contrast: .standard).first { $0.background == "selectionSpread" }!
        XCTAssertLessThan(ContrastFloors.ratio(of: pair, in: tokens)!, 4.5)
        let fixed = ContrastFloors.enforce(tokens, contrast: .standard)
        XCTAssertEqual(fixed["selectionInk"], "#FFFFFF")
        XCTAssertGreaterThanOrEqual(ContrastFloors.ratio(of: pair, in: fixed)!, 4.5)
        let spread = PaletteColor(hex: fixed["selectionSpread"]!)!
        let before = PaletteColor(hex: "#E0D0C0")!.oklch
        XCTAssertLessThan(spread.oklch.l, before.l, "the wash moved, darker")
        XCTAssertLessThanOrEqual(hueDistance(spread.oklch.h, before.h), 3, "its hue did not")
        XCTAssertEqual(fixed["paper"], "#141414")
    }


    func testEnforceMovesForegroundFirst() {
        let tokens = ["ink": "#808080", "paper": "#202020"]
        let fixed = ContrastFloors.enforce(tokens, contrast: .standard)
        XCTAssertEqual(fixed["paper"], "#202020", "the background stays while the foreground can move")
        let ratio = PaletteColor.contrast(PaletteColor(hex: fixed["ink"]!)!, PaletteColor(hex: fixed["paper"]!)!)
        XCTAssertGreaterThanOrEqual(ratio, 7)
    }

    func testEnforceMovesBackgroundWhenForegroundIsAtItsLimit() {
        let tokens = ["ink": "#FFFFFF", "paper": "#A0A0A0"]
        let fixed = ContrastFloors.enforce(tokens, contrast: .high)
        XCTAssertEqual(fixed["ink"], "#FFFFFF")
        let paper = PaletteColor(hex: fixed["paper"]!)!
        XCTAssertLessThan(paper.oklch.l, PaletteColor(hex: "#A0A0A0")!.oklch.l)
        XCTAssertGreaterThanOrEqual(PaletteColor.contrast(PaletteColor(hex: "#FFFFFF")!, paper), 10)
    }

    func testEnforceAdjustsTheFallbackOfAnUnsetOverride() {
        // `chassisInk` unset follows `ink2`, so it is `ink2` that has to read on the keys.
        let tokens = ["ink2": "#505050", "metal": "#404040", "chassis": "#404040"]
        let fixed = ContrastFloors.enforce(tokens, contrast: .standard)
        XCTAssertNil(fixed["chassisInk"])
        let ink2 = PaletteColor(hex: fixed["ink2"]!)!
        XCTAssertGreaterThanOrEqual(PaletteColor.contrast(ink2, PaletteColor(hex: fixed["metal"]!)!), 4.5)
    }

    func testFloorsScaleWithContrast() {
        func inkFloor(_ contrast: SimpleContrast) -> Double? {
            ContrastFloors.pairs(contrast: contrast)
                .first { $0.foreground == "ink" && $0.background == "paper" }?.minimum
        }
        XCTAssertEqual(inkFloor(.soft), 4.5)
        XCTAssertEqual(inkFloor(.standard), 7)
        XCTAssertEqual(inkFloor(.high), 10)
    }

    // MARK: Helpers

    private func assertHostileSurvives(_ jobs: [ThemeJob: PaletteColor], file: StaticString = #filePath, line: UInt = #line) {
        for appearance in [Appearance.dark, .light] {
            for contrast in SimpleContrast.allCases {
                let tokens = SimplePaletteRecipe.tokens(jobColors: jobs, contrast: contrast, appearance: appearance)
                let label = "\(appearance) \(contrast) \(jobs.mapValues(\.hex))"
                assertFloorsHold(tokens, contrast: contrast, label, file: file, line: line)
                let chassis = PaletteColor(hex: tokens["chassis"]!)!
                let paper = PaletteColor(hex: tokens["paper"]!)!
                let accent = PaletteColor(hex: tokens["orange"]!)!
                XCTAssertGreaterThanOrEqual(chassis.distance(to: paper), 0.04, "frame/panels \(label)",
                                            file: file, line: line)
                // The accent still reads as an accent: well clear of both surfaces.
                XCTAssertGreaterThanOrEqual(accent.distance(to: paper), 0.15, "accent/paper \(label)",
                                            file: file, line: line)
                XCTAssertGreaterThanOrEqual(accent.distance(to: chassis), 0.15, "accent/frame \(label)",
                                            file: file, line: line)
            }
        }
    }

    private func assertFrameAndPanelsSeparate(_ tokens: [String: String], _ label: String,
                                              file: StaticString = #filePath, line: UInt = #line) {
        let chassis = PaletteColor(hex: tokens["chassis"]!)!, paper = PaletteColor(hex: tokens["paper"]!)!
        XCTAssertGreaterThanOrEqual(chassis.distance(to: paper), 0.04,
                                    "frame/panels \(chassis.hex)/\(paper.hex) — \(label)", file: file, line: line)
    }

    /// Measured here from scratch, the way the app draws it, not through
    /// `ContrastFloors`: a selected browser row's title is `slotInk` (`selectionInk`
    /// in dark, `ink` in light) on the wash at 90% / 85% over the panel.
    private func assertSelectedRowTitlesRead(_ tokens: [String: String], appearance: Appearance, _ label: String,
                                             file: StaticString = #filePath, line: UInt = #line) {
        let ink = PaletteColor(hex: tokens[appearance == .dark ? "selectionInk" : "ink"]!)!
        let spread = PaletteColor(hex: tokens["selectionSpread"]!)!
        let paper = PaletteColor(hex: tokens["paper"]!)!
        let a = spread.a * (appearance == .dark ? 0.90 : 0.85)
        let fill = PaletteColor(r: spread.r * a + paper.r * (1 - a), g: spread.g * a + paper.g * (1 - a),
                                b: spread.b * a + paper.b * (1 - a))
        XCTAssertGreaterThanOrEqual(PaletteColor.contrast(ink, fill), 4.5,
                                    "row title \(ink.hex) on wash \(fill.hex) — \(label)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(PaletteColor.contrast(ink, paper), 4.5,
                                    "row title \(ink.hex) on panel \(paper.hex) — \(label)", file: file, line: line)
    }

    private func assertFloorsHold(_ tokens: [String: String], contrast: SimpleContrast, _ label: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        for pair in ContrastFloors.pairs(contrast: contrast) {
            guard let ratio = ContrastFloors.ratio(of: pair, in: tokens) else {
                XCTFail("missing \(pair.foreground) or \(pair.background) — \(label)", file: file, line: line)
                continue
            }
            let fg = ContrastFloors.foregroundKey(pair.foreground, in: tokens).flatMap { tokens[$0] } ?? "?"
            XCTAssertGreaterThanOrEqual(ratio, pair.minimum,
                                        "\(pair.foreground) on \(pair.background) \(fg)/\(tokens[pair.background] ?? "?") — \(label)",
                                        file: file, line: line)
        }
    }

    private func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }
}

private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
