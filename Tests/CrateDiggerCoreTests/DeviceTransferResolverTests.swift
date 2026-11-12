#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// The resolver against a temp-dir "device" holding real (empty) files: the
/// file plan is what a transfer writes and deletes on a real player, so every
/// test reads it back as paths relative to the mounted root.
final class DeviceTransferResolverTests: XCTestCase {
    private let resolver = DeviceTransferResolver()
    private var scratch: URL!
    private var device: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceTransferResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // /var → /private/var once, so planned and catalog paths agree.
        scratch = base.resolvingSymlinksInPath()
        device = scratch.appendingPathComponent("IPOD", isDirectory: true)
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - New, Gaps, Present

    func testNewAlbumPlansNaturalPaths() throws {
        let profile = copyProfile()
        let review = resolver.review(sending: sent([1, 2]), catalog: [], profile: profile, mountedAt: device, leftAlone: [])

        XCTAssertEqual(review.albums.map(\.status), [.new])
        XCTAssertTrue(review.needingDecision.isEmpty)
        XCTAssertEqual(review.newTrackCount, 2)
        XCTAssertEqual(review.presentTrackCount, 0)

        let plan = try resolver.resolve(review, decisions: [:], profile: profile, mountedAt: device)
        XCTAssertEqual(relative(plan.copies), [
            "Music/Miles Davis/1959/Kind of Blue/01 Track 1.flac",
            "Music/Miles Davis/1959/Kind of Blue/02 Track 2.flac"
        ])
        XCTAssertEqual(plan.copies.map(\.kind), [.new, .new])
        XCTAssertEqual(plan.copies.map(\.overwrites), [false, false])
        XCTAssertTrue(plan.deletions.isEmpty)
        XCTAssertTrue(plan.coverFolders.isEmpty, "folder art is off on this profile")
    }

    func testGapsLandInExistingDeviceFolderEvenWhenTemplateDiffers() throws {
        let profile = copyProfile()
        // Filed under an older Artist/Album template; the profile now plans Artist/Year/Album.
        let onDevice = try deviceAlbum("Music/Miles Davis/Kind of Blue", numbers: [1, 2])

        let review = resolver.review(sending: sent([1, 2, 3, 4]), catalog: onDevice, profile: profile,
                                     mountedAt: device, leftAlone: [])
        XCTAssertEqual(review.albums.map(\.status), [.gaps])
        XCTAssertEqual(review.gapAlbumCount, 1)
        XCTAssertEqual(review.presentTrackCount, 2)

        let plan = try resolver.resolve(review, decisions: [:], profile: profile, mountedAt: device)
        XCTAssertEqual(relative(plan.copies), [
            "Music/Miles Davis/Kind of Blue/03 Track 3.flac",
            "Music/Miles Davis/Kind of Blue/04 Track 4.flac"
        ])
        XCTAssertEqual(plan.copies.map(\.kind), [.gap, .gap])
        XCTAssertEqual(plan.copies.map(\.overwrites), [false, false])
        XCTAssertTrue(plan.deletions.isEmpty)
        XCTAssertEqual(plan.gapAlbums, 1)
        XCTAssertEqual(plan.skippedPresent, 2)
    }

    func testGapsUseTheDeviceDiscFolders() throws {
        let profile = copyProfile()
        let onDevice = try deviceAlbum("Music/Miles Davis/Kind of Blue/CD1", disc: 1, numbers: [1, 2])
            + deviceAlbum("Music/Miles Davis/Kind of Blue/CD2", disc: 2, numbers: [1])
        let sending = sent([1, 2, 3], folder: "Src/Kind of Blue/Disc 1", disc: 1)
            + sent([1, 2], folder: "Src/Kind of Blue/Disc 2", disc: 2)
            + sent([1], folder: "Src/Kind of Blue/Disc 3", disc: 3)

        let review = resolver.review(sending: sending, catalog: onDevice, profile: profile, mountedAt: device, leftAlone: [])
        XCTAssertEqual(review.albums.map(\.status), [.gaps])
        XCTAssertEqual(review.albums.first?.deviceFolder?.lastPathComponent, "Kind of Blue")

        let plan = try resolver.resolve(review, decisions: [:], profile: profile, mountedAt: device)
        XCTAssertEqual(relative(plan.copies), [
            "Music/Miles Davis/Kind of Blue/CD1/03 Track 3.flac",
            "Music/Miles Davis/Kind of Blue/CD2/02 Track 2.flac",
            // No disc 3 on the device yet: the album folder, as the template would file it.
            "Music/Miles Davis/Kind of Blue/01 Track 1.flac"
        ])
    }

    func testGapsInFlatLayoutArePlannedNormally() throws {
        let profile = copyProfile(.flat)
        let onDevice = try deviceAlbum("Music/Old/Kind of Blue", numbers: [1])

        let review = resolver.review(sending: sent([1, 2]), catalog: onDevice, profile: profile, mountedAt: device, leftAlone: [])
        XCTAssertEqual(review.albums.map(\.status), [.gaps])

        let plan = try resolver.resolve(review, decisions: [:], profile: profile, mountedAt: device)
        XCTAssertEqual(relative(plan.copies), ["Music/02 Track 2.flac"])
    }

    func testPresentPlansNothing() throws {
        let profile = copyProfile()
        let onDevice = try deviceAlbum("Music/Miles Davis/Kind of Blue", numbers: [1, 2, 3])

        let review = resolver.review(sending: sent([1, 2]), catalog: onDevice, profile: profile, mountedAt: device, leftAlone: [])
        XCTAssertEqual(review.albums.map(\.status), [.present])
        XCTAssertEqual(review.presentTrackCount, 2)
        XCTAssertTrue(review.needingDecision.isEmpty)

        let plan = try resolver.resolve(review, decisions: [:], profile: profile, mountedAt: device)
        XCTAssertTrue(plan.copies.isEmpty)
        XCTAssertTrue(plan.deletions.isEmpty)
        XCTAssertEqual(plan.skippedPresent, 2)
    }

    // MARK: - Replace

