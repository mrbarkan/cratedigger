#if canImport(XCTest)
import CrateDiggerCore
import XCTest
@testable import CrateDiggerApp

/// How a key drawn with `StyledSlab` answers a press in each style
/// (`StyledPress`): where it moves, how much it squashes, and on which curve.
final class StyledPressRuleTests: XCTestCase {

    private let depth: CGFloat = 3

    private func transform(_ style: InterfaceStyle, pressed: Bool) -> StyledPressRule.Transform {
        StyledPressRule.transform(style: style, pressed: pressed, depth: depth)
    }

    // MARK: Transform

    func testNoStyleMovesAKeyThatIsUp() {
        for style in InterfaceStyle.allCases {
            XCTAssertEqual(transform(style, pressed: false), .rest, "\(style)")
        }
    }

    func testRealHardwareDoesNothingWhenPressed() {
        XCTAssertEqual(transform(.hardware, pressed: true), .rest)
    }

    func testFlatHardwareMovesTheCapDownByItsDepth() {
        XCTAssertEqual(transform(.flatHardware, pressed: true),
                       StyledPressRule.Transform(scale: 1, x: 0, y: depth))
    }

    func testStickerMovesTheKeyOntoItsShadow() {
        XCTAssertEqual(transform(.sticker, pressed: true),
                       StyledPressRule.Transform(scale: 1, x: depth, y: depth))
    }

    func testSoftBlocksSquashesInPlace() {
        XCTAssertEqual(transform(.softBlocks, pressed: true),
                       StyledPressRule.Transform(scale: 0.95, x: 0, y: 0))
    }

    // MARK: Curve

    func testRealHardwareHasNoPressCurveOfItsOwn() {
        XCTAssertNil(StyledPressRule.curve(style: .hardware, reduceMotion: false))
        XCTAssertNil(StyledPressRule.curve(style: .hardware, reduceMotion: true))
    }

    func testSoftBlocksSpringsUnlessMotionIsReduced() {
        XCTAssertEqual(StyledPressRule.curve(style: .softBlocks, reduceMotion: false), .softPress)
        XCTAssertEqual(StyledPressRule.curve(style: .softBlocks, reduceMotion: true), .reducedMovement)
    }

    func testFlatHardwareAndStickerKeepTheKeyPressUnderReduceMotion() {
        for style in [InterfaceStyle.flatHardware, .sticker] {
            for reduce in [false, true] {
                XCTAssertEqual(StyledPressRule.curve(style: style, reduceMotion: reduce), .press,
                               "\(style) reduceMotion=\(reduce)")
            }
        }
    }
}
#endif
