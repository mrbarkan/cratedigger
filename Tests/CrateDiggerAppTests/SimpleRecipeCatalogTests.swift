#if canImport(XCTest)
import CrateDiggerCore
import XCTest
@testable import CrateDiggerApp

/// Core keeps its own list of the tokens Simple writes (it cannot see the app's
/// catalog). Every one of them has to be a real, editable colour token.
final class SimpleRecipeCatalogTests: XCTestCase {
    func testEveryWrittenTokenIsInCatalog() {
        let catalog = Set(ThemeTokenCatalog.allColorTokens.map(\.key))
        let unknown = SimplePaletteRecipe.simpleWrittenTokens.subtracting(catalog)
        XCTAssertTrue(unknown.isEmpty, "not in ThemeTokenCatalog: \(unknown.sorted())")
    }
}
#endif