    func testReplaceSameReleaseSwapsOnlyMatchedTracks() throws {
        let profile = copyProfile()
        let onDevice = try deviceAlbum("Music/Miles Davis/Kind of Blue", numbers: [1, 2, 3, 4, 5],
                                       format: "MP3", bitrate: 128, ext: "mp3")

        let review = resolver.review(sending: sent([1, 2, 6]), catalog: onDevice, profile: profile, mountedAt: device, leftAlone: [])
        XCTAssertEqual(review.albums.map(\.status), [.differs])
        XCTAssertEqual(review.albums.first?.differences, [.audioForm])
        XCTAssertEqual(review.needingDecision.count, 1)

        let plan = try resolver.resolve(review, decisions: decide(review, .replace), profile: profile, mountedAt: device)
        XCTAssertEqual(relative(plan.copies), [
            "Music/Miles Davis/Kind of Blue/01 Track 1.flac",
            "Music/Miles Davis/Kind of Blue/02 Track 2.flac",
            "Music/Miles Davis/Kind of Blue/06 Track 6.flac"
        ])
        XCTAssertEqual(plan.copies.map(\.kind), [.replacement, .replacement, .replacement])
        XCTAssertEqual(plan.copies.map(\.overwrites), [false, false, false])
        // Only the two MP3s that have a counterpart go; 3, 4 and 5 stay.
        XCTAssertEqual(relative(plan.deletions), [
            "Music/Miles Davis/Kind of Blue/01 Track 1.mp3",
            "Music/Miles Davis/Kind of Blue/02 Track 2.mp3"
        ])
        XCTAssertEqual(plan.replacedAlbums, 1)
    }

    func testReplaceSamePathOverwritesAndDoesNotDelete() throws {
        let profile = convertProfile()
        let onDevice = try deviceAlbum("Music/Miles Davis/Kind of Blue", numbers: [1, 2],
                                       format: "MP3", bitrate: 192, ext: "mp3", art: 600)

        let review = resolver.review(sending: sent([1, 2], art: 1400), catalog: onDevice, profile: profile,
                                     mountedAt: device, leftAlone: [])
        XCTAssertEqual(review.albums.first?.differences, [.artSize])

        let plan = try resolver.resolve(review, decisions: decide(review, .replace), profile: profile, mountedAt: device)
        XCTAssertEqual(relative(plan.copies), [
            "Music/Miles Davis/Kind of Blue/01 Track 1.mp3",
            "Music/Miles Davis/Kind of Blue/02 Track 2.mp3"
        ])
        XCTAssertEqual(plan.copies.map(\.overwrites), [true, true])
        XCTAssertTrue(plan.deletions.isEmpty)
    }

    func testReplaceDifferentReleaseDeletesWholeDeviceAlbum() throws {
        let profile = copyProfile()
        let folder = "Music/Miles Davis/Kind of Blue"
        // Slot 1 happens to carry the name the new track 1 is written under.
        var onDevice = [try deviceTrack("\(folder)/01 Track 1.flac", number: 1, title: "Old 1")]
        onDevice += try deviceAlbum(folder, numbers: [2, 3, 4], titlePrefix: "Old")
        try makeFile("\(folder)/cover.jpg")
        try makeFile("\(folder)/notes.txt")

        let review = resolver.review(sending: sent([1, 2]), catalog: onDevice, profile: profile, mountedAt: device, leftAlone: [])
        XCTAssertEqual(review.albums.first?.differences, [.differentRelease])

        let plan = try resolver.resolve(review, decisions: decide(review, .replace), profile: profile, mountedAt: device)
        XCTAssertEqual(relative(plan.copies), ["\(folder)/01 Track 1.flac", "\(folder)/02 Track 2.flac"])
        XCTAssertEqual(plan.copies.map(\.overwrites), [true, false])
        XCTAssertEqual(relative(plan.deletions), ["\(folder)/02 Old 2.flac", "\(folder)/03 Old 3.flac", "\(folder)/04 Old 4.flac"])
    }

    func testDeletionsNeverIncludeNonAudioOrCopyDestinations() throws {
        let profile = copyProfile()
        let folder = "Music/Miles Davis/Kind of Blue"
        var onDevice = [try deviceTrack("\(folder)/01 Track 1.flac", number: 1, title: "Old 1")]
        onDevice += try deviceAlbum(folder, numbers: [2], titlePrefix: "Old")
        // A catalog that somehow lists non-audio files under the album's tags.
        onDevice.append(try deviceTrack("\(folder)/cover.jpg", number: 5, title: "Old 5"))
        onDevice.append(try deviceTrack("\(folder)/Booklet.pdf", number: 6, title: "Old 6"))

        let review = resolver.review(sending: sent([1, 2]), catalog: onDevice, profile: profile, mountedAt: device, leftAlone: [])
        let plan = try resolver.resolve(review, decisions: decide(review, .replace), profile: profile, mountedAt: device)

        let copyPaths = Set(plan.copies.map { $0.destinationURL.path.lowercased() })
        XCTAssertFalse(plan.deletions.isEmpty)
        for deletion in plan.deletions {
            XCTAssertTrue(LibraryScanService.defaultSupportedExtensions.contains(deletion.pathExtension.lowercased()),
                          "\(deletion.lastPathComponent) is not audio")
            XCTAssertFalse(copyPaths.contains(deletion.path.lowercased()), "\(deletion.lastPathComponent) is being written")
        }
        XCTAssertEqual(relative(plan.deletions), ["\(folder)/02 Old 2.flac"])
    }

    func testDeviceFilesOutsideTheMountAreNeverTouched() throws {
        let profile = copyProfile()
        // A stale catalog saved while the volume was mounted somewhere else.
        let elsewhere = scratch.appendingPathComponent("IPOD 1", isDirectory: true)
        let stale = try deviceAlbum("Music/Miles Davis/Kind of Blue", numbers: [1, 2], titlePrefix: "Old", root: elsewhere)

        let review = resolver.review(sending: sent([1, 2]), catalog: stale, profile: profile, mountedAt: device, leftAlone: [])
        XCTAssertEqual(review.albums.map(\.status), [.new], "files outside the music folder are not the device's music")

        let plan = try resolver.resolve(review, decisions: decide(review, .replace), profile: profile, mountedAt: device)
        XCTAssertTrue(plan.deletions.isEmpty)
        for copy in plan.copies {
            XCTAssertTrue(copy.destinationURL.path.hasPrefix(device.path + "/"), copy.destinationURL.path)
        }
    }

