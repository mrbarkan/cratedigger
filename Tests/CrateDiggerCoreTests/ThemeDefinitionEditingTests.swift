import XCTest
@testable import CrateDiggerCore

/// Editing a shipped theme in place: the diff must be exactly what the author
/// touched, and laying it back over the file must leave everything else alone.
/// The tokens a theme deliberately leaves unset are the ones at risk — the
/// screen lamps follow the accent until something pins them, and a save that
/// writes them out freezes that away silently.
final class ThemeDefinitionEditingTests: XCTestCase {

    /// A shipped theme: a few shared tokens, and a value per appearance.
    private func shipped() -> ThemeDefinition {
        ThemeDefinition(
            id: "carbon",
            name: "Carbon",
            author: "CrateDigger",
            version: "2.0",
            baseAppearance: .dark,
            colors: ["onAir": "#FF5B4A"],
            light: ThemeVariant(colors: ["chassis": "#F5F8FA", "orange": "#FF6236"]),
            dark: ThemeVariant(colors: ["chassis": "#171C22", "orange": "#FF6D3F"])
        )
    }

    /// What the editor hands the registry: every token filled in, whether the
    /// file declared it or not.
    private func seeded(from theme: ThemeDefinition) -> ThemeDefinition {
        var draft = theme
        draft.colors = (theme.colors ?? [:]).merging([
            "lampNow": "#F4CA54",
            "lampScan": "#45C7BD",
            "transportLamp": "#FF6D3F"
        ]) { current, _ in current }
        draft.geometry = ["keyHeight": 30, "wellPadding": 8]
        return draft
    }

    // MARK: - The diff

    func testAnUntouchedDraftChangesNothing() {
        let theme = shipped()
        let seed = seeded(from: theme)
        let changes = seed.tokensChanged(from: seed)

        XCTAssertNil(changes.colors)
        XCTAssertNil(changes.geometry)
        XCTAssertEqual(changes.light?.colors ?? [:], [:])
        XCTAssertEqual(changes.dark?.colors ?? [:], [:])
    }

    func testOnlyTheEditedTokenIsRecorded() {
        let seed = seeded(from: shipped())
        var edited = seed
        edited.dark?.colors?["chassis"] = "#101418"

        let changes = edited.tokensChanged(from: seed)
        XCTAssertEqual(changes.dark?.colors, ["chassis": "#101418"])
        XCTAssertNil(changes.colors, "a shared token nobody touched should not appear")
        XCTAssertEqual(changes.light?.colors ?? [:], [:], "the other appearance is untouched")
    }

    /// The reason this pair exists at all.
    func testUnsetLampTokensSurviveAnUnrelatedEdit() {
        let theme = shipped()
        let seed = seeded(from: theme)
        var edited = seed
        edited.dark?.colors?["chassis"] = "#101418"

        let result = theme.merging(edited.tokensChanged(from: seed))

        XCTAssertNil(result.colors?["lampNow"], "an unset lamp must stay unset and keep following the accent")
        XCTAssertNil(result.colors?["transportLamp"])
        XCTAssertNil(result.geometry, "geometry the theme never declared should not appear either")
    }

    /// Reformatting is not editing.
    func testRecasedHexIsNotAChange() {
        let seed = seeded(from: shipped())
        var edited = seed
        edited.dark?.colors?["chassis"] = "#171c22"
        XCTAssertEqual(edited.tokensChanged(from: seed).dark?.colors ?? [:], [:])
    }

    /// An appearance layer that changed nothing stays present: `light`/`dark`
    /// being non-nil is what marks a theme adaptive.
    func testAnUnchangedLayerStaysPresent() {
        let seed = seeded(from: shipped())
        let changes = seed.tokensChanged(from: seed)
        XCTAssertNotNil(changes.light)
        XCTAssertNotNil(changes.dark)
        XCTAssertTrue(changes.isAdaptive)
    }

    // MARK: - The overlay

    func testMergingReplacesOnlyWhatItCarries() {
        let theme = shipped()
        let patch = ThemeDefinition(
            id: "ignored", name: "Ignored", baseAppearance: .dark,
            dark: ThemeVariant(colors: ["chassis": "#101418"])
        )
        let result = theme.merging(patch)

        XCTAssertEqual(result.dark?.colors?["chassis"], "#101418")
        XCTAssertEqual(result.dark?.colors?["orange"], "#FF6D3F", "untouched tokens survive")
        XCTAssertEqual(result.light?.colors?["chassis"], "#F5F8FA", "the other layer survives")
        XCTAssertEqual(result.colors?["onAir"], "#FF5B4A", "shared tokens survive")
    }

    func testMergingNeverRenamesTheThemeItPatches() {
        let theme = shipped()
        let patch = ThemeDefinition(id: "carbon-copy", name: "Carbon Copy",
                                    baseAppearance: .dark, inherits: "carbon")
        let result = theme.merging(patch)

        XCTAssertEqual(result.id, "carbon")
        XCTAssertEqual(result.name, "Carbon")
        XCTAssertEqual(result.author, "CrateDigger")
        XCTAssertEqual(result.version, "2.0")
        XCTAssertNil(result.inherits, "a built-in is a root theme and stays one")
    }

    /// End to end: seed, edit one colour, patch the file, and the file should
    /// differ by exactly that colour.
    func testAnEditRoundTripsAsASingleTokenChange() throws {
        let theme = shipped()
        let seed = seeded(from: theme)
        var edited = seed
        edited.light?.colors?["orange"] = "#FF8800"

        let result = theme.merging(edited.tokensChanged(from: seed))

        XCTAssertEqual(result.light?.colors?["orange"], "#FF8800")
        XCTAssertEqual(result.light?.colors?["chassis"], theme.light?.colors?["chassis"])
        XCTAssertEqual(result.dark?.colors, theme.dark?.colors)
        XCTAssertEqual(result.colors, theme.colors)
    }
}
