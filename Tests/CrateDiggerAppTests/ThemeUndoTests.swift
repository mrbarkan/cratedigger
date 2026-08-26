import CrateDiggerCore
import XCTest
@testable import CrateDiggerApp

/// The editor's UNDO key. Every control writes through `ThemeRegistry.draft`,
/// so undo is one snapshot per change — the parts worth pinning are the ones
/// that aren't obvious: a drag or a typed name must cost one step, not fifty,
/// and the history has to stop growing at ten.
@MainActor
final class ThemeUndoTests: XCTestCase {
    private var themesDirectory: URL!
    private var registry: ThemeRegistry!
    private var originalWindow: TimeInterval!

    override func setUpWithError() throws {
        try super.setUpWithError()
        themesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThemeUndoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: themesDirectory, withIntermediateDirectories: true)
        registry = ThemeRegistry(loader: ThemeLoaderService(
            bundle: Bundle(for: type(of: self)),
            userThemesDirectoryOverride: themesDirectory
        ))
        originalWindow = ThemeRegistry.undoCoalesceWindow
        // Each edit below stands on its own; the coalescing case sets its own.
        ThemeRegistry.undoCoalesceWindow = 0
    }

    override func tearDownWithError() throws {
        ThemeRegistry.undoCoalesceWindow = originalWindow
        if let themesDirectory, FileManager.default.fileExists(atPath: themesDirectory.path) {
            try FileManager.default.removeItem(at: themesDirectory)
        }
        try super.tearDownWithError()
    }

    private func startDraft() {
        registry.draft = ThemeDefinition(
            id: "draft",
            name: "Draft",
            baseAppearance: .dark,
            colors: ["chassis": "#111111"]
        )
    }

    func testOpeningADraftIsNotItselfUndoable() {
        startDraft()
        XCTAssertEqual(registry.undoDepth, 0)
    }

    func testUndoRestoresTheValueBeforeTheChange() {
        startDraft()
        registry.setDraftColor("chassis", "#222222")

        XCTAssertEqual(registry.undoDepth, 1)
        registry.undoDraftStep()

        XCTAssertEqual(registry.draftColor("chassis"), "#111111")
        XCTAssertEqual(registry.undoDepth, 0)
    }

    func testOneGestureIsOneStep() {
        ThemeRegistry.undoCoalesceWindow = 60   // nothing separates these
        startDraft()
        for shade in ["#222222", "#333333", "#444444"] {
            registry.setDraftColor("chassis", shade)
        }

        XCTAssertEqual(registry.undoDepth, 1, "a drag should cost one step, not one per frame")
        registry.undoDraftStep()
        XCTAssertEqual(registry.draftColor("chassis"), "#111111")
    }

    func testHistoryStopsAtTenAndDropsTheOldest() {
        startDraft()
        for step in 1...15 {
            registry.setDraftColor("chassis", String(format: "#%06X", step))
        }

        XCTAssertEqual(registry.undoDepth, ThemeRegistry.undoDepthLimit)

        for _ in 0..<ThemeRegistry.undoDepthLimit { registry.undoDraftStep() }
        XCTAssertEqual(registry.undoDepth, 0)
        // Ten steps back from the fifteenth edit — the first five are gone.
        XCTAssertEqual(registry.draftColor("chassis"), String(format: "#%06X", 5))
        registry.undoDraftStep()   // nothing left; must not crash or wrap
        XCTAssertEqual(registry.undoDepth, 0)
    }

    func testDiscardingClearsTheHistory() {
        startDraft()
        registry.setDraftColor("chassis", "#222222")
        registry.discardDraft()

        XCTAssertEqual(registry.undoDepth, 0)
        registry.undoDraftStep()
        XCTAssertNil(registry.draft)
    }
}