    func testDeletionsWaitForEveryCopyOfTheirAlbum() throws {
        let profile = copyProfile()
        let onDevice = try deviceAlbum("Music/Miles Davis/Kind of Blue", numbers: [1, 2],
                                       format: "MP3", bitrate: 128, ext: "mp3")
        let review = resolver.review(sending: sent([1, 2]), catalog: onDevice, profile: profile, mountedAt: device, leftAlone: [])
        let plan = try resolver.resolve(review, decisions: decide(review, .replace), profile: profile, mountedAt: device)

        XCTAssertEqual(plan.deletions(afterFailing: []), plan.deletions)
        XCTAssertTrue(plan.deletions(afterFailing: [plan.copies[1]]).isEmpty)
    }

    // MARK: - Keep both

    func testKeepBothUsesVersionFolder() throws {
        let profile = copyProfile()
        let onDevice = try deviceAlbum("Music/Miles Davis/Kind of Blue", numbers: [1, 2],
                                       format: "MP3", bitrate: 128, ext: "mp3")
        try FileManager.default.createDirectory(
            at: device.appendingPathComponent("Music/Miles Davis/Kind of Blue [2]", isDirectory: true),
            withIntermediateDirectories: true
        )

        let review = resolver.review(sending: sent([1, 2]), catalog: onDevice, profile: profile, mountedAt: device, leftAlone: [])
        let plan = try resolver.resolve(review, decisions: decide(review, .keepBoth), profile: profile, mountedAt: device)

        XCTAssertEqual(relative(plan.copies), [
            "Music/Miles Davis/Kind of Blue [3]/01 Track 1.flac",
            "Music/Miles Davis/Kind of Blue [3]/02 Track 2.flac"
        ])
        XCTAssertEqual(plan.copies.map(\.kind), [.keptBoth, .keptBoth])
        XCTAssertTrue(plan.deletions.isEmpty)
        XCTAssertEqual(plan.keptBothAlbums, 1)
    }

    func testKeepBothFlatUsesSuffix() throws {
        let profile = convertProfile(.flat)
        let onDevice = try deviceAlbum("Music", numbers: [1], format: "MP3", bitrate: 192, ext: "mp3", art: 600)

        let review = resolver.review(sending: sent([1], art: 1400), catalog: onDevice, profile: profile,
                                     mountedAt: device, leftAlone: [])
        XCTAssertEqual(review.albums.map(\.status), [.differs])

        let plan = try resolver.resolve(review, decisions: decide(review, .keepBoth), profile: profile, mountedAt: device)
        XCTAssertEqual(relative(plan.copies), ["Music/01 Track 1 (2).mp3"])
        XCTAssertEqual(plan.copies.map(\.overwrites), [false])
        XCTAssertTrue(plan.deletions.isEmpty)
    }

    func testKeepBothNeverMakesAVersionOfTheMusicFolder() throws {
        let profile = copyProfile()
        // Loose files straight in the music folder, on a template device.
        let onDevice = try deviceAlbum("Music", numbers: [1], format: "MP3", bitrate: 128, ext: "mp3")

        let review = resolver.review(sending: sent([1]), catalog: onDevice, profile: profile, mountedAt: device, leftAlone: [])
        let plan = try resolver.resolve(review, decisions: decide(review, .keepBoth), profile: profile, mountedAt: device)

        XCTAssertEqual(relative(plan.copies), ["Music/Miles Davis/1959/Kind of Blue/01 Track 1.flac"])
    }

    // MARK: - Leave it

    func testLeaveAndUndecidedPlanNothing() throws {
        let profile = copyProfile()
        let onDevice = try deviceAlbum("Music/Miles Davis/Kind of Blue", numbers: [1], format: "MP3", bitrate: 128, ext: "mp3")
            + deviceAlbum("Music/Miles Davis/Bitches Brew", album: "Bitches Brew", numbers: [1], format: "MP3", bitrate: 128, ext: "mp3")
            + deviceAlbum("Music/Miles Davis/Milestones", album: "Milestones", numbers: [1], format: "MP3", bitrate: 128, ext: "mp3")
        let sending = sent([1]) + sent([1], folder: "Src/Bitches Brew", album: "Bitches Brew")
            + sent([1], folder: "Src/Milestones", album: "Milestones")
        let remembered = DeviceAlbumIdentity(artist: "Miles Davis", album: "Milestones")

        let review = resolver.review(sending: sending, catalog: onDevice, profile: profile, mountedAt: device,
                                     leftAlone: [remembered])
        XCTAssertEqual(review.albums.map(\.status), [.differs, .differs, .differs])
        XCTAssertEqual(review.needingDecision.map(\.displayAlbum), ["Kind of Blue", "Bitches Brew"])
        XCTAssertEqual(review.leftAloneAlbumCount, 1)

        let decisions = [review.albums[0].identity: DeviceAlbumDecision.leave]
        let plan = try resolver.resolve(review, decisions: decisions, profile: profile, mountedAt: device)
        XCTAssertTrue(plan.copies.isEmpty)
        XCTAssertTrue(plan.deletions.isEmpty)
        XCTAssertEqual(plan.leftAlone, 3)
    }

