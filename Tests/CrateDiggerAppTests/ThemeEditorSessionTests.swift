import CrateDiggerCore
import XCTest
@testable import CrateDiggerApp

/// The theme editor panel's routes out of a theme: closing, NEW, crossing
/// between Simple and Advanced, and the questions each asks first. Uses a
/// temp Themes folder and puts `selectedThemeID` back afterwards.
@MainActor
final class ThemeEditorSessionTests: XCTestCase {
    private var themesDirectory: URL!
    private var registry: ThemeRegistry!
    private var session: ThemeEditorSession!
    private var savedSelection: String?
    private var dismissed = 0

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedSelection = PreferencesStore.shared.selectedThemeID
        themesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThemeEditorSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: themesDirectory, withIntermediateDirectories: true)
        try ThemeAuthoringService(themesDirectory: themesDirectory).save(ThemeDefinition(
            id: "base-theme", name: "Base Theme", baseAppearance: .dark,
            colors: ["chassis": "#111111", "ink": "#EEEEEE", "orange": "#E07020"]
        ))
        registry = ThemeRegistry(loader: ThemeLoaderService(
            bundle: Bundle(for: type(of: self)),
            userThemesDirectoryOverride: themesDirectory
        ))
        session = ThemeEditorSession(registry: registry)
        dismissed = 0
        session.dismiss = { [weak self] in self?.dismissed += 1 }
    }

    override func tearDownWithError() throws {
        PreferencesStore.shared.selectedThemeID = savedSelection
        if let themesDirectory { try? FileManager.default.removeItem(at: themesDirectory) }
        try super.tearDownWithError()
    }

    private func manifest(_ id: String) throws -> ThemeManifest {
        try XCTUnwrap(registry.manifests.first { $0.id == id })
    }

    /// A Simple editor on a NEW theme from Base Theme, with one unapplied edit.
    private func startEditedNew() throws -> SimpleThemeEditor {
        session.startNew(from: try manifest("base-theme"))
        let editor = try XCTUnwrap(session.simple)
        editor.edit { $0.contrast = .high }
        XCTAssertTrue(editor.hasUnappliedChanges)
        return editor
    }

    private func choose(_ label: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let prompt = try XCTUnwrap(session.prompt, "no question is up", file: file, line: line)
        let choice = try XCTUnwrap(prompt.choices.first { $0.label == label },
                                   "no \(label) in \(prompt.choices.map(\.label))", file: file, line: line)
        session.answer(choice)
    }

    private var labels: [String] { session.prompt?.choices.map(\.label) ?? [] }

    // MARK: Closing

    func testCloseWithUnappliedChangesAsks() throws {
        _ = try startEditedNew()
        XCTAssertFalse(session.shouldClose())
        XCTAssertEqual(labels, ["DISCARD", "CANCEL", "APPLY"])
        XCTAssertEqual(dismissed, 0)
        XCTAssertNil(registry.draft, "Simple never touches the app's draft")
    }

    func testCloseWithoutChangesDoesNotAsk() throws {
        session.startNew(from: try manifest("base-theme"))
        XCTAssertTrue(session.shouldClose())
        XCTAssertNil(session.prompt)
    }

    func testDiscardThenCloses() throws {
        _ = try startEditedNew()
        XCTAssertFalse(session.shouldClose())
        try choose("DISCARD")
        XCTAssertEqual(dismissed, 1)
        XCTAssertNil(session.simple)
        XCTAssertNil(session.prompt)
    }

    func testCancelKeepsEditing() throws {
        let editor = try startEditedNew()
        XCTAssertFalse(session.shouldClose())
        try choose("CANCEL")
        XCTAssertEqual(dismissed, 0)
        XCTAssertTrue(session.simple === editor)
        XCTAssertTrue(editor.hasUnappliedChanges)
    }

    func testApplyThenCloses() throws {
        _ = try startEditedNew()
        XCTAssertFalse(session.shouldClose())
        try choose("APPLY")
        XCTAssertEqual(dismissed, 1)
        XCTAssertEqual(PreferencesStore.shared.selectedThemeID, "new-theme")
        XCTAssertNotNil(registry.manifest(for: "new-theme"))
    }

    // MARK: NEW

    func testNewWhileUnappliedAsks() throws {
        let editor = try startEditedNew()
        session.startNew(from: try manifest("base-theme"))
        XCTAssertNotNil(session.prompt)
        XCTAssertTrue(session.simple === editor, "nothing replaced before the answer")
        try choose("DISCARD")
        XCTAssertNotNil(session.simple)
        XCTAssertFalse(session.simple === editor)
    }

    func testNewFromChangedAdvancedDraftAsksSaveDiscardCancel() throws {
        registry.beginEditing(try manifest("base-theme"))
        registry.setDraftColor("orange", "#123456")
        XCTAssertTrue(session.advancedDraftHasChanges)
        session.startNew(from: try manifest("base-theme"))
        XCTAssertEqual(labels, ["DISCARD", "CANCEL", "SAVE"])
        XCTAssertNil(session.simple)
        try choose("CANCEL")
        XCTAssertNotNil(registry.draft, "Cancel keeps the Advanced draft")
    }

    // MARK: Crossing

    func testSimpleToAdvancedOffersCopyCancelConvert() throws {
        _ = try startEditedNew()
        session.cross(to: .advanced)
        XCTAssertEqual(labels, ["COPY", "CANCEL", "CONVERT"])
    }

    func testCopyToAdvancedMakesANewDraftAndLeavesSimple() throws {
        let editor = try startEditedNew()
        let candidate = editor.candidate
        session.cross(to: .advanced)
        try choose("COPY")
        XCTAssertNil(session.simple)
        let draft = try XCTUnwrap(registry.draft)
        XCTAssertNotEqual(draft.id, candidate.id)
        XCTAssertEqual(draft.name, "\(candidate.name) Copy")
        XCTAssertNil(draft.simple)
        XCTAssertTrue(session.advancedDraftHasChanges, "an unsaved copy is unsaved work")
    }

    func testConvertKeepsIdentityAndCountsAsUnsaved() throws {
        let editor = try startEditedNew()
        let candidate = editor.candidate
        session.cross(to: .advanced)
        try choose("CONVERT")
        XCTAssertNil(session.simple)
        let draft = try XCTUnwrap(registry.draft)
        XCTAssertEqual(draft.id, candidate.id)
        XCTAssertEqual(draft.name, candidate.name)
        XCTAssertNil(draft.simple)
        XCTAssertEqual(registry.undoDepth, 0)
        // Never applied, so there is no file and no undo history: only the
        // session's own record says this is unsaved.
        XCTAssertNil(registry.manifest(for: draft.id))
        XCTAssertTrue(session.advancedDraftHasChanges)

        session.startNew(from: try manifest("base-theme"))
        XCTAssertEqual(labels, ["DISCARD", "CANCEL", "SAVE"], "a later NEW must not drop the converted theme silently")
    }

    func testAdvancedToSimpleOffersCopyOnly() throws {
        registry.beginEditing(try manifest("base-theme"))
        session.cross(to: .simple)
        XCTAssertEqual(labels, ["CANCEL", "COPY"])
    }

    func testAdvancedToSimpleCopyWithoutChangesCopiesSavedTheme() throws {
        registry.beginEditing(try manifest("base-theme"))
        session.cross(to: .simple)
        try choose("COPY")
        XCTAssertNil(session.prompt)
        XCTAssertNil(registry.draft)
        let editor = try XCTUnwrap(session.simple)
        XCTAssertEqual(editor.candidate.name, "Base Theme Copy")
        XCTAssertNil(editor.candidate.inherits, "a Simple theme is self-contained")
    }

    func testAdvancedToSimpleCopyWithUnsavedWorkAsksFirst() throws {
        registry.beginEditing(try manifest("base-theme"))
        registry.setDraftColor("orange", "#123456")
        session.cross(to: .simple)
        try choose("COPY")
        XCTAssertEqual(labels, ["DISCARD", "CANCEL", "SAVE"])
        XCTAssertNil(session.simple, "nothing copied before the answer")

        try choose("SAVE")
        XCTAssertNil(registry.draft)
        let editor = try XCTUnwrap(session.simple)
        XCTAssertNil(editor.candidate.inherits)
        let saved = try manifest("base-theme").definition
        XCTAssertEqual(saved.colors?["orange"], "#123456", "Save put the work in the file the copy is made from")
    }

    func testAdvancedToSimpleCopyCancelledKeepsDraft() throws {
        registry.beginEditing(try manifest("base-theme"))
        registry.setDraftColor("orange", "#123456")
        session.cross(to: .simple)
        try choose("COPY")
        try choose("CANCEL")
        XCTAssertNil(session.simple)
        XCTAssertEqual(registry.draftColor("orange"), "#123456")
    }

    func testPromptChoicesFollowMacOrder() {
        let order = ThemeEditorPrompt.Choice.inMacOrder([
            .init(label: "CANCEL", role: .cancel) {},
            .init(label: "PRIMARY", role: .primary) {},
            .init(label: "OTHER", role: .plain) {},
        ]).map(\.label)
        XCTAssertEqual(order, ["OTHER", "CANCEL", "PRIMARY"])
    }

    // MARK: Registry

    func testBeginAdvancedConversionKeepsIdNameAndFillsTokens() throws {
        let seed = registry.newSimpleSeed(from: try manifest("base-theme"))
        XCTAssertNotNil(seed.simple)
        registry.beginEditing(try manifest("base-theme"))
        registry.setDraftColor("orange", "#123456")
        XCTAssertGreaterThan(registry.undoDepth, 0)

        registry.beginAdvancedConversion(of: seed)
        let draft = try XCTUnwrap(registry.draft)
        XCTAssertEqual(draft.id, seed.id)
        XCTAssertEqual(draft.name, seed.name)
        XCTAssertNil(draft.inherits, "a converted Simple theme stays self-contained")
        XCTAssertNil(draft.logo)
        XCTAssertNil(registry.draftLogo, "a Simple theme shows its name, and so does its conversion")
        XCTAssertNil(draft.simple)
        XCTAssertEqual(registry.undoDepth, 0, "the draft open before is not an undo step of the conversion")
        // Every token is filled in, as the candidate draws it.
        let drawn = registry.previewTheme(for: seed, appearance: .dark).theme
        XCTAssertEqual(draft.colors?["chassis"]?.uppercased(), drawn.chassis.themeHexString.uppercased())
        XCTAssertGreaterThan(draft.colors?.count ?? 0, 20)
    }

    func testAdvancedCopyOfSimpleCarriesNoLogoOrParent() throws {
        let candidate = registry.newSimpleSeed(from: try manifest("base-theme"))
        registry.beginAdvancedCopy(of: candidate)
        let draft = try XCTUnwrap(registry.draft)
        XCTAssertNil(draft.inherits)
        XCTAssertNil(draft.logo)
        XCTAssertNil(draft.light?.logo)
        XCTAssertNil(draft.dark?.logo)
        XCTAssertNil(registry.draftLogo)
        XCTAssertNil(draft.simple)
    }

    func testNewStartsThePreviewOnTheLookOnScreen() throws {
        try ThemeAuthoringService(themesDirectory: themesDirectory).save(ThemeDefinition(
            id: "both-theme", name: "Both Theme", baseAppearance: .dark,
            colors: ["chassis": "#101820"],
            light: ThemeVariant(colors: ["chassis": "#EEF2F5"]), dark: ThemeVariant()
        ))
        registry.refresh()
        for screen in [ThemeDefinition.BaseAppearance.light, .dark] {
            session.onScreen = screen
            session.startNew(from: try manifest("both-theme"))
            if session.prompt != nil { try choose("DISCARD") }
            let editor = try XCTUnwrap(session.simple)
            XCTAssertEqual(editor.choices.appearance, .both)
            XCTAssertEqual(editor.previewAppearance, screen, "the preview opens on the look on screen")
        }
    }
}
