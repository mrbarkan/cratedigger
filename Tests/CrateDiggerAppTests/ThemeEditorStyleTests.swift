import CrateDiggerCore
import XCTest
@testable import CrateDiggerApp

/// Choosing a theme's interface style in the editors: Advanced writes it into
/// the draft as one undo step and leaves the FLAT switch's stored value alone;
/// Simple reads it from the theme it opens and carries it into the candidate,
/// reopened or new. Uses a temp Themes folder and puts `selectedThemeID` back.
@MainActor
final class ThemeEditorStyleTests: XCTestCase {
    private var themesDirectory: URL!
    private var registry: ThemeRegistry!
    private var session: ThemeEditorSession!
    private var savedSelection: String?
    private var originalWindow: TimeInterval!

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedSelection = PreferencesStore.shared.selectedThemeID
        originalWindow = ThemeRegistry.undoCoalesceWindow
        // Each edit below is its own step; nothing here is a drag.
        ThemeRegistry.undoCoalesceWindow = 0
        themesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThemeEditorStyleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: themesDirectory, withIntermediateDirectories: true)
        let authoring = ThemeAuthoringService(themesDirectory: themesDirectory)
        try authoring.save(ThemeDefinition(
            id: "base-theme", name: "Base Theme", baseAppearance: .dark,
            colors: ["chassis": "#111111", "ink": "#EEEEEE", "orange": "#E07020"]
        ))
        // Funhouse-like: a theme that wears Sticker.
        try authoring.save(ThemeDefinition(
            id: "sticker-theme", name: "Sticker Theme", baseAppearance: .light,
            colors: ["chassis": "#F4E9D8", "ink": "#2A2140", "orange": "#E0457B"],
            style: .sticker
        ))
        registry = ThemeRegistry(loader: ThemeLoaderService(
            bundle: Bundle(for: type(of: self)),
            userThemesDirectoryOverride: themesDirectory
        ))
        session = ThemeEditorSession(registry: registry)
    }

    override func tearDownWithError() throws {
        ThemeRegistry.undoCoalesceWindow = originalWindow
        PreferencesStore.shared.selectedThemeID = savedSelection
        if let themesDirectory { try? FileManager.default.removeItem(at: themesDirectory) }
        try super.tearDownWithError()
    }

    private func manifest(_ id: String) throws -> ThemeManifest {
        try XCTUnwrap(registry.manifests.first { $0.id == id })
    }

    // MARK: Advanced

    func testSettingStyleOnTheDraftIsOneUndoStep() throws {
        session.open(try manifest("base-theme"))
        XCTAssertNil(session.simple, "a theme with no Simple block opens in Advanced")
        XCTAssertEqual(registry.draft?.resolvedStyle, .hardware)
        XCTAssertEqual(registry.undoDepth, 0)

        registry.setDraftStyle(.sticker)
        XCTAssertEqual(registry.draft?.resolvedStyle, .sticker)
        XCTAssertEqual(registry.undoDepth, 1, "a style is one step")

        registry.undoDraftStep()
        XCTAssertEqual(registry.draft?.resolvedStyle, .hardware)
        XCTAssertEqual(registry.undoDepth, 0)
    }

    /// Pressing the key already lit is not an edit: no undo step, and an
    /// unstyled theme's absent style is not written out as `hardware`.
    func testChoosingTheCurrentStyleChangesNothing() throws {
        session.open(try manifest("base-theme"))
        let before = registry.draft
        XCTAssertNil(before?.style)
        registry.setDraftStyle(.hardware)
        XCTAssertEqual(registry.undoDepth, 0)
        XCTAssertEqual(registry.draft, before)

        session.open(try manifest("sticker-theme"))
        let sticker = registry.draft
        let depth = registry.undoDepth
        registry.setDraftStyle(.sticker)
        XCTAssertEqual(registry.undoDepth, depth)
        XCTAssertEqual(registry.draft, sticker)
    }

    func testStyleChangeLeavesTheFlatSwitchAsItWas() throws {
        session.open(try manifest("base-theme"))
        registry.draft?.effects = ["flat": 1]
        registry.setDraftStyle(.softBlocks)
        XCTAssertEqual(registry.draft?.effects?["flat"], 1)
        registry.setDraftStyle(.hardware)
        XCTAssertEqual(registry.draft?.effects?["flat"], 1, "FLAT works again back on Real Hardware")
        XCTAssertNil(registry.draft?.style, "Real Hardware is written as absent")
    }

    func testDiscardingTheDraftDropsTheChosenStyle() throws {
        session.open(try manifest("sticker-theme"))
        registry.setDraftStyle(.flatHardware)
        XCTAssertEqual(registry.activeDefinition(for: "sticker-theme")?.resolvedStyle, .flatHardware)
        registry.discardDraft()
        XCTAssertEqual(registry.activeDefinition(for: "sticker-theme")?.resolvedStyle, .sticker,
                       "the console goes back to the saved theme's style")
    }

    // MARK: Forks

    /// A style is not inherited, so a fork of a styled built-in must write its
    /// style out itself. Funhouse's own file, under an id the checkout does not
    /// hold, so the editor forks it rather than editing it in place.
    func testAForkOfFunhouseSavedFromTheEditorStoresStickerAndReloadsAsSticker() throws {
        let checkout = try XCTUnwrap(BuiltInThemeEditing.repositoryThemesDirectory)
        var funhouse = try XCTUnwrap(
            ThemeLoaderService(bundles: [], userThemesDirectoryOverride: checkout)
                .discoverThemes().themes.first { $0.id == "funhouse" }
        ).definition
        XCTAssertEqual(funhouse.style, .sticker)
        funhouse.id = "funhouse-fixture"
        try ThemeAuthoringService(themesDirectory: themesDirectory).save(funhouse)
        registry.refresh()
        let shipped = ThemeManifest(definition: try manifest("funhouse-fixture").definition, origin: .builtIn)
        XCTAssertFalse(BuiltInThemeEditing.isEditable(shipped), "the fixture must fork, not edit in place")

        registry.beginEditing(shipped, appearance: .light)
        XCTAssertEqual(registry.draft?.inherits, "funhouse-fixture")
        let savedID = try XCTUnwrap(try registry.saveDraft())

        let file = ThemeAuthoringService(themesDirectory: themesDirectory).bundleURL(for: savedID)
            .appendingPathComponent("theme.json")
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        XCTAssertEqual(object["inherits"] as? String, "funhouse-fixture")
        XCTAssertEqual(object["style"] as? String, "sticker", "the fork carries its style itself")

        let reloaded = ThemeLoaderService(bundles: [], userThemesDirectoryOverride: themesDirectory)
            .discoverThemes().themes.first { $0.id == savedID }
        XCTAssertEqual(reloaded?.definition.resolvedStyle, .sticker)
    }

    // MARK: Simple

    func testSimpleChoicesReadTheThemesStyle() throws {
        let editor = SimpleThemeEditor(copyOf: try manifest("sticker-theme").definition, registry: registry)
        XCTAssertEqual(editor.choices.style, .sticker)
        XCTAssertEqual(editor.candidate.resolvedStyle, .sticker)

        let fromNew = SimpleThemeEditor(newFrom: try manifest("sticker-theme"), registry: registry)
        XCTAssertEqual(fromNew.choices.style, .sticker)
        XCTAssertEqual(fromNew.candidate.resolvedStyle, .sticker)
    }

    func testSimpleStyleChoiceReachesTheCandidateAndDiscardPutsItBack() throws {
        let editor = SimpleThemeEditor(newFrom: try manifest("base-theme"), registry: registry)
        XCTAssertEqual(editor.choices.style, .hardware)
        editor.choices.style = .softBlocks
        XCTAssertEqual(editor.candidate.resolvedStyle, .softBlocks)
        XCTAssertTrue(editor.hasUnappliedChanges)
        editor.discard()
        XCTAssertEqual(editor.choices.style, .hardware)
        XCTAssertEqual(editor.candidate.resolvedStyle, .hardware)
    }

    /// A reopened Simple theme draws its saved colours until the first
    /// regenerating change; a style, like a material, applies straight onto them.
    func testReopenedSimpleThemeKeepsAndChangesItsStyleWithoutRegenerating() throws {
        let first = SimpleThemeEditor(newFrom: try manifest("base-theme"), registry: registry)
        first.choices.style = .sticker
        try first.apply()
        let saved = try manifest(first.candidate.id)
        XCTAssertEqual(saved.definition.resolvedStyle, .sticker)

        let editor = SimpleThemeEditor(reopening: saved, registry: registry)
        XCTAssertTrue(editor.needsRegenerateWarning)
        XCTAssertEqual(editor.choices.style, .sticker)
        XCTAssertEqual(editor.candidate.resolvedStyle, .sticker)
        XCTAssertFalse(editor.hasUnappliedChanges)

        XCTAssertFalse(editor.needsWarning(for: .style))
        editor.choices.style = .flatHardware
        XCTAssertTrue(editor.needsRegenerateWarning)
        XCTAssertEqual(editor.candidate.resolvedStyle, .flatHardware)
        XCTAssertEqual(editor.candidate.colors, saved.definition.colors)
        XCTAssertTrue(editor.hasUnappliedChanges)
    }
}