    func testExplicitDecisionOverridesRememberedLeaveIt() throws {
        let profile = copyProfile()
        let onDevice = try deviceAlbum("Music/Miles Davis/Kind of Blue", numbers: [1], format: "MP3", bitrate: 128, ext: "mp3")
        let identity = DeviceAlbumIdentity(artist: "Miles Davis", album: "Kind of Blue")

        let review = resolver.review(sending: sent([1]), catalog: onDevice, profile: profile, mountedAt: device,
                                     leftAlone: [identity])
        XCTAssertTrue(review.needingDecision.isEmpty)

        let plan = try resolver.resolve(review, decisions: [identity: .replace], profile: profile, mountedAt: device)
        XCTAssertEqual(plan.copies.count, 1)
        XCTAssertEqual(plan.leftAlone, 0)
    }

    // MARK: - Taken paths

    func testTakenUnmatchedPathBecomesDiffers() throws {
        let profile = copyProfile()
        // On the device but not in the catalog: a stale catalog, or another album's file.
        try makeFile("Music/Miles Davis/1959/Kind of Blue/01 Track 1.flac")

        let review = resolver.review(sending: sent([1, 2]), catalog: [], profile: profile, mountedAt: device, leftAlone: [])
        XCTAssertEqual(review.albums.map(\.status), [.differs])
        XCTAssertEqual(review.albums.first?.differences, [.pathTaken])
        XCTAssertEqual(review.needingDecision.count, 1)
        XCTAssertEqual(review.newTrackCount, 0)

        let replaced = try resolver.resolve(review, decisions: decide(review, .replace), profile: profile, mountedAt: device)
        XCTAssertEqual(relative(replaced.copies), [
            "Music/Miles Davis/1959/Kind of Blue/01 Track 1.flac",
            "Music/Miles Davis/1959/Kind of Blue/02 Track 2.flac"
        ])
        XCTAssertEqual(replaced.copies.map(\.overwrites), [true, false])
        XCTAssertTrue(replaced.deletions.isEmpty)

        let keptBoth = try resolver.resolve(review, decisions: decide(review, .keepBoth), profile: profile, mountedAt: device)
        XCTAssertEqual(relative(keptBoth.copies), [
            "Music/Miles Davis/1959/Kind of Blue/01 Track 1 (2).flac",
            "Music/Miles Davis/1959/Kind of Blue/02 Track 2.flac"
        ])
        XCTAssertEqual(keptBoth.copies.map(\.overwrites), [false, false])

        let left = try resolver.resolve(review, decisions: decide(review, .leave), profile: profile, mountedAt: device)
        XCTAssertTrue(left.copies.isEmpty)
    }

    func testTakenPathCaseInsensitive() throws {
        // Within one batch: folded, whatever the volume.
        let flat = copyProfile(.flat)
        let first = sent([1], folder: "Src/Kind of Blue")
        let second = [track(album: "Bitches Brew", number: 1, title: "Track 1",
                            path: scratch.appendingPathComponent("Src/Bitches Brew/01 TRACK 1.flac").path)]
        let batch = resolver.review(sending: first + second, catalog: [], profile: flat, mountedAt: device, leftAlone: [])
        XCTAssertEqual(batch.albums.map(\.status), [.new, .differs])
        XCTAssertEqual(batch.albums.last?.differences, [.pathTaken])

        // Replace onto a device file that differs only in case: one file, overwritten, never deleted.
        let profile = convertProfile()
        let folder = "Music/Miles Davis/Kind of Blue"
        let onDevice = [try deviceTrack("\(folder)/01 TRACK 1.MP3", number: 1, title: "Track 1",
                                        format: "MP3", bitrate: 192, art: 600)]
        let review = resolver.review(sending: sent([1], art: 1400), catalog: onDevice, profile: profile,
                                     mountedAt: device, leftAlone: [])
        let plan = try resolver.resolve(review, decisions: decide(review, .replace), profile: profile, mountedAt: device)
        XCTAssertEqual(relative(plan.copies), ["\(folder)/01 Track 1.mp3"])
        XCTAssertTrue(plan.deletions.isEmpty)

        // On disk: only where the volume itself folds case, as FAT and exFAT do.
        guard try volumeIgnoresCase() else { return }
        XCTAssertEqual(plan.copies.map(\.overwrites), [true])
        try makeFile("Music/MILES DAVIS/1959/KIND OF BLUE/01 TRACK 1.FLAC")
        let taken = resolver.review(sending: sent([1]), catalog: [], profile: copyProfile(), mountedAt: device, leftAlone: [])
        XCTAssertEqual(taken.albums.first?.differences, [.pathTaken])
    }

    func testNoDuplicateDestinations() throws {
        // Two albums whose files share a name in a flat layout: the second is
        // asked about, and Replace never overwrites the batch's own file.
        let flat = copyProfile(.flat)
        let sending = sent([1]) + sent([1], folder: "Src/Bitches Brew", album: "Bitches Brew")
        let review = resolver.review(sending: sending, catalog: [], profile: flat, mountedAt: device, leftAlone: [])
        XCTAssertEqual(review.albums.map(\.status), [.new, .differs])
        XCTAssertEqual(review.albums.last?.differences, [.pathTaken])

        let plan = try resolver.resolve(review, decisions: [review.albums[1].identity: .replace], profile: flat, mountedAt: device)
        XCTAssertEqual(relative(plan.copies), ["Music/01 Track 1.flac", "Music/01 Track 1 (2).flac"])
        XCTAssertEqual(plan.copies.map(\.kind), [.new, .replacement])

        // One album whose two discs share file names, filed into one folder.
        let discs = sent([1], folder: "Src/Kind of Blue/Disc 1", disc: 1) + sent([1], folder: "Src/Kind of Blue/Disc 2", disc: 2)
        let template = copyProfile()
        let discReview = resolver.review(sending: discs, catalog: [], profile: template, mountedAt: device, leftAlone: [])
        XCTAssertEqual(discReview.albums.first?.differences, [.pathTaken])
        let discPlan = try resolver.resolve(discReview, decisions: decide(discReview, .keepBoth), profile: template, mountedAt: device)
        XCTAssertEqual(Set(discPlan.copies.map { $0.destinationURL.path.lowercased() }).count, 2)

        // The same file listed twice is sent once.
        let twice = sent([1, 2]) + sent([1])
        let once = try resolver.resolve(
            resolver.review(sending: twice, catalog: [], profile: template, mountedAt: device, leftAlone: []),
            decisions: [:], profile: template, mountedAt: device
        )
        XCTAssertEqual(once.copies.count, 2)
        XCTAssertEqual(once.copies.map(\.kind), [.new, .new])
    }

