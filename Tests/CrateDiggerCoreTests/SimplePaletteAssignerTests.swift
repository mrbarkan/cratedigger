import XCTest
@testable import CrateDiggerCore

final class SimplePaletteAssignerTests: XCTestCase {
    private func colors(_ hexes: [String]) -> [PaletteColor] { hexes.map { PaletteColor(hex: $0)! } }
    private let six = ["#10141A", "#E8ECEF", "#F4F4F0", "#FF6D3F", "#050504", "#7FE0D0"]
    private let two = ["#1B2430", "#F2E9D8"]

    private func index(_ a: JobAssignment, _ job: ThemeJob) -> Int? { a[job] ?? nil }

    func testPinsHonoured() {
        let pins: [ThemeJob: Int] = [.frame: 0, .glass: 4]
        let all = SimplePaletteAssigner.validAssignments(palette: colors(six), pins: pins)
        XCTAssertFalse(all.isEmpty)
        for a in all {
            XCTAssertEqual(index(a, .frame), 0)
            XCTAssertEqual(index(a, .glass), 4)
        }
    }

    func testListIsDeterministicAndFramePanelsSeparated() {
        let palette = colors(six)
        let a = SimplePaletteAssigner.validAssignments(palette: palette, pins: [:])
        XCTAssertEqual(a, SimplePaletteAssigner.validAssignments(palette: palette, pins: [:]))
        for x in a {
            let f = palette[index(x, .frame)!].oklch.l, p = palette[index(x, .panels)!].oklch.l
            XCTAssertGreaterThanOrEqual(abs(f - p), 0.08)
        }
    }

    func testAccentIsMostChromatic() {
        let palette = colors(six)
        let top = palette.indices.max { palette[$0].oklch.c < palette[$1].oklch.c }!
        for a in SimplePaletteAssigner.validAssignments(palette: palette, pins: [:]) {
            XCTAssertEqual(index(a, .accent), top)
        }
    }

    func testShuffleCyclesAndWraps() {
        let palette = colors(six)
        let all = SimplePaletteAssigner.validAssignments(palette: palette, pins: [:])
        XCTAssertGreaterThan(all.count, 2)
        var current = SimplePaletteAssigner.initial(palette: palette, pins: [:])
        XCTAssertEqual(current, all[0])
        var seen = [current]
        for _ in 1..<all.count {
            current = SimplePaletteAssigner.shuffled(after: current, palette: palette, pins: [:])
            seen.append(current)
        }
        XCTAssertEqual(seen, all)
        XCTAssertEqual(SimplePaletteAssigner.shuffled(after: current, palette: palette, pins: [:]), all[0])
    }

    func testShuffleNeverChangesPinnedJob() {
        let palette = colors(six)
        let pins: [ThemeJob: Int] = [.text: 2]
        var current = SimplePaletteAssigner.initial(palette: palette, pins: pins)
        for _ in 0..<10 {
            current = SimplePaletteAssigner.shuffled(after: current, palette: palette, pins: pins)
            XCTAssertEqual(index(current, .text), 2)
        }
    }

    func testShuffleReturnsCurrentWhenOnlyOne() {
        let palette = colors(six)
        let pins: [ThemeJob: Int] = [.frame: 0, .panels: 1, .text: 2, .accent: 3, .glass: 4, .screenText: 5]
        let only = SimplePaletteAssigner.initial(palette: palette, pins: pins)
        XCTAssertEqual(SimplePaletteAssigner.validAssignments(palette: palette, pins: pins).count, 1)
        XCTAssertEqual(SimplePaletteAssigner.shuffled(after: only, palette: palette, pins: pins), only)
    }

    func testTwoColoursDeriveText() {
        let palette = colors(two)
        let all = SimplePaletteAssigner.validAssignments(palette: palette, pins: [:])
        XCTAssertFalse(all.isEmpty)
        XCTAssertTrue(all.contains { index($0, .text) == nil && index($0, .screenText) == nil })
        let a = all.first { index($0, .text) == nil }!
        let jobs = SimplePaletteAssigner.jobColors(palette: palette, assignment: a, appearance: .dark)
        XCTAssertEqual(jobs.count, 6)
        XCTAssertGreaterThan(PaletteColor.contrast(jobs[.text]!, jobs[.panels]!), 4.5)
    }

    func testSixColoursCanFillEveryJob() {
        let all = SimplePaletteAssigner.validAssignments(palette: colors(six), pins: [:])
        for a in all {
            XCTAssertEqual(Set(ThemeJob.allCases.compactMap { index(a, $0) }).count, 6)
        }
        let jobs = SimplePaletteAssigner.jobColors(palette: colors(six), assignment: all[0], appearance: .dark)
        XCTAssertEqual(jobs.count, 6)
    }

    func testPinToRemovedIndexIsDropped() {
        var assignment: JobAssignment = [:]
        assignment[.frame] = .some(1)
        assignment[.accent] = .some(5)
        assignment[.text] = .some(nil)
        let result = SimplePaletteAssigner.sanitize(
            pins: [.frame: 1, .accent: 5], assignment: assignment, paletteCount: 3)
        XCTAssertEqual(result.pins, [.frame: 1])
        XCTAssertEqual(result.assignment[.frame] ?? nil, 1)
        XCTAssertFalse(result.assignment.keys.contains(.accent))
        XCTAssertTrue(result.assignment.keys.contains(.text))
    }

    func testNearIdenticalPaletteStillYieldsAssignment() {
        let palette = colors(["#101010", "#111111", "#121212"])
        XCTAssertFalse(SimplePaletteAssigner.validAssignments(palette: palette, pins: [:]).isEmpty)
    }
}
