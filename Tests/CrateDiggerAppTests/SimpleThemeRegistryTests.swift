import CrateDiggerCore
import XCTest
@testable import CrateDiggerApp

/// The registry half of Simple themes: preview without touching the draft,
/// seeding from an existing theme, saving, and crossing over to Advanced.
/// Uses a temp Themes folder and puts `selectedThemeID` back afterwards.
@MainActor
final class SimpleThemeRegistryTests: XCTestCase {
    private var themesDirectory: URL!
    private var registry: ThemeRegistry!
    private var savedSelection: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedSelection = PreferencesStore.shared.selectedThemeID
        themesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleThemeRegistryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: themesDirectory, withIntermediateDirectories: true)

        let authoring = ThemeAuthoringService(themesDirectory: themesDirectory)
        try authoring.save(ThemeDefinition(
            id: "base-theme", name: "Base Theme", baseAppearance: .dark,
            colors: ["chassis": "#111111", "ink": "#EEEEEE", "orange": "#E07020"]
        ))
        try authoring.save(ThemeDefinition(
            id: "both-theme", name: "Both Theme", baseAppearance: .dark,
            colors: ["chassis": "#101820", "orange": "#E07020"],
            light: ThemeVariant(colors: ["chassis": "#EEF2F5", "orange": "#2060C0"]),
            dark: ThemeVariant()
        ))
        registry = ThemeRegistry(loader: ThemeLoaderService(
            bundle: Bundle(for: type(of: self)),
            userThemesDirectoryOverride: themesDirectory
        ))
    }

    override func tearDownWithError() throws {
        PreferencesStore.shared.selectedThemeID = savedSelection
        if let themesDirectory { try? FileManager.default.removeItem(at: themesDirectory) }
        try super.tearDownWithError()
    }

    private func manifest(_ id: String) throws -> ThemeManifest {
        try XCTUnwrap(registry.manifests.first { $0.id == id })
    }

    private func simpleCandidate() throws -> ThemeDefinition {
        var seed = registry.newSimpleSeed(from: try manifest("base-theme"))
        seed.colors = ["orange": "#12AB34"]
        return seed
    }

    func testApplySimpleSavesAndSelects() throws {
        let id = try registry.applySimple(try simpleCandidate())
        XCTAssertEqual(id, "new-theme")
        XCTAssertEqual(PreferencesStore.shared.selectedThemeID, "new-theme")
        XCTAssertNil(registry.draft)
        let saved = try manifest("new-theme")
        XCTAssertNil(saved.definition.inherits, "a Simple theme names no parent")
        XCTAssertEqual(saved.definition.colors?["orange"], "#12AB34")
    }

    func testApplySimpleWritesTheThemeWhole() throws {
        var candidate = try simpleCandidate()
        candidate.fonts = ["sans": ThemeFont(regular: "Helvetica")]
        candidate.effects = ["grain": 0.1]

        try registry.applySimple(candidate)
        let data = try Data(contentsOf: try XCTUnwrap(registry.sourceURL(for: "new-theme")))
        let file = try JSONDecoder().decode(ThemeDefinition.self, from: data)
        XCTAssertNil(file.inherits)
        XCTAssertEqual(file.fonts?["sans"]?.regular, "Helvetica")
        XCTAssertEqual(file.effects?["grain"], 0.1)
        XCTAssertEqual(file.colors?.keys.sorted(), ["orange"])
    }

    func testApplySimpleFailureLeavesStateUntouched() throws {
        registry.beginEditing(try manifest("base-theme"))
        let before = try XCTUnwrap(registry.draft)
        let depth = registry.undoDepth
        let candidate = try simpleCandidate()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: themesDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: themesDirectory.path) }

        XCTAssertThrowsError(try registry.applySimple(candidate))
        XCTAssertEqual(registry.draft, before)
        XCTAssertEqual(registry.undoDepth, depth)
        XCTAssertEqual(PreferencesStore.shared.selectedThemeID, savedSelection)
    }

    func testApplySimpleKeepsBlockOnDisk() throws {
        try registry.applySimple(try simpleCandidate())
        let saved = try manifest("new-theme")
        XCTAssertTrue(saved.definition.isSimple)
        let data = try Data(contentsOf: try XCTUnwrap(registry.sourceURL(for: "new-theme")))
        XCTAssertNotNil(try JSONDecoder().decode(ThemeDefinition.self, from: data).simple)
    }

    func testNewSeedIsSelfContained() throws {
        let seed = registry.newSimpleSeed(from: try manifest("base-theme"))
        XCTAssertNil(seed.inherits)
        XCTAssertNil(seed.logo)
        XCTAssertNil(seed.colors, "colours come from the recipe, never from the original")
        XCTAssertEqual(seed.name, "New Theme")
        XCTAssertNil(seed.author)
        XCTAssertNil(seed.version)
        XCTAssertNotNil(seed.simple)
        XCTAssertEqual(seed.baseAppearance, .dark)
        XCTAssertFalse(seed.isAdaptive)
        XCTAssertEqual(seed.fonts, try manifest("base-theme").definition.fonts)
        XCTAssertEqual(seed.effects, try manifest("base-theme").definition.effects)

        try registry.applySimple(try simpleCandidate())
        let second = registry.newSimpleSeed(from: try manifest("base-theme"))
        XCTAssertEqual(second.name, "New Theme 2")
        XCTAssertNotEqual(second.id, "new-theme")
    }

    func testNewSeedFromAdaptiveIsBoth() throws {
        let seed = registry.newSimpleSeed(from: try manifest("both-theme"))
        XCTAssertTrue(seed.isAdaptive)
        XCTAssertNil(seed.inherits)
        XCTAssertNil(seed.light?.colors)
        XCTAssertNil(seed.dark?.colors)
    }

    func testConvertDropsBlockKeepsTokens() throws {
        registry.beginAdvancedCopy(of: try simpleCandidate())
        var draft = try XCTUnwrap(registry.draft)
        draft.simple = try XCTUnwrap(registry.newSimpleSeed(from: try manifest("base-theme")).simple)
        let window = ThemeRegistry.undoCoalesceWindow
        ThemeRegistry.undoCoalesceWindow = -1
        defer { ThemeRegistry.undoCoalesceWindow = window }
        registry.draft = draft
        let depth = registry.undoDepth
        registry.convertDraftToAdvanced()
        let converted = try XCTUnwrap(registry.draft)
        XCTAssertNil(converted.simple)
        XCTAssertEqual(converted.colors?["orange"], "#12AB34")
        XCTAssertEqual(registry.undoDepth, depth + 1)
        registry.undoDraftStep()
        XCTAssertNotNil(registry.draft?.simple)
    }

    func testAdvancedCopyIsNewNamedAndRecipeFree() throws {
        registry.beginAdvancedCopy(of: try simpleCandidate())
        let copy = try XCTUnwrap(registry.draft)
        XCTAssertNil(copy.simple)
        XCTAssertEqual(copy.name, "New Theme Copy")
        XCTAssertEqual(copy.colors?.count, ThemeRegistry.seeded(try simpleCandidate()).colors?.count)
    }

    func testPreviewThemeUsesDraftColours() throws {
        let candidate = try simpleCandidate()
        let preview = registry.previewTheme(for: candidate, appearance: .dark)
        XCTAssertEqual(preview.theme.orange.themeHexString.uppercased(), "#12AB34")
        // Nothing comes from the theme it was started from: a token the candidate
        // leaves out is the stock theme's, not the original's.
        XCTAssertNotEqual(preview.theme.ink.themeHexString.uppercased(), "#EEEEEE")
        XCTAssertNil(registry.draft, "a preview must never become the live draft")
    }
}