    // MARK: - Multi-disc

    func testKeepBothKeepsTheDeviceDiscFolders() throws {
        let profile = copyProfile()
        let onDevice = try deviceAlbum("Music/Miles Davis/Kind of Blue/CD1", disc: 1, numbers: [1],
                                       format: "MP3", bitrate: 128, ext: "mp3")
            + deviceAlbum("Music/Miles Davis/Kind of Blue/CD2", disc: 2, numbers: [1],
                          format: "MP3", bitrate: 128, ext: "mp3")
        // Both discs' files are named "01 Track 1".
        let sending = sent([1], folder: "Src/Kind of Blue/Disc 1", disc: 1)
            + sent([1], folder: "Src/Kind of Blue/Disc 2", disc: 2)

        let review = resolver.review(sending: sending, catalog: onDevice, profile: profile, mountedAt: device, leftAlone: [])
        XCTAssertEqual(review.albums.first?.differences, [.audioForm])

        let plan = try resolver.resolve(review, decisions: decide(review, .keepBoth), profile: profile, mountedAt: device)
        XCTAssertEqual(relative(plan.copies), [
            "Music/Miles Davis/Kind of Blue [2]/CD1/01 Track 1.flac",
            "Music/Miles Davis/Kind of Blue [2]/CD2/01 Track 1.flac"
        ])
        XCTAssertTrue(plan.deletions.isEmpty)
    }

    func testReplaceSameReleaseOnMultiDiscDevice() throws {
        let profile = copyProfile()
        let onDevice = try deviceAlbum("Music/Miles Davis/Kind of Blue/CD1", disc: 1, numbers: [1, 2],
                                       format: "MP3", bitrate: 128, ext: "mp3")
            + deviceAlbum("Music/Miles Davis/Kind of Blue/CD2", disc: 2, numbers: [1, 2],
                          format: "MP3", bitrate: 128, ext: "mp3")
        let sending = sent([1], folder: "Src/Kind of Blue/Disc 1", disc: 1)
            + sent([1, 3], folder: "Src/Kind of Blue/Disc 2", disc: 2)

        let review = resolver.review(sending: sending, catalog: onDevice, profile: profile, mountedAt: device, leftAlone: [])
        XCTAssertEqual(review.albums.first?.differences, [.audioForm])

        let plan = try resolver.resolve(review, decisions: decide(review, .replace), profile: profile, mountedAt: device)
        XCTAssertEqual(relative(plan.copies), [
            "Music/Miles Davis/Kind of Blue/CD1/01 Track 1.flac",
            "Music/Miles Davis/Kind of Blue/CD2/01 Track 1.flac",
            "Music/Miles Davis/Kind of Blue/CD2/03 Track 3.flac"
        ])
        // Only the matched MP3s go; each disc's track 2 stays.
        XCTAssertEqual(relative(plan.deletions), [
            "Music/Miles Davis/Kind of Blue/CD1/01 Track 1.mp3",
            "Music/Miles Davis/Kind of Blue/CD2/01 Track 1.mp3"
        ])
    }

    func testReplaceDifferentReleaseOnMultiDiscDevice() throws {
        let profile = copyProfile()
        let onDevice = try deviceAlbum("Music/Miles Davis/Kind of Blue/CD1", disc: 1, numbers: [1, 2], titlePrefix: "Old")
            + deviceAlbum("Music/Miles Davis/Kind of Blue/CD2", disc: 2, numbers: [1], titlePrefix: "Old")
        let sending = sent([1], folder: "Src/Kind of Blue/Disc 1", disc: 1)
            + sent([1], folder: "Src/Kind of Blue/Disc 2", disc: 2)

        let review = resolver.review(sending: sending, catalog: onDevice, profile: profile, mountedAt: device, leftAlone: [])
        XCTAssertEqual(review.albums.first?.differences, [.differentRelease])

        let plan = try resolver.resolve(review, decisions: decide(review, .replace), profile: profile, mountedAt: device)
        XCTAssertEqual(relative(plan.copies), [
            "Music/Miles Davis/Kind of Blue/CD1/01 Track 1.flac",
            "Music/Miles Davis/Kind of Blue/CD2/01 Track 1.flac"
        ])
        XCTAssertEqual(relative(plan.deletions), [
            "Music/Miles Davis/Kind of Blue/CD1/01 Old 1.flac",
            "Music/Miles Davis/Kind of Blue/CD1/02 Old 2.flac",
            "Music/Miles Davis/Kind of Blue/CD2/01 Old 1.flac"
        ])
    }

    // MARK: - What review cleared

    func testReplaceOverwritesOnlyWhatReviewCleared() throws {
        let profile = copyProfile()
        let folder = "Music/Miles Davis/Kind of Blue"
        let onDevice = try deviceAlbum(folder, numbers: [1, 2], format: "MP3", bitrate: 128, ext: "mp3")
        let review = resolver.review(sending: sent([1, 3]), catalog: onDevice, profile: profile, mountedAt: device, leftAlone: [])
        XCTAssertEqual(review.albums.first?.differences, [.audioForm])

        // Files that appear while the sheet is open.
        try makeFile("\(folder)/01 Track 1.flac")
        try makeFile("\(folder)/03 Track 3.flac")

        let plan = try resolver.resolve(review, decisions: decide(review, .replace), profile: profile, mountedAt: device)
        XCTAssertEqual(relative(plan.copies), ["\(folder)/01 Track 1.flac", "\(folder)/03 Track 3.flac"])
        XCTAssertEqual(plan.copies.map(\.overwrites), [false, false], "the executor must fail these, not overwrite")
    }

