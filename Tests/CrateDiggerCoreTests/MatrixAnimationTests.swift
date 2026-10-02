import XCTest
@testable import CrateDiggerCore

/// The NOW screen's 12 × 6 matrix. Every animation is a pure function of the
/// audio it is fed (plus its own memory, for Explosions), so each is checked
/// here frame by frame rather than by eye.
final class MatrixAnimationTests: XCTestCase {

    private let tick: TimeInterval = 1.0 / 30

    private func input(_ bands: [Double], left: Double = 0, right: Double = 0, dt: TimeInterval? = nil) -> MatrixInput {
        MatrixInput(bands: bands, left: left, right: right, dt: dt ?? tick)
    }

    private func bands(_ values: [Int: Double]) -> [Double] {
        (0..<12).map { values[$0] ?? 0 }
    }

    private func litCells(_ frame: MatrixFrame) -> [(column: Int, row: Int)] {
        var lit: [(Int, Int)] = []
        for row in 0..<MatrixFrame.rows {
            for column in 0..<MatrixFrame.columns where frame[column: column, row: row].intensity > 0 {
                lit.append((column, row))
            }
        }
        return lit
    }

    // MARK: - Frame and input

    func testFrameIsRowMajorWithRowZeroAtTheBottom() {
        var frame = MatrixFrame.dark
        XCTAssertEqual(frame.cells.count, 72)
        frame[column: 3, row: 1] = MatrixCell(intensity: 1, heat: 0.5)
        XCTAssertEqual(frame.cells[1 * 12 + 3], MatrixCell(intensity: 1, heat: 0.5))
        XCTAssertEqual(frame[column: 3, row: 1].heat, 0.5)
        XCTAssertNotEqual(frame, .dark)
    }

    func testDarkFrameIsEntirelyUnlit() {
        XCTAssertTrue(MatrixFrame.dark.cells.allSatisfy { $0 == MatrixCell(intensity: 0, heat: 0) })
    }

    /// A stream tap that has not delivered yet hands over no bands at all.
    func testInputPadsShortBandsWithZerosAndTruncatesLongOnes() {
        XCTAssertEqual(MatrixInput(bands: [], left: 0, right: 0, dt: tick).bands, Array(repeating: 0, count: 12))
        XCTAssertEqual(MatrixInput(bands: [0.5, 1], left: 0, right: 0, dt: tick).bands, [0.5, 1] + Array(repeating: 0, count: 10))
        XCTAssertEqual(MatrixInput(bands: Array(repeating: 0.25, count: 20), left: 0, right: 0, dt: tick).bands.count, 12)
    }

    func testInputPadsBandsAssignedAfterInit() {
        var input = MatrixInput(bands: [], left: 0, right: 0, dt: tick)
        input.bands = [1]
        XCTAssertEqual(input.bands.count, 12)
        XCTAssertEqual(input.loudness, 1.0 / 12, accuracy: 1e-12)
    }

    func testLoudnessIsTheMeanOfTheBands() {
        XCTAssertEqual(input(bands([0: 1, 1: 1, 2: 1])).loudness, 0.25, accuracy: 1e-12)
        XCTAssertEqual(input(Array(repeating: 1, count: 12)).loudness, 1, accuracy: 1e-12)
        XCTAssertEqual(input([]).loudness, 0)
    }

    func testInputClampsOutOfRangeAndNonFiniteValues() {
        let odd = MatrixInput(bands: [2, -1, .nan], left: 7, right: -.infinity, dt: -1)
        XCTAssertEqual(Array(odd.bands.prefix(3)), [1, 0, 0])
        XCTAssertEqual(odd.left, 1)
        XCTAssertEqual(odd.right, 0)
        XCTAssertEqual(odd.dt, 0)
        XCTAssertEqual(MatrixInput(bands: [], left: 0, right: 0, dt: .nan).dt, 0)
    }

    // MARK: - Every kind

    func testSilenceGivesDarkAndRestForEveryKind() {
        for kind in MatrixAnimationKind.allCases {
            guard var animation = kind.make() else { continue }
            XCTAssertTrue(animation.isAtRest, "\(kind) before its first frame")
            for _ in 0..<5 {
                XCTAssertEqual(animation.frame(for: input([])), .dark, "\(kind)")
            }
            XCTAssertTrue(animation.isAtRest, "\(kind)")
        }
    }

