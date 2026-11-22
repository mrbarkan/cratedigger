#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// "Leave it" is remembered per device and album, so an album the user chose
/// not to touch stops coming back to the review sheet.
final class DeviceLeftAloneStoreTests: XCTestCase {
    private let kindOfBlue = DeviceAlbumIdentity(artist: "Miles Davis", album: "Kind of Blue")
    private let bitchesBrew = DeviceAlbumIdentity(artist: "Miles Davis", album: "Bitches Brew")
    private let inRainbows = DeviceAlbumIdentity(artist: "Radiohead", album: "In Rainbows")

    func testLeftAloneRoundTrip() throws {
        try withTemporaryDirectory(prefix: "left-alone") { dir in
            let store = DeviceLeftAloneStore(directory: dir)
            let profile = UUID()

            store.insert([kindOfBlue, bitchesBrew], profileID: profile)
            store.insert([inRainbows], profileID: profile)

            // A fresh store reads the same file.
            XCTAssertEqual(
                DeviceLeftAloneStore(directory: dir).load(profileID: profile),
                [kindOfBlue, bitchesBrew, inRainbows]
            )

            store.remove([bitchesBrew], profileID: profile)
            XCTAssertEqual(store.load(profileID: profile), [kindOfBlue, inRainbows])
        }
    }

    func testLeftAloneIsPerDevice() throws {
        try withTemporaryDirectory(prefix: "left-alone") { dir in
            let store = DeviceLeftAloneStore(directory: dir)
            let ipod = UUID(), stick = UUID()

            store.insert([kindOfBlue], profileID: ipod)

            XCTAssertEqual(store.load(profileID: ipod), [kindOfBlue])
            XCTAssertEqual(store.load(profileID: stick), [])
        }
    }

    func testLeftAloneClear() throws {
        try withTemporaryDirectory(prefix: "left-alone") { dir in
            let store = DeviceLeftAloneStore(directory: dir)
            let profile = UUID(), other = UUID()
            store.insert([kindOfBlue, inRainbows], profileID: profile)
            store.insert([bitchesBrew], profileID: other)

            store.clear(profileID: profile)

            XCTAssertEqual(store.load(profileID: profile), [])
            XCTAssertEqual(store.load(profileID: other), [bitchesBrew], "clearing one device leaves the others")
        }
    }

    func testRemovingTheLastAlbumLeavesNoFileBehind() throws {
        try withTemporaryDirectory(prefix: "left-alone") { dir in
            let store = DeviceLeftAloneStore(directory: dir)
            let profile = UUID()
            store.insert([kindOfBlue], profileID: profile)

            store.remove([kindOfBlue], profileID: profile)

            XCTAssertEqual(store.load(profileID: profile), [])
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            XCTAssertTrue(leftovers.isEmpty, "found \(leftovers)")
        }
    }

    func testRecordRemembersLeaveItAndForgetsAChangedAnswer() throws {
        try withTemporaryDirectory(prefix: "left-alone") { dir in
            let store = DeviceLeftAloneStore(directory: dir)
            let profile = UUID()
            store.insert([kindOfBlue, inRainbows], profileID: profile)

            // Kind of Blue was left alone before and is now replaced; Bitches
            // Brew is left alone for the first time; In Rainbows is not answered.
            store.record([kindOfBlue: .replace, bitchesBrew: .leave],
                         kinds: [kindOfBlue: .sameRelease, bitchesBrew: .differentRelease], profileID: profile)

            XCTAssertEqual(store.load(profileID: profile), [bitchesBrew, inRainbows])

            store.record([bitchesBrew: .keepBoth], kinds: [bitchesBrew: .differentRelease], profileID: profile)
            XCTAssertEqual(store.load(profileID: profile), [inRainbows])
        }
    }

    /// A Leave it for a name taken by an unknown file says nothing about the
    /// album: remembered, it would silently leave alone a later real upgrade.
    func testLeaveItForATakenNameIsNotRemembered() throws {
        try withTemporaryDirectory(prefix: "left-alone") { dir in
            let store = DeviceLeftAloneStore(directory: dir)
            let profile = UUID()
            store.insert([inRainbows], profileID: profile)

            store.record([kindOfBlue: .leave, inRainbows: .leave, bitchesBrew: .leave],
                         kinds: [kindOfBlue: .pathTaken, inRainbows: .pathTaken, bitchesBrew: .sameRelease],
                         profileID: profile)

            XCTAssertEqual(store.load(profileID: profile), [bitchesBrew, inRainbows],
                           "Kind of Blue is not remembered; In Rainbows keeps what it had")
        }
    }

    func testUnreadableFileLoadsEmpty() throws {
        try withTemporaryDirectory(prefix: "left-alone") { dir in
            let profile = UUID()
            try Data("not json".utf8).write(to: dir.appendingPathComponent("\(profile.uuidString).json"))

            XCTAssertEqual(DeviceLeftAloneStore(directory: dir).load(profileID: profile), [])
        }
    }
}
#endif