    func testResolveRefusesAReviewOfAnotherDestination() throws {
        let profile = copyProfile()
        let review = resolver.review(sending: sent([1]), catalog: [], profile: profile, mountedAt: device, leftAlone: [])

        let otherVolume = scratch.appendingPathComponent("IPOD 1", isDirectory: true)
        XCTAssertThrowsError(try resolver.resolve(review, decisions: [:], profile: profile, mountedAt: otherVolume)) {
            XCTAssertEqual($0 as? DeviceTransferResolver.ResolveError, .reviewedForAnotherDestination)
        }
        var otherFolder = profile
        otherFolder.musicDirectorySubpath = "Audio"
        XCTAssertThrowsError(try resolver.resolve(review, decisions: [:], profile: otherFolder, mountedAt: device)) {
            XCTAssertEqual($0 as? DeviceTransferResolver.ResolveError, .reviewedForAnotherDestination)
        }
        XCTAssertThrowsError(try resolver.resolve(review, decisions: [:], profile: copyProfile(.flat), mountedAt: device)) {
            XCTAssertEqual($0 as? DeviceTransferResolver.ResolveError, .reviewedForAnotherDestination)
        }
        XCTAssertThrowsError(try resolver.resolve(DeviceTransferReview(albums: review.albums), decisions: [:],
                                                  profile: profile, mountedAt: device)) {
            XCTAssertEqual($0 as? DeviceTransferResolver.ResolveError, .notReviewedAgainstDevice)
        }
    }

    func testUnplannableCopyIsReported() throws {
        // A review that skipped the path check: two New albums on one flat name.
        let flat = copyProfile(.flat)
        let sending = sent([1]) + sent([1], folder: "Src/Bitches Brew", album: "Bitches Brew")
        let albums = DeviceTransferMatcher().compare(sending: sending, catalog: [], settings: flat.transferSettings, leftAlone: [])
        XCTAssertEqual(albums.map(\.status), [.new, .new])
        let unchecked = DeviceTransferReview(
            albums: albums, mountedRoot: device, musicFolder: device.appendingPathComponent("Music", isDirectory: true),
            settings: flat.transferSettings, reviewedAlbumFolders: [:]
        )

        let plan = try resolver.resolve(unchecked, decisions: [:], profile: flat, mountedAt: device)
        XCTAssertEqual(relative(plan.copies), ["Music/01 Track 1.flac"])
        XCTAssertEqual(plan.unplanned.map(\.track.fileURL), [sending[1].track.fileURL])
    }

    func testBatchClashesAreFlaggedForReplaceAndKeepBoth() throws {
        let flat = copyProfile(.flat)
        // Replace: Bitches Brew's FLAC would land on the name Kind of Blue (New) takes.
        let bitches = try deviceAlbum("Music", album: "Bitches Brew", numbers: [1], format: "MP3", bitrate: 128, ext: "mp3")
        let sending = sent([1]) + sent([1], folder: "Src/Bitches Brew", album: "Bitches Brew")
        let review = resolver.review(sending: sending, catalog: bitches, profile: flat, mountedAt: device, leftAlone: [])
        XCTAssertEqual(review.albums.map(\.status), [.new, .differs])
        XCTAssertEqual(review.albums.last?.differences, [.audioForm, .pathTaken])

        let plan = try resolver.resolve(review, decisions: [review.albums[1].identity: .replace], profile: flat, mountedAt: device)
        XCTAssertEqual(relative(plan.copies), ["Music/01 Track 1.flac", "Music/01 Track 1 (2).flac"])
        XCTAssertEqual(relative(plan.deletions), ["Music/01 Track 1.mp3"])

        // Keep both: the device keeps its discs apart, but a flat Keep both
        // would write both discs' "01 Track 1.flac" into one folder.
        let discs = try deviceAlbum("Music/Old/Milestones/CD1", album: "Milestones", disc: 1, numbers: [1],
                                    format: "MP3", bitrate: 128, ext: "mp3")
            + deviceAlbum("Music/Old/Milestones/CD2", album: "Milestones", disc: 2, numbers: [1],
                          format: "MP3", bitrate: 128, ext: "mp3")
        let discSending = sent([1], folder: "Src/Milestones/Disc 1", album: "Milestones", disc: 1)
            + sent([1], folder: "Src/Milestones/Disc 2", album: "Milestones", disc: 2)
        let discReview = resolver.review(sending: discSending, catalog: discs, profile: flat, mountedAt: device, leftAlone: [])
        XCTAssertEqual(discReview.albums.first?.differences, [.audioForm, .pathTaken])
    }

    // MARK: - The music folder only

    func testMusicOutsideTheMusicFolderIsIgnored() throws {
        let profile = copyProfile()
        let backup = try deviceAlbum("Backup/Miles Davis/Kind of Blue", numbers: [1, 2],
                                     format: "MP3", bitrate: 128, ext: "mp3")

        let review = resolver.review(sending: sent([1, 2]), catalog: backup, profile: profile, mountedAt: device, leftAlone: [])
        XCTAssertEqual(review.albums.map(\.status), [.new])

        let plan = try resolver.resolve(review, decisions: [:], profile: profile, mountedAt: device)
        XCTAssertTrue(plan.deletions.isEmpty)
        XCTAssertEqual(relative(plan.copies), [
            "Music/Miles Davis/1959/Kind of Blue/01 Track 1.flac",
            "Music/Miles Davis/1959/Kind of Blue/02 Track 2.flac"
        ])
    }

    func testVolumeRootMusicFolderSkipsIPodControlAndHiddenFolders() throws {
        var profile = copyProfile()
        profile.musicDirectorySubpath = ""
        let stock = try deviceAlbum("iPod_Control/Music/F00", numbers: [1], format: "MP3", bitrate: 128, ext: "mp3")
        let trashed = try deviceAlbum(".Trashes/501/Kind of Blue", numbers: [2], format: "MP3", bitrate: 128, ext: "mp3")
        let filed = try deviceAlbum("Miles Davis/Milestones", album: "Milestones", numbers: [1])
        let sending = sent([1, 2]) + sent([1, 2], folder: "Src/Milestones", album: "Milestones")

        let review = resolver.review(sending: sending, catalog: stock + trashed + filed, profile: profile,
                                     mountedAt: device, leftAlone: [])
        XCTAssertEqual(review.albums.map(\.status), [.new, .gaps], "the filed album still matches")

        let plan = try resolver.resolve(review, decisions: [:], profile: profile, mountedAt: device)
        XCTAssertTrue(plan.deletions.isEmpty)
        XCTAssertFalse(plan.copies.contains { $0.destinationURL.path.contains("iPod_Control") })
        XCTAssertEqual(relative(plan.copies).last, "Miles Davis/Milestones/02 Track 2.flac")
    }