    func testSoundIsNotAtRestForEveryKind() {
        for kind in MatrixAnimationKind.allCases {
            guard var animation = kind.make() else { continue }
            let frame = animation.frame(for: input(Array(repeating: 1, count: 12), left: 1, right: 1))
            XCTAssertNotEqual(frame, .dark, "\(kind)")
            XCTAssertFalse(animation.isAtRest, "\(kind)")
        }
    }

    /// dt = 0 (two ticks in the same instant) and a huge dt (the first tick
    /// after the timer slept) must both produce a sane frame.
    func testDegenerateTimeStepsAreHarmlessForEveryKind() {
        for kind in MatrixAnimationKind.allCases {
            guard var animation = kind.make() else { continue }
            _ = animation.frame(for: input(Array(repeating: 1, count: 12), left: 1, right: 1, dt: 0))
            _ = animation.frame(for: input(Array(repeating: 0.5, count: 12), left: 0.5, right: 0.5, dt: 0))
            let after = animation.frame(for: input([], dt: 3_600))
            XCTAssertTrue(after.cells.allSatisfy { (0...1).contains($0.intensity) && (0...1).contains($0.heat) }, "\(kind)")
            XCTAssertEqual(after, .dark, "\(kind)")
            XCTAssertTrue(animation.isAtRest, "\(kind)")
        }
    }

    func testCellsStayWithinRangeForEveryKind() {
        for kind in MatrixAnimationKind.allCases {
            guard var animation = kind.make() else { continue }
            for step in 0..<60 {
                let level = Double(step % 7) / 6
                let frame = animation.frame(for: input((0..<12).map { Double(($0 + step) % 12) / 11 * level }, left: level, right: 1 - level))
                for cell in frame.cells {
                    XCTAssertTrue((0...1).contains(cell.intensity), "\(kind) intensity \(cell.intensity)")
                    XCTAssertTrue((0...1).contains(cell.heat), "\(kind) heat \(cell.heat)")
                }
            }
        }
    }

    // MARK: - Vertical VU

    func testVerticalFullBandsLightEveryCellWithTheTopRowAsPeak() {
        var vu = VerticalVUAnimation()
        let frame = vu.frame(for: input(Array(repeating: 1, count: 12)))
        for column in 0..<12 {
            for row in 0..<6 {
                let cell = frame[column: column, row: row]
                XCTAssertEqual(cell.intensity, row == 5 ? 1 : 0.75, "c\(column) r\(row)")
                XCTAssertEqual(cell.heat, Double(row) / 5, accuracy: 1e-12)
            }
        }
    }

    func testVerticalHalfBassLightsThreeCellsInTheFirstColumnOnly() {
        var vu = VerticalVUAnimation()
        let frame = vu.frame(for: input(bands([0: 0.5])))
        let lit = litCells(frame)
        XCTAssertEqual(lit.count, 3)
        XCTAssertTrue(lit.allSatisfy { $0.column == 0 })
        XCTAssertEqual(frame[column: 0, row: 2].intensity, 1)     // the peak
        XCTAssertEqual(frame[column: 0, row: 0].intensity, 0.75)
        XCTAssertEqual(frame[column: 0, row: 1].intensity, 0.75)
        XCTAssertEqual(frame[column: 0, row: 3], MatrixCell(intensity: 0, heat: 0))
    }

    func testVerticalRoundsToWholeSegments() {
        var vu = VerticalVUAnimation()
        // 0.08 × 6 = 0.48 → 0 segments; 0.09 × 6 = 0.54 → 1 segment.
        let frame = vu.frame(for: input(bands([0: 0.08, 1: 0.09])))
        XCTAssertEqual(litCells(frame).map(\.column), [1])
        XCTAssertEqual(frame[column: 1, row: 0].intensity, 1)
    }

    // MARK: - Horizontal VU

    func testHorizontalLeftFillsTheTopRowsAndRightTheBottom() {
        var vu = HorizontalVUAnimation()
        let frame = vu.frame(for: input([], left: 1, right: 0))
        for row in 0..<6 {
            for column in 0..<12 {
                let cell = frame[column: column, row: row]
                if row >= 3 {
                    XCTAssertEqual(cell.intensity, column == 11 ? 1 : 0.75, "c\(column) r\(row)")
                    XCTAssertEqual(cell.heat, Double(column) / 11, accuracy: 1e-12)
                } else {
                    XCTAssertEqual(cell, MatrixCell(intensity: 0, heat: 0), "c\(column) r\(row)")
                }
            }
        }
    }

