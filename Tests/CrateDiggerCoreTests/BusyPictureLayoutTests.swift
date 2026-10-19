#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

/// Where a pane puts its picture, and when it drops it so the cell rail and
/// the readout keep their room.
final class BusyPictureLayoutTests: XCTestCase {
    func testDefaultBandGives220By76AtTheGivenLeading() {
        let frame = BusyPictureLayout.frame(bandSize: CGSize(width: 838, height: 85),
                                            leading: 345, topInset: 9)
        XCTAssertEqual(frame, CGRect(x: 345, y: 9, width: 220, height: 76))
    }

    func testATallBandCapsTheHeightAt84() {
        let frame = BusyPictureLayout.frame(bandSize: CGSize(width: 838, height: 200),
                                            leading: 345, topInset: 9)
        XCTAssertEqual(frame?.height, 84)
    }

    func testAShortBandDropsThePicture() {
        XCTAssertNil(BusyPictureLayout.frame(bandSize: CGSize(width: 838, height: 45),
                                             leading: 345, topInset: 9),
                     "45 − 9 = 36 < 40")
        XCTAssertNotNil(BusyPictureLayout.frame(bandSize: CGSize(width: 838, height: 49),
                                                leading: 345, topInset: 9),
                        "49 − 9 = 40 is just enough")
    }

    func testANarrowBandDropsThePictureToKeepTheReadout() {
        XCTAssertNil(BusyPictureLayout.frame(bandSize: CGSize(width: 700, height: 85),
                                             leading: 345, topInset: 9),
                     "700 − 565 = 135 < 174")
        XCTAssertNotNil(BusyPictureLayout.frame(bandSize: CGSize(width: 739, height: 85),
                                                leading: 345, topInset: 9),
                        "739 − 565 = 174 is just enough")
    }
}
#endif