    // MARK: - Loose singles

    /// Forty singles under "Unknown Album" and one new one sent: the new one
    /// fills in beside them, and nothing is offered for deletion, whatever
    /// the answers.
    func testOneNewLooseSingleRemovesNothing() throws {
        let profile = copyProfile()
        let onDevice = try (1...40).map { number in
            try deviceTrack("Music/Miles Davis/Unknown Album/Single \(number).flac", album: "",
                            number: 1, title: "Single \(number)")
        }
        let single = track(album: "", number: 1, title: "New Single",
                           path: scratch.appendingPathComponent("Src/Singles/New Single.flac").path)

        let review = resolver.review(sending: [single], catalog: onDevice, profile: profile, mountedAt: device, leftAlone: [])
        XCTAssertEqual(review.albums.map(\.status), [.gaps])
        XCTAssertTrue(review.needingDecision.isEmpty)

        let plan = try resolver.resolve(review, decisions: decide(review, .replace), profile: profile, mountedAt: device)
        XCTAssertTrue(plan.deletions.isEmpty)
        XCTAssertEqual(plan.copies.map(\.kind), [.gap])
        XCTAssertEqual(relative(plan.copies), ["Music/Miles Davis/Unknown Album/New Single.flac"])
    }

    // MARK: - Covers

    func testCoverFoldersFollowTheSwitch() throws {
        var profile = convertProfile()
        profile.transferSettings.writesFolderCoverArt = true
        let tracks = sent([1, 2], art: 1400)

        let review = resolver.review(sending: tracks, catalog: [], profile: profile, mountedAt: device, leftAlone: [])
        let plan = try resolver.resolve(review, decisions: [:], profile: profile, mountedAt: device)

        let folder = device.appendingPathComponent("Music/Miles Davis/1959/Kind of Blue", isDirectory: true)
        XCTAssertEqual(plan.coverFolders.count, 1)
        XCTAssertEqual(plan.coverFolders.first?.key.path, folder.path)
        XCTAssertEqual(plan.coverFolders.first?.value.track.fileURL, tracks[0].track.fileURL)
    }

    // MARK: - Stored decisions (sync queue)

    func testStoredReplaceStillAppliesWhenDiffers() throws {
        let profile = copyProfile()
        let onDevice = try deviceAlbum("Music/Miles Davis/Kind of Blue", numbers: [1, 2],
                                       format: "MP3", bitrate: 128, ext: "mp3")
        let review = resolver.review(sending: sent([1, 2]), catalog: onDevice, profile: profile, mountedAt: device, leftAlone: [])
        let identity = try XCTUnwrap(review.albums.first?.identity)

        let applicable = DeviceTransferResolver.applicableDecisions(stored: [identity: DeviceStoredDecision(.replace, for: .sameRelease)], review: review)

        XCTAssertEqual(applicable, [identity: .replace])
        XCTAssertTrue(review.needingDecision.allSatisfy { applicable[$0.identity] != nil },
                      "an album answered when it was queued is not asked again")
    }

    func testStoredDecisionDroppedWhenAlbumNowNew() throws {
        let profile = copyProfile()
        // Queued against a catalog that held the album; the device no longer does.
        let review = resolver.review(sending: sent([1, 2]), catalog: [], profile: profile, mountedAt: device, leftAlone: [])
        let identity = try XCTUnwrap(review.albums.first?.identity)
        XCTAssertEqual(review.albums.map(\.status), [.new])

        XCTAssertEqual(DeviceTransferResolver.applicableDecisions(stored: [identity: DeviceStoredDecision(.replace, for: .sameRelease)], review: review), [:])
    }

    func testStoredDecisionDroppedWhenAlbumNowPresentOrGaps() throws {
        let profile = copyProfile()
        let onDevice = try deviceAlbum("Music/Miles Davis/Kind of Blue", numbers: [1])
        let review = resolver.review(sending: sent([1, 2]), catalog: onDevice, profile: profile, mountedAt: device, leftAlone: [])
        let identity = try XCTUnwrap(review.albums.first?.identity)
        XCTAssertEqual(review.albums.map(\.status), [.gaps])

        XCTAssertEqual(DeviceTransferResolver.applicableDecisions(stored: [identity: DeviceStoredDecision(.keepBoth, for: .sameRelease)], review: review), [:])
    }

    func testNilDecisionOnDifferingAlbumNeedsAsking() throws {
        let profile = copyProfile()
        let onDevice = try deviceAlbum("Music/Miles Davis/Kind of Blue", numbers: [1, 2],
                                       format: "MP3", bitrate: 128, ext: "mp3")
        let review = resolver.review(sending: sent([1, 2]), catalog: onDevice, profile: profile, mountedAt: device, leftAlone: [])
        // Another album's answer is not this one's.
        let other = DeviceAlbumIdentity(artist: "John Coltrane", album: "Blue Train")

        let applicable = DeviceTransferResolver.applicableDecisions(stored: [other: DeviceStoredDecision(.replace, for: .sameRelease)], review: review)

        XCTAssertEqual(applicable, [:])
        XCTAssertEqual(review.needingDecision.filter { applicable[$0.identity] == nil }.count, 1)
    }