    func testHorizontalBarLengthIsRoundedLevelTimesTwelve() {
        var vu = HorizontalVUAnimation()
        let frame = vu.frame(for: input([], left: 0, right: 0.5))
        let lit = litCells(frame)
        XCTAssertEqual(lit.count, 6 * 3)
        XCTAssertTrue(lit.allSatisfy { $0.row <= 2 && $0.column < 6 })
        XCTAssertEqual(frame[column: 5, row: 0].intensity, 1)
        XCTAssertEqual(frame[column: 4, row: 0].intensity, 0.75)
    }

    func testHorizontalIgnoresTheBands() {
        var vu = HorizontalVUAnimation()
        XCTAssertEqual(vu.frame(for: input(Array(repeating: 1, count: 12))), .dark)
        XCTAssertTrue(vu.isAtRest)
    }

    // MARK: - Explosions

    private let bassOnly: [Double] = [1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0]

    func testExplosionsBassStepSpawnsARingThatGrows() {
        var boom = ExplosionsAnimation()
        _ = boom.frame(for: input([]))
        XCTAssertTrue(boom.rings.isEmpty)

        _ = boom.frame(for: input(bassOnly))
        XCTAssertEqual(boom.rings.count, 1)
        XCTAssertEqual(boom.rings[0].radius, 0, accuracy: 1e-12)

        var previous = boom.rings[0].radius
        for _ in 0..<5 {
            _ = boom.frame(for: input(bassOnly))
            XCTAssertEqual(boom.rings.count, 1, "a held bass is one hit, not one per frame")
            XCTAssertGreaterThan(boom.rings[0].radius, previous)
            previous = boom.rings[0].radius
        }
        XCTAssertEqual(previous, 5 * tick * 2.0, accuracy: 1e-9)    // 2.0 per second
    }

