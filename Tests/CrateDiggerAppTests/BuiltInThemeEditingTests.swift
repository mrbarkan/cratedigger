import CrateDiggerCore
import XCTest
@testable import CrateDiggerApp

/// The beta-only hatch that lets the editor change the shipped themes in place
/// (see `BuiltInThemeEditing`). These tests say what the flag does in both
/// positions, so closing it for the RC is one line and the suite explains the
/// consequence rather than merely going green.
final class BuiltInThemeEditingTests: XCTestCase {

    // MARK: - The flag

    /// Fails once the RC closes the hatch, at which point delete this file's
    /// open-state expectations along with the feature. Kept as an explicit
    /// assertion so the switch is never flipped by accident.
    func testTheHatchIsOpenForTheBeta() {
        XCTAssertTrue(
            BuiltInThemeEditing.isOpen,
            "the beta edits the shipped themes in place; close this for the RC"
        )
    }

    /// The whole safety argument: nothing happens without a checkout to write
    /// to, so a packaged build forks exactly as it does today.
    func testEditingIsRefusedWithoutACheckoutToWriteTo() {
        let carbon = ThemeManifest(definition: definition(id: "carbon"), origin: .builtIn)
        XCTAssertNil(
            BuiltInThemeEditing.manifestURL(forThemeID: "carbon", in: nil),
            "no directory means no destination"
        )
        XCTAssertNil(
            BuiltInThemeEditing.manifestURL(
                forThemeID: "carbon",
                in: URL(fileURLWithPath: "/nowhere/that/exists")
            )
        )
        // Editable only because this test *is* running from the checkout.
        XCTAssertEqual(
            BuiltInThemeEditing.isEditable(carbon),
            BuiltInThemeEditing.repositoryThemesDirectory != nil
        )
    }

    func testAUserThemeIsNeverTreatedAsBuiltIn() {
        let user = ThemeManifest(
            definition: definition(id: "carbon"),
            origin: .userInstalled(sourceURL: URL(fileURLWithPath: "/tmp/carbon.cdtheme/theme.json"))
        )
        XCTAssertFalse(BuiltInThemeEditing.isEditable(user))
    }

    // MARK: - Finding the file to write

    func testTheSourceThemesAreFoundInTheCheckout() throws {
        let directory = try XCTUnwrap(
            BuiltInThemeEditing.repositoryThemesDirectory,
            "these tests run from the checkout, so the source themes should be visible"
        )
        for id in ["carbon", "cobalt", "llama-97"] {
            XCTAssertNotNil(
                BuiltInThemeEditing.manifestURL(forThemeID: id, in: directory),
                "\(id) should resolve to a theme.json in Sources"
            )
        }
        XCTAssertNil(BuiltInThemeEditing.manifestURL(forThemeID: "not-a-theme", in: directory))
    }

    /// A theme's folder name is free-form, so the id has to come from inside
    /// the file. `Llama 97.cdtheme` declaring `llama-97` is the live example.
    func testTheIdIsReadFromTheFileNotTheFolderName() throws {
        let directory = try XCTUnwrap(BuiltInThemeEditing.repositoryThemesDirectory)
        let found = try XCTUnwrap(BuiltInThemeEditing.manifestURL(forThemeID: "llama-97", in: directory))
        XCTAssertEqual(found.lastPathComponent, "theme.json")
        XCTAssertNotEqual(
            found.deletingLastPathComponent().lastPathComponent,
            "llama-97.cdtheme",
            "the folder is named for people, the id for the loader"
        )
    }

    /// The edit has to reach both the checkout, which is what lasts, and the
    /// resource bundle the running app is reading, which is what redraws.
    func testAnEditIsWrittenToTheCheckoutAndTheRunningBundle() throws {
        try XCTSkipIf(BuiltInThemeEditing.repositoryThemesDirectory == nil)
        let destinations = BuiltInThemeEditing.destinations(forThemeID: "carbon")
        XCTAssertFalse(destinations.isEmpty)
        XCTAssertTrue(
            destinations.contains { $0.path.contains("/Sources/CrateDiggerApp/Resources/Themes/") },
            "the checkout is the destination that survives a rebuild; got \(destinations.map(\.path))"
        )
        XCTAssertEqual(Set(destinations).count, destinations.count, "no file written twice")
    }

    // MARK: - The mark survives the edit

    /// Opening a shipped theme in place must keep its logo on screen. The
    /// editor looks for a draft's logo beside the *user* Themes folder, where a
    /// built-in has no bundle at all, so the mark vanished the moment you
    /// pressed EDIT — the fallback is what points the preview back at the app
    /// bundle the file actually lives in.
    @MainActor
    func testAnEditedBuiltInStillPreviewsItsLogo() throws {
        let directory = try XCTUnwrap(BuiltInThemeEditing.repositoryThemesDirectory)
        // Read from the checkout (the loader calls that user-installed), then
        // re-label it as shipped — which is what it is at runtime, and the
        // origin the preview got wrong.
        let found = try XCTUnwrap(
            ThemeLoaderService(bundles: [], userThemesDirectoryOverride: directory)
                .discoverThemes().themes.first { $0.id == "carbon" }
        )
        let carbon = ThemeManifest(definition: found.definition, origin: .builtIn,
                                   logoURLs: found.logoURLs)
        try XCTSkipUnless(BuiltInThemeEditing.isEditable(carbon))
        XCTAssertNotNil(carbon.logoURL(for: .dark), "the shipped theme has a mark to keep")

        let registry = ThemeRegistry(loader: ThemeLoaderService(bundles: []))
        registry.beginEditing(carbon, appearance: .dark)
        defer { registry.draft = nil }
        XCTAssertNotNil(
            registry.resolvedTheme(for: carbon.id, appearance: .dark)?.theme.logoURL,
            "the draft lost the logo the theme was drawing a moment ago"
        )
    }

    // MARK: -

    private func definition(id: String) -> ThemeDefinition {
        ThemeDefinition(id: id, name: id.capitalized, baseAppearance: .dark)
    }
}