    /// Queued as an upgrade (Replace swaps counterparts); at SYNC the device
    /// holds another release, where Replace would remove the whole album.
    func testStoredReplaceForAnUpgradeIsAskedAgainWhenNowAnotherRelease() throws {
        let profile = copyProfile()
        let onDevice = try deviceAlbum("Music/Miles Davis/Kind of Blue", numbers: [1, 2, 3, 4], titlePrefix: "Old")
        let review = resolver.review(sending: sent([1, 2]), catalog: onDevice, profile: profile, mountedAt: device, leftAlone: [])
        let album = try XCTUnwrap(review.albums.first)
        XCTAssertEqual(album.differenceKind, .differentRelease)

        let stored = [album.identity: DeviceStoredDecision(.replace, for: .sameRelease)]
        XCTAssertEqual(DeviceTransferResolver.applicableDecisions(stored: stored, review: review), [:])

        let sameKind = [album.identity: DeviceStoredDecision(.replace, for: .differentRelease)]
        XCTAssertEqual(DeviceTransferResolver.applicableDecisions(stored: sameKind, review: review),
                       [album.identity: .replace])
    }

    func testStoredDecisionWithoutAKindIsAskedAgain() throws {
        let profile = copyProfile()
        let onDevice = try deviceAlbum("Music/Miles Davis/Kind of Blue", numbers: [1, 2],
                                       format: "MP3", bitrate: 128, ext: "mp3")
        let review = resolver.review(sending: sent([1, 2]), catalog: onDevice, profile: profile, mountedAt: device, leftAlone: [])
        let identity = try XCTUnwrap(review.albums.first?.identity)
        XCTAssertEqual(review.differenceKinds, [identity: .sameRelease])

        XCTAssertEqual(DeviceTransferResolver.applicableDecisions(
            stored: [identity: DeviceStoredDecision(.replace, for: nil)], review: review), [:])
    }

    // MARK: - Fixtures

    private func copyProfile(_ layout: FolderStructureMode = .metadataTemplate) -> ExternalDeviceProfile {
        var profile = ExternalDeviceProfile.genericStorage(name: "Test")
        profile.transferSettings.mode = .copyOriginals
        profile.transferSettings.folderStructureMode = layout
        return profile
    }

    private func convertProfile(_ layout: FolderStructureMode = .metadataTemplate) -> ExternalDeviceProfile {
        var profile = ExternalDeviceProfile.genericStorage(name: "Test")
        profile.transferSettings = ExternalDeviceTransferSettings(
            mode: .convertDuringTransfer, outputFormat: .mp3, bitrateKbps: 192,
            artworkMaxDimension: 1024, artworkMode: .compatReembed, writesFolderCoverArt: false,
            folderStructureMode: layout
        )
        return profile
    }

    private func decide(_ review: DeviceTransferReview, _ decision: DeviceAlbumDecision) -> [DeviceAlbumIdentity: DeviceAlbumDecision] {
        Dictionary(review.albums.map { ($0.identity, decision) }, uniquingKeysWith: { first, _ in first })
    }

    /// Library tracks being sent; their files are never read.
    private func sent(
        _ numbers: [Int],
        folder: String = "Src/Kind of Blue",
        album: String = "Kind of Blue",
        disc: Int? = nil,
        art: Int? = nil
    ) -> [LoadedTrack] {
        numbers.map { number in
            track(album: album, disc: disc, number: number, title: "Track \(number)",
                  path: scratch.appendingPathComponent("\(folder)/0\(number) Track \(number).flac").path,
                  art: art, year: 1959)
        }
    }

    /// Catalog entries for an album on the device, each with a real empty file.
    private func deviceAlbum(
        _ folder: String,
        album: String = "Kind of Blue",
        disc: Int? = nil,
        numbers: [Int],
        titlePrefix: String = "Track",
        format: String = "FLAC",
        bitrate: Int? = 900,
        ext: String = "flac",
        art: Int? = nil,
        root: URL? = nil
    ) throws -> [LoadedTrack] {
        try numbers.map { number in
            try deviceTrack("\(folder)/0\(number) \(titlePrefix) \(number).\(ext)", album: album, disc: disc,
                            number: number, title: "\(titlePrefix) \(number)", format: format, bitrate: bitrate,
                            art: art, root: root)
        }
    }

    private func deviceTrack(
        _ relativePath: String,
        album: String = "Kind of Blue",
        disc: Int? = nil,
        number: Int?,
        title: String,
        format: String = "FLAC",
        bitrate: Int? = 900,
        art: Int? = nil,
        root: URL? = nil
    ) throws -> LoadedTrack {
        let url = try makeFile(relativePath, root: root)
        return track(album: album, disc: disc, number: number, title: title, format: format, bitrate: bitrate,
                     path: url.path, art: art)
    }

    @discardableResult
    private func makeFile(_ relativePath: String, root: URL? = nil) throws -> URL {
        let url = (root ?? device).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }

    private func track(
        album: String,
        artist: String = "Miles Davis",
        disc: Int? = nil,
        number: Int?,
        title: String,
        format: String = "FLAC",
        bitrate: Int? = 900,
        path: String,
        art: Int? = nil,
        year: Int? = nil
    ) -> LoadedTrack {
        let audio = AudioTrack(
            fileURL: URL(fileURLWithPath: path),
            title: title,
            artist: artist,
            album: album,
            formatName: format,
            bitrateKbps: bitrate,
            sampleRateHz: 44_100,
            year: year,
            trackNumber: number,
            discNumber: disc,
            artworkSource: art == nil ? .none : .embedded,
            artworkDimensions: art.map { ArtworkDimensions(width: $0, height: $0) }
        )
        let metadata = ConversionMetadata(
            title: title, artist: artist, album: album, trackNumber: number, discNumber: disc, year: year
        )
        return LoadedTrack(track: audio, metadata: metadata)
    }

    private func relative(_ copies: [DeviceTransferFilePlan.Copy]) -> [String] {
        relative(copies.map(\.destinationURL))
    }

    private func relative(_ urls: [URL]) -> [String] {
        let prefix = device.path + "/"
        return urls.map { url in
            let path = url.standardizedFileURL.path
            return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
        }
    }

    private func volumeIgnoresCase() throws -> Bool {
        let values = try device.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        return values.volumeSupportsCaseSensitiveNames == false
    }
}
#endif
