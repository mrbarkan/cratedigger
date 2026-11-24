#if canImport(XCTest)
import CrateDiggerCore
import XCTest
@testable import CrateDiggerApp

/// Which cast shadow a part (`depthShadow`) and a piece of content or the
/// display (`contentShadow`) get in each interface style.
final class CastShadowRuleTests: XCTestCase {

    private let asked = CastShadow(radius: 18, x: 2, y: 8)

    // MARK: Parts

    func testRealHardwarePartCastsWhatWasAskedUnlessFlat() {
        XCTAssertEqual(CastShadowRule.part(asked, style: .hardware, castsShadows: true), asked)
        XCTAssertNil(CastShadowRule.part(asked, style: .hardware, castsShadows: false))
    }

    func testFlatHardwarePartCastsAShortContactShadowWhateverTheSwitch() {
        let contact = CastShadow(radius: 6 * 0.45, x: 1, y: 4 * 0.6)
        XCTAssertEqual(CastShadowRule.part(asked, style: .flatHardware, castsShadows: true), contact)
        XCTAssertEqual(CastShadowRule.part(asked, style: .flatHardware, castsShadows: false), contact)
    }

    func testFlatHardwareContactShadowKeepsSmallShadowsSmall() {
        let small = CastShadow(radius: 2, x: 0, y: 1)
        XCTAssertEqual(CastShadowRule.part(small, style: .flatHardware, castsShadows: true),
                       CastShadow(radius: 2 * 0.45, x: 0, y: 0.6))
    }

    func testSoftBlocksAndStickerPartsCastNothing() {
        for style in [InterfaceStyle.softBlocks, .sticker] {
            for flat in [true, false] {
                XCTAssertNil(CastShadowRule.part(asked, style: style, castsShadows: !flat), "\(style) flat=\(flat)")
            }
        }
    }

    // MARK: Content and the display

    func testRealHardwareContentMatchesTodaysDepthShadow() {
        for casts in [true, false] {
            XCTAssertEqual(CastShadowRule.content(asked, style: .hardware, castsShadows: casts),
                           CastShadowRule.part(asked, style: .hardware, castsShadows: casts))
        }
    }

    func testOtherStylesKeepContentShadowExactlyAsAskedEvenWithTheFlatSwitch() {
        for style in [InterfaceStyle.flatHardware, .softBlocks, .sticker] {
            for casts in [true, false] {
                XCTAssertEqual(CastShadowRule.content(asked, style: style, castsShadows: casts), asked,
                               "\(style) castsShadows=\(casts)")
            }
        }
    }
}
#endif
