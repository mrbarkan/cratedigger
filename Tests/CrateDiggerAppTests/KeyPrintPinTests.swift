import CrateDiggerCore
import SwiftUI
import XCTest
@testable import CrateDiggerApp

/// The editor seeds Key Print (`chassisInk`) at the layer's Secondary ink
/// (`ink2`), and `keyPrint` treats a Key Print equal to `ink2` as no choice.
/// That pin has to follow Secondary ink while they are equal, or the first
/// `ink2` edit would leave it behind at the old value, where it reads as a
/// deliberate Key Print and moves every small key's print. A Key Print that
/// differs from `ink2` is the author's and is never touched.
///
/// Carbon is read from the checkout into a registry whose Themes folder is that
/// checkout; nothing here saves, so no file is written.
@MainActor
final class KeyPrintPinTests: XCTestCase {
    private var registry: ThemeRegistry!
    private var originalWindow: TimeInterval!
    private let newInk2 = "#11AA33"

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalWindow = ThemeRegistry.undoCoalesceWindow
        ThemeRegistry.undoCoalesceWindow = 0
        let checkout = try XCTUnwrap(BuiltInThemeEditing.repositoryThemesDirectory)
        registry = ThemeRegistry(loader: ThemeLoaderService(bundles: [], userThemesDirectoryOverride: checkout))
    }

    override func tearDownWithError() throws {
        registry?.draft = nil
        ThemeRegistry.undoCoalesceWindow = originalWindow
        try super.tearDownWithError()
    }

    private func openCarbon(on appearance: ThemeDefinition.BaseAppearance) throws {
        let carbon = try XCTUnwrap(registry.manifests.first { $0.id == "carbon" })
        registry.beginEditing(carbon, appearance: appearance)
        registry.draftEditingAppearance = appearance
        XCTAssertEqual(registry.draft?.isAdaptive, true)
    }

    /// The draft as the app draws `appearance`'s layer (the registry itself
    /// only previews the layer being edited).
    private func theme(_ appearance: ThemeDefinition.BaseAppearance) throws -> CarbonTheme {
        let flattened = try XCTUnwrap(registry.draft).resolved(for: appearance)
        return CarbonTheme(definition: flattened, resolvedBase: flattened.baseAppearance == .dark ? .carbon : .linen)
    }

    private func assertKeysKeepTheirInks(_ appearance: ThemeDefinition.BaseAppearance,
                                         file: StaticString = #filePath, line: UInt = #line) throws {
        let drawn = try theme(appearance)
        XCTAssertEqual(drawn.keyPrint(drawn.ink3).themeHexString, drawn.ink3.themeHexString,
                       "\(appearance): keyPrint(ink3) moved", file: file, line: line)
        XCTAssertEqual(drawn.keyPrint(drawn.ink2).themeHexString, drawn.ink2.themeHexString,
                       "\(appearance): keyPrint(ink2) is not the layer's ink2", file: file, line: line)
    }

    func testEditingSecondaryInkKeepsTheSmallKeysOnTheirOwnInks() throws {
        for appearance in [ThemeDefinition.BaseAppearance.dark, .light] {
            try openCarbon(on: appearance)
            registry.setDraftColor("ink2", newInk2)
            XCTAssertEqual(try theme(appearance).ink2.themeHexString, newInk2)
            try assertKeysKeepTheirInks(appearance)
            try assertKeysKeepTheirInks(appearance == .dark ? .light : .dark)
        }
    }

    func testTheMultiColourSetterCarriesThePinToo() throws {
        try openCarbon(on: .dark)
        registry.setDraftColors(["ink2": newInk2, "ink": "#FFFFFF"], appearance: .light)
        XCTAssertEqual(try theme(.light).ink2.themeHexString, newInk2)
        try assertKeysKeepTheirInks(.light)
        try assertKeysKeepTheirInks(.dark)
    }

    /// A single-appearance draft writes the shared set, and follows there.
    func testASingleAppearanceDraftFollowsInItsSharedSet() throws {
        let flat = ThemeDefinition(id: "flat-test", name: "Flat", baseAppearance: .dark,
                                   colors: ["ink2": "#C8D4D9", "ink3": "#82929B"])
        registry.draft = ThemeRegistry.seeded(flat)
        XCTAssertEqual(registry.draft?.colors?["chassisInk"], "#C8D4D9")
        registry.setDraftColor("ink2", newInk2)
        XCTAssertEqual(registry.draft?.colors?["chassisInk"], newInk2)
    }

    func testADeliberateKeyPrintIsLeftAlone() throws {
        try openCarbon(on: .dark)
        registry.setDraftColor("chassisInk", "#ABCDEF")
        registry.setDraftColor("ink2", newInk2)
        XCTAssertEqual(registry.draftColor("chassisInk"), "#ABCDEF")
        XCTAssertEqual(try theme(.dark).keyPrint(try theme(.dark).ink3).themeHexString, "#ABCDEF")
    }

    /// An `ink2` edit and the pin moving with it are one assignment, so one
    /// undo step puts both back.
    func testOneUndoRestoresBoth() throws {
        try openCarbon(on: .dark)
        let ink2 = registry.draftColor("ink2")
        let pin = registry.draftColor("chassisInk")
        XCTAssertEqual(ink2, pin)
        registry.setDraftColor("ink2", newInk2)
        XCTAssertEqual(registry.undoDepth, 1)
        XCTAssertEqual(registry.draftColor("chassisInk"), newInk2)
        registry.undoDraftStep()
        XCTAssertEqual(registry.undoDepth, 0)
        XCTAssertEqual(registry.draftColor("ink2"), ink2)
        XCTAssertEqual(registry.draftColor("chassisInk"), pin)
    }
}
