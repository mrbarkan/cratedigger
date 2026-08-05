#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class ArtworkCropTests: XCTestCase {

    func testIdentityChangesNothing() {
        XCTAssertTrue(ArtworkCrop.identity.isIdentity)
        XCTAssertEqual(ArtworkCrop.identity.scale, 1)
        XCTAssertEqual(ArtworkCrop.identity.rotationDegrees, 0)
        XCTAssertFalse(ArtworkCrop(rotationDegrees: 3).isIdentity)
        XCTAssertFalse(ArtworkCrop(scale: 1.2).isIdentity)
        XCTAssertFalse(ArtworkCrop(offsetX: 0.1).isIdentity)
    }

    /// Bounds exist so a mis-drag stays recoverable — a scan zoomed to 40× or
    /// pushed three frames away shows nothing to drag back.
    func testClampingKeepsTheImageReachable() {
        let wild = ArtworkCrop(rotationDegrees: 20, scale: 40, offsetX: 9, offsetY: -9).clamped
        XCTAssertEqual(wild.scale, ArtworkCrop.scaleRange.upperBound)
        XCTAssertEqual(wild.offsetX, ArtworkCrop.offsetRange.upperBound)
        XCTAssertEqual(wild.offsetY, ArtworkCrop.offsetRange.lowerBound)

        let tiny = ArtworkCrop(scale: 0.01).clamped
        XCTAssertEqual(tiny.scale, ArtworkCrop.scaleRange.lowerBound)
    }

    func testRotationWrapsIntoASingleTurn() {
        XCTAssertEqual(ArtworkCrop.normalizedRotation(370), 10, accuracy: 0.0001)
        XCTAssertEqual(ArtworkCrop.normalizedRotation(-350), 10, accuracy: 0.0001)
        XCTAssertEqual(ArtworkCrop.normalizedRotation(-90), 270, accuracy: 0.0001)
        XCTAssertEqual(ArtworkCrop.normalizedRotation(720), 0, accuracy: 0.0001)
        XCTAssertEqual(ArtworkCrop.normalizedRotation(.nan), 0)
    }

    /// A slider should read 350° as −10°, the shortest way back to upright.
    func testSignedRotationTakesTheShortWayRound() {
        XCTAssertEqual(ArtworkCrop(rotationDegrees: 350).signedRotation, -10, accuracy: 0.0001)
        XCTAssertEqual(ArtworkCrop(rotationDegrees: 10).signedRotation, 10, accuracy: 0.0001)
        XCTAssertEqual(ArtworkCrop(rotationDegrees: 180).signedRotation, 180, accuracy: 0.0001)
        XCTAssertEqual(ArtworkCrop(rotationDegrees: 181).signedRotation, -179, accuracy: 0.0001)
    }

    /// Offsets are normalized so a cut set on a small preview holds when the
    /// same disc is drawn large.
    func testOffsetsScaleWithTheFrame() {
        let crop = ArtworkCrop(offsetX: 0.25, offsetY: -0.5)
        let small = crop.pixelOffset(in: 200)
        let large = crop.pixelOffset(in: 800)
        XCTAssertEqual(small.x, 50, accuracy: 0.0001)
        XCTAssertEqual(large.x, 200, accuracy: 0.0001)
        XCTAssertEqual(large.y, -400, accuracy: 0.0001)
    }

    func testDragTranslatesIntoNormalizedOffset() {
        let nudged = ArtworkCrop.identity.nudged(byX: 40, y: -20, in: 400)
        XCTAssertEqual(nudged.offsetX, 0.1, accuracy: 0.0001)
        XCTAssertEqual(nudged.offsetY, -0.05, accuracy: 0.0001)
    }

    func testDragOnAZeroSizedFrameIsIgnored() {
        XCTAssertEqual(ArtworkCrop.identity.nudged(byX: 10, y: 10, in: 0), .identity)
    }

    func testZoomAndRotateCompose() {
        let crop = ArtworkCrop.identity.zoomed(by: 2).rotated(by: 90).rotated(by: 300)
        XCTAssertEqual(crop.scale, 2, accuracy: 0.0001)
        XCTAssertEqual(crop.rotationDegrees, 30, accuracy: 0.0001, "90 + 300 wraps to 30")
    }

    func testNonsenseZoomIsRejected() {
        XCTAssertEqual(ArtworkCrop.identity.zoomed(by: 0), .identity)
        XCTAssertEqual(ArtworkCrop.identity.zoomed(by: -3), .identity)
        XCTAssertEqual(ArtworkCrop.identity.zoomed(by: .infinity), .identity)
    }

    func testCodableRoundTrip() throws {
        let crop = ArtworkCrop(rotationDegrees: 12.5, scale: 1.4, offsetX: -0.2, offsetY: 0.3)
        let data = try JSONEncoder().encode(crop)
        XCTAssertEqual(try JSONDecoder().decode(ArtworkCrop.self, from: data), crop)
    }
}

final class ArtworkManifestCropTests: XCTestCase {

    func testUnsetImageReportsIdentity() {
        let manifest = ArtworkManifest()
        XCTAssertEqual(manifest.crop(for: "disc.jpg"), .identity)
    }

    func testStoringAndReadingBackACrop() {
        var manifest = ArtworkManifest()
        manifest.setCrop(ArtworkCrop(rotationDegrees: 14, scale: 1.3), for: "disc.jpg")
        XCTAssertEqual(manifest.crop(for: "disc.jpg").rotationDegrees, 14, accuracy: 0.0001)
        XCTAssertEqual(manifest.crop(for: "other.jpg"), .identity)
    }

    /// A no-op crop shouldn't leave an entry behind — resetting an image should
    /// return the manifest to the state it had before.
    func testResettingToIdentityRemovesTheEntry() {
        var manifest = ArtworkManifest()
        manifest.setCrop(ArtworkCrop(scale: 2), for: "disc.jpg")
        XCTAssertNotNil(manifest.crops)
        manifest.setCrop(.identity, for: "disc.jpg")
        XCTAssertNil(manifest.crops, "the last entry going means the map goes too")
    }

    func testStoredCropsAreClamped() {
        var manifest = ArtworkManifest()
        manifest.setCrop(ArtworkCrop(scale: 99, offsetX: 5), for: "disc.jpg")
        let stored = manifest.crop(for: "disc.jpg")
        XCTAssertEqual(stored.scale, ArtworkCrop.scaleRange.upperBound)
        XCTAssertEqual(stored.offsetX, ArtworkCrop.offsetRange.upperBound)
    }

    /// Manifests written before crops existed must still decode.
    func testOlderManifestsWithoutCropsStillDecode() throws {
        let json = #"{"roles":{"disc.jpg":"Disc"},"discSides":{"disc.jpg":"A"}}"#
        let manifest = try JSONDecoder().decode(ArtworkManifest.self, from: Data(json.utf8))
        XCTAssertNil(manifest.crops)
        XCTAssertEqual(manifest.crop(for: "disc.jpg"), .identity)
        XCTAssertEqual(manifest.roles["disc.jpg"], .disc)
    }
}
#endif