    func testExplosionsRingFadesLinearlyOverHalfASecond() {
        var boom = ExplosionsAnimation()
        _ = boom.frame(for: input(bassOnly, dt: 0))
        _ = boom.frame(for: input(bassOnly, dt: 0.25))
        XCTAssertEqual(boom.rings.first?.brightness ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(boom.rings.first?.radius ?? -1, 0.5, accuracy: 1e-9)
    }

    func testExplosionsReachRestWithinSixTenthsOfASecondOnceTheBassFallsBack() {
        var boom = ExplosionsAnimation()
        _ = boom.frame(for: input([]))
        _ = boom.frame(for: input(bassOnly))
        XCTAssertFalse(boom.isAtRest)

        var elapsed: TimeInterval = 0
        var frame = MatrixFrame.dark
        while elapsed < 0.6 && !boom.isAtRest {
            frame = boom.frame(for: input([]))
            elapsed += tick
        }
        XCTAssertTrue(boom.isAtRest, "still moving after \(elapsed) s")
        XCTAssertEqual(frame, .dark)
        XCTAssertGreaterThan(elapsed, 0.4, "the ring should travel, not vanish")
    }

    func testExplosionsRingLightsCellsNearItsRadius() {
        var boom = ExplosionsAnimation()
        _ = boom.frame(for: input([]))
        _ = boom.frame(for: input(bassOnly, dt: 0))
        // Drop the bass so the core goes dark and only the ring is left, at radius 0.6.
        let frame = boom.frame(for: input([], dt: 0.3))
        let lit = litCells(frame)
        XCTAssertFalse(lit.isEmpty)
        for (column, row) in lit {
            let d = ExplosionsAnimation.distance(column: column, row: row)
            XCTAssertLessThanOrEqual(abs(d - 0.6), 0.18 + 1e-9)
            let cell = frame[column: column, row: row]
            XCTAssertEqual(cell.intensity, 0.4, accuracy: 1e-9)       // 1 − 0.3/0.5
            XCTAssertEqual(cell.heat, 1 - d, accuracy: 1e-9)
        }
        // The centre (d ≈ 0.19) is well inside the ring and stays dark.
        XCTAssertEqual(frame[column: 5, row: 2].intensity, 0)
    }

    /// The core is exactly the cells within `loudness` of the centre, at the
    /// body brightness, and it widens as the music gets louder. Each level
    /// gets a fresh animation at dt = 0 so no average built over time comes
    /// into it. The step from silence does launch a ring, but at radius 0 it
    /// reaches only d ≤ 0.18, and the nearest cells to the centre sit at
    /// d ≈ 0.19, so every lit cell here is core.
    func testExplosionsCoreRadiusFollowsLoudness() {
        var previous = Set<Int>()
        for loudness in [0.25, 0.5, 0.75] {
            var boom = ExplosionsAnimation()
            let frame = boom.frame(for: input(Array(repeating: loudness, count: 12), dt: 0))
            var core = Set<Int>()
            for row in 0..<6 {
                for column in 0..<12 {
                    let d = ExplosionsAnimation.distance(column: column, row: row)
                    let cell = frame[column: column, row: row]
                    if d <= loudness {
                        core.insert(row * 12 + column)
                        XCTAssertEqual(cell.intensity, ExplosionsAnimation.coreIntensity, "L=\(loudness) c\(column) r\(row) d=\(d)")
                        XCTAssertEqual(cell.heat, 1 - d, accuracy: 1e-9)
                    } else {
                        XCTAssertEqual(cell, MatrixCell(), "L=\(loudness) c\(column) r\(row) d=\(d)")
                    }
                }
            }
            XCTAssertTrue(core.isStrictSuperset(of: previous), "the core should widen at L=\(loudness)")
            previous = core
        }
    }

    func testExplosionsDistanceIsEllipticalAndClamped() {
        // The grid's centre is (5.5, 2.5): the four middle cells are equidistant.
        let centre = ExplosionsAnimation.distance(column: 5, row: 2)
        XCTAssertEqual(centre, ExplosionsAnimation.distance(column: 6, row: 3), accuracy: 1e-12)
        XCTAssertEqual(centre, ((0.5 / 6) * (0.5 / 6) + (0.5 / 3) * (0.5 / 3)).squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(ExplosionsAnimation.distance(column: 0, row: 0), 1)        // corner, clamped
        XCTAssertEqual(ExplosionsAnimation.distance(column: 0, row: 2), (5.5 / 6 * 5.5 / 6 + 0.5 / 3 * 0.5 / 3).squareRoot(), accuracy: 1e-12)
    }

    func testExplosionsKeepAtMostFourRings() {
        var boom = ExplosionsAnimation()
        for _ in 0..<6 {
            _ = boom.frame(for: input([], dt: 0.01))
            _ = boom.frame(for: input(bassOnly, dt: 0.01))
        }
        XCTAssertEqual(boom.rings.count, 4)
        // The survivors are the newest four: the youngest has age 0.
        XCTAssertEqual(boom.rings.map(\.age).min() ?? -1, 0, accuracy: 1e-12)
        XCTAssertLessThan(boom.rings.map(\.age).max() ?? 1, 0.1)
    }

    func testExplosionsGradualRiseIsNotAHit() {
        var boom = ExplosionsAnimation()
        // The bass creeps up slower than its own average can follow past 0.15.
        for step in 0...90 {
            let level = Double(step) / 90 * 0.6
            _ = boom.frame(for: input([level, level, level]))
        }
        XCTAssertTrue(boom.rings.isEmpty)
    }

    func testExplosionsHugeTimeStepClearsTheRings() {
        var boom = ExplosionsAnimation()
        _ = boom.frame(for: input([]))
        _ = boom.frame(for: input(bassOnly))
        XCTAssertEqual(boom.rings.count, 1)
        XCTAssertEqual(boom.frame(for: input([], dt: 10)), .dark)
        XCTAssertTrue(boom.rings.isEmpty)
        XCTAssertTrue(boom.isAtRest)
    }

    /// The driver stops its timer at rest, and the next tick can come much
    /// later. The bass average must not hold a stale value across that gap, or
    /// the first hit after a pause is swallowed.
    func testExplosionsDetectTheFirstHitAfterRest() {
        var boom = ExplosionsAnimation()
        for _ in 0..<30 { _ = boom.frame(for: input(bassOnly)) }
        // Bounded: two seconds of silence is four ring lifetimes, so an
        // animation that never comes to rest fails here instead of hanging
        // the suite.
        var silentTicks = 0
        while !boom.isAtRest, silentTicks < 60 {
            _ = boom.frame(for: input([]))
            silentTicks += 1
        }
        XCTAssertTrue(boom.isAtRest, "never came to rest after \(silentTicks) silent ticks")
        _ = boom.frame(for: input(bassOnly))
        XCTAssertEqual(boom.rings.count, 1)
    }

    // MARK: - Frame

    func testFrameRingIndexRunsFromTheBorderInward() {
        XCTAssertEqual(FrameAnimation.ring(column: 0, row: 3), 0)
        XCTAssertEqual(FrameAnimation.ring(column: 11, row: 3), 0)
        XCTAssertEqual(FrameAnimation.ring(column: 5, row: 0), 0)
        XCTAssertEqual(FrameAnimation.ring(column: 1, row: 1), 1)
        XCTAssertEqual(FrameAnimation.ring(column: 6, row: 4), 1)
        XCTAssertEqual(FrameAnimation.ring(column: 2, row: 2), 2)
        XCTAssertEqual(FrameAnimation.ring(column: 9, row: 3), 2)
    }

    func testFrameBassOnlyLightsTheOuterRingAlone() {
        var frame = FrameAnimation()
        let out = frame.frame(for: input(bands([0: 1, 1: 1, 2: 1, 3: 1])))
        for row in 0..<6 {
            for column in 0..<12 {
                let cell = out[column: column, row: row]
                if FrameAnimation.ring(column: column, row: row) == 0 {
                    XCTAssertEqual(cell.intensity, 1, accuracy: 1e-12, "c\(column) r\(row)")
                    XCTAssertEqual(cell.heat, 0)
                } else {
                    XCTAssertEqual(cell, MatrixCell(intensity: 0, heat: 0), "c\(column) r\(row)")
                }
            }
        }
    }

    func testFrameFullBandsLightEveryRing() {
        var frame = FrameAnimation()
        let out = frame.frame(for: input(Array(repeating: 1, count: 12)))
        for row in 0..<6 {
            for column in 0..<12 {
                let cell = out[column: column, row: row]
                XCTAssertEqual(cell.intensity, 1, accuracy: 1e-12)
                XCTAssertEqual(cell.heat, Double(FrameAnimation.ring(column: column, row: row)) / 2, accuracy: 1e-12)
            }
        }
    }

    /// depth = loudness × 3 = 1.5: ring 0 whole, ring 1 at half its group's level.
    func testFrameScalesTheInnermostLitRingByTheFraction() {
        var frame = FrameAnimation()
        let out = frame.frame(for: input([1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0]))
        XCTAssertEqual(out[column: 0, row: 0].intensity, 1, accuracy: 1e-12)        // ring 0: bands 0–3 mean 1
        XCTAssertEqual(out[column: 1, row: 1].intensity, 0.5 * 0.5, accuracy: 1e-12) // ring 1: mean 0.5, × 0.5
        XCTAssertEqual(out[column: 2, row: 2].intensity, 0)                         // ring 2: unlit
    }

    // MARK: - Resting heat

    /// A dark cell prints in the colour it would light in, so the unlit grid
    /// shades the same way each animation does. The frame itself keeps unlit
    /// heat at 0; the tint comes from here.
    func testRestingHeatIsTheHeatACellLightsWith() {
        var vertical = VerticalVUAnimation()
        var horizontal = HorizontalVUAnimation()
        var frameAnimation = FrameAnimation()
        let full = input(Array(repeating: 1, count: 12), left: 1, right: 1)
        let pictures: [(MatrixAnimationKind, MatrixFrame)] = [
            (.vertical, vertical.frame(for: full)),
            (.horizontal, horizontal.frame(for: full)),
            (.frame, frameAnimation.frame(for: full)),
        ]
        for (kind, picture) in pictures {
            for row in 0..<6 {
                for column in 0..<12 {
                    XCTAssertEqual(kind.restingHeat(column: column, row: row), picture[column: column, row: row].heat,
                                   accuracy: 1e-12, "\(kind) c\(column) r\(row)")
                }
            }
        }
    }

    func testRestingHeatRunsInEachAnimationsDirection() {
        XCTAssertEqual(MatrixAnimationKind.vertical.restingHeat(column: 4, row: 0), 0)
        XCTAssertEqual(MatrixAnimationKind.vertical.restingHeat(column: 4, row: 5), 1)
        XCTAssertEqual(MatrixAnimationKind.horizontal.restingHeat(column: 0, row: 3), 0)
        XCTAssertEqual(MatrixAnimationKind.horizontal.restingHeat(column: 11, row: 3), 1)
        XCTAssertEqual(MatrixAnimationKind.explosions.restingHeat(column: 0, row: 0), 0)        // corner, d = 1
        XCTAssertEqual(MatrixAnimationKind.explosions.restingHeat(column: 5, row: 2),
                       1 - ExplosionsAnimation.distance(column: 5, row: 2), accuracy: 1e-12)
        XCTAssertEqual(MatrixAnimationKind.frame.restingHeat(column: 0, row: 3), 0)
        XCTAssertEqual(MatrixAnimationKind.frame.restingHeat(column: 1, row: 1), 0.5)
        XCTAssertEqual(MatrixAnimationKind.frame.restingHeat(column: 5, row: 2), 1)
        for kind in MatrixAnimationKind.allCases {
            for row in 0..<6 {
                for column in 0..<12 {
                    XCTAssertTrue((0...1).contains(kind.restingHeat(column: column, row: row)), "\(kind)")
                }
            }
        }
    }

    // MARK: - Quantising

    func testQuantizeRoundsToEighthsAndDropsTheHeatOfACellThatGoesOut() {
        var frame = MatrixFrame.dark
        frame[column: 0, row: 0] = MatrixCell(intensity: 0.06, heat: 0.8)    // 0.48 eighths → out
        frame[column: 1, row: 0] = MatrixCell(intensity: 0.07, heat: 0.8)    // 0.56 eighths → 1/8
        frame[column: 2, row: 0] = MatrixCell(intensity: 0.74, heat: 0.3)    // → 0.75
        frame[column: 3, row: 0] = MatrixCell(intensity: 1, heat: 1)
        frame.quantize(step: 1.0 / 8)
        XCTAssertEqual(frame[column: 0, row: 0], MatrixCell(intensity: 0, heat: 0))
        XCTAssertEqual(frame[column: 1, row: 0], MatrixCell(intensity: 0.125, heat: 0.8))
        XCTAssertEqual(frame[column: 2, row: 0], MatrixCell(intensity: 0.75, heat: 0.3))
        XCTAssertEqual(frame[column: 3, row: 0], MatrixCell(intensity: 1, heat: 1))
    }

    /// A ring in the last sixteenth of its life is too dim to draw. Once
    /// quantised, the picture it leaves must be `.dark`, heat and all, or the
    /// driver would see a change that is not there.
    func testQuantizedFadeOutComparesEqualToDark() {
        var frame = MatrixFrame.dark
        for row in 0..<6 {
            for column in 0..<12 {
                frame[column: column, row: row] = MatrixCell(intensity: 0.05, heat: ExplosionsAnimation.restingHeat(column: column, row: row))
            }
        }
        XCTAssertNotEqual(frame, .dark)
        frame.quantize(step: 1.0 / 8)
        XCTAssertEqual(frame, .dark)
    }

    // MARK: - Kind

    func testKindNextFollowsTheClickOrder() {
        XCTAssertEqual(MatrixAnimationKind.vertical.next, .horizontal)
        XCTAssertEqual(MatrixAnimationKind.horizontal.next, .explosions)
        XCTAssertEqual(MatrixAnimationKind.explosions.next, .frame)
        XCTAssertEqual(MatrixAnimationKind.frame.next, .off)
        XCTAssertEqual(MatrixAnimationKind.off.next, .vertical)
        XCTAssertEqual(MatrixAnimationKind.allCases, [.vertical, .horizontal, .explosions, .frame, .off])
    }

    func testKindPersistedValueFallsBackToVertical() {
        XCTAssertEqual(MatrixAnimationKind(persisted: nil), .vertical)
        XCTAssertEqual(MatrixAnimationKind(persisted: "bogus"), .vertical)
        XCTAssertEqual(MatrixAnimationKind(persisted: ""), .vertical)
        for kind in MatrixAnimationKind.allCases {
            XCTAssertEqual(MatrixAnimationKind(persisted: kind.rawValue), kind)
        }
    }

    func testKindMakesTheMatchingAnimation() {
        XCTAssertNil(MatrixAnimationKind.off.make())
        XCTAssertTrue(MatrixAnimationKind.vertical.make() is VerticalVUAnimation)
        XCTAssertTrue(MatrixAnimationKind.horizontal.make() is HorizontalVUAnimation)
        XCTAssertTrue(MatrixAnimationKind.explosions.make() is ExplosionsAnimation)
        XCTAssertTrue(MatrixAnimationKind.frame.make() is FrameAnimation)
    }

    func testKindLabels() {
        XCTAssertEqual(MatrixAnimationKind.allCases.map(\.label), ["Vertical VU", "Horizontal VU", "Explosions", "Frame", "Off"])
    }
}
