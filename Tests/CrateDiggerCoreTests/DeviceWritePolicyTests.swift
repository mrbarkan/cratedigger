import XCTest
@testable import CrateDiggerCore

final class DeviceWritePolicyTests: XCTestCase {
    private let policy = DeviceWritePolicy(musicSubpath: "Music")
    private let allRoles: Set<DeviceFileRole> = [.audio, .cover, .temp, .artistPicture, .artistFolderPicture,
                                                 .lyrics, .playlist, .centralCover, .ignoreMarker, .knownArtists]
    private let allReasons: [DeviceDeleteReason] = [.appleDouble, .ownedByCrateDigger, .userReplace, .staleTemp]

    private func assertAllowed(_ path: String, _ role: DeviceFileRole, policy: DeviceWritePolicy? = nil,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNoThrow(try (policy ?? self.policy).checkWrite(path, role: role),
                         "\(path) as \(role) should be allowed", file: file, line: line)
    }

    private func assertDenied(_ path: String, _ role: DeviceFileRole, policy: DeviceWritePolicy? = nil,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try (policy ?? self.policy).checkWrite(path, role: role),
                             "\(path) as \(role) should be refused", file: file, line: line) { error in
            guard case DeviceWritePolicyError.forbidden(let reason) = error else {
                return XCTFail("unexpected error \(error)", file: file, line: line)
            }
            XCTAssertFalse(reason.isEmpty, file: file, line: line)
        }
    }

    private func deleteAllowed(_ path: String, _ reason: DeviceDeleteReason,
                               policy: DeviceWritePolicy? = nil) -> Bool {
        (try? (policy ?? self.policy).checkDelete(path, reason: reason)) != nil
    }

    func testAllowsAudioUnderMusicFolder() {
        assertAllowed("Music/A/B/01.m4a", .audio)
        assertAllowed("Music/x.mp3", .audio)
        assertAllowed("music/A/02.FLAC", .audio) // FAT ignores case
    }

    func testAllowsCoverBesideAudio() {
        assertAllowed("Music/A/B/cover.jpg", .cover)
    }

    func testDeniesCoverNamedOtherwise() {
        assertDenied("Music/A/B/folder.png", .cover)
        assertDenied("Music/A/B/folder.jpg", .cover)
        assertDenied("Other/cover.jpg", .cover)
    }

    func testDeniesAudioOutsideMusicFolder() {
        assertDenied("Other/x.mp3", .audio)
        assertDenied("x.mp3", .audio)
        assertDenied("Musical/x.mp3", .audio)
    }

    func testDeniesNonAudioExtensionAsAudio() {
        assertDenied("Music/x.dat", .audio)
        assertDenied("Music/A/noextension", .audio)
    }

    func testDeniesEveryDeniedTree() {
        for tree in DeviceWritePolicy.deniedTrees {
            let path = "\(tree)/x.mp3"
            for role in allRoles {
                XCTAssertThrowsError(try DeviceWritePolicy(musicSubpath: "", enabledRoles: allRoles)
                    .checkWrite(path, role: role), "\(path) as \(role)")
            }
            for reason in allReasons {
                XCTAssertFalse(deleteAllowed(path, reason), "\(path) delete for \(reason)")
                XCTAssertFalse(deleteAllowed("\(tree)/._x.mp3", reason), "\(tree)/._x.mp3 delete for \(reason)")
            }
        }
    }

    func testDeniesScrobblerLog() {
        let rootPolicy = DeviceWritePolicy(musicSubpath: "", enabledRoles: allRoles)
        for role in allRoles { assertDenied(".scrobbler.log", role, policy: rootPolicy) }
        for reason in allReasons { XCTAssertFalse(deleteAllowed(".scrobbler.log", reason, policy: rootPolicy)) }
        XCTAssertFalse(deleteAllowed(".SCROBBLER.LOG.", .ownedByCrateDigger, policy: rootPolicy))
    }

    func testDeniesTrailingDotSpaceAndCaseAliases() {
        let rootPolicy = DeviceWritePolicy(musicSubpath: "", enabledRoles: allRoles)
        for path in [".ROCKBOX/config.cfg", ".rockbox./x.mp3", ".rockbox /x.mp3", "IPOD_CONTROL/x.mp3",
                     ".Rockbox. ./x.mp3", "iPod_Control./Music/F00/x.mp3",
                     // Folds FAT upper-cases into the same name, and a FAT short name.
                     "\u{0131}Pod_Control/x.mp3", ".Tra\u{017F}hes/x.mp3", "ROCKBO~1/x.mp3", ".ROCKB~12/x.mp3"] {
            for role in allRoles { assertDenied(path, role, policy: rootPolicy) }
            for reason in allReasons { XCTAssertFalse(deleteAllowed(path, reason, policy: rootPolicy), path) }
        }
    }

    func testDeniesTraversalAndAbsolutePaths() {
        for path in ["Music/../.rockbox/x.mp3", "/Music/x.mp3", "Music/./x.mp3", "", "Music//x.mp3",
                     "Music/x.mp3/", "Music/../Music/x.mp3", "Music/.../x.mp3"] {
            assertDenied(path, .audio)
            for reason in allReasons { XCTAssertFalse(deleteAllowed(path, reason), path) }
        }
    }

    func testEmptyMusicSubpathAllowsRootAudioButNotRockbox() {
        let direct = DeviceWritePolicy(musicSubpath: "")
        assertAllowed("x.mp3", .audio, policy: direct)
        assertAllowed("Artist/Album/01.m4a", .audio, policy: direct)
        assertAllowed("cover.jpg", .cover, policy: direct)
        assertDenied(".rockbox/x.mp3", .audio, policy: direct)
        assertDenied(".ROCKBOX/cover.jpg", .cover, policy: direct)
    }

    func testRootAudioDeniedWhenMusicSubpathSet() {
        assertDenied("x.mp3", .audio)
        assertDenied("cover.jpg", .cover)
    }

    func testTempAllowedOnlyBesideAllowedTarget() {
        assertAllowed("Music/A/01.m4a.cdtmp", .temp)
        assertAllowed("Music/A/cover.jpg.cdtmp", .temp)
        assertDenied("Music/A/x.dat.cdtmp", .temp)
        assertDenied("Other/01.m4a.cdtmp", .temp)
        assertDenied("Music/A/01.m4a", .temp)
        assertDenied("Music/A/.cdtmp", .temp)
        assertDenied(".rockbox/01.m4a.cdtmp", .temp)
    }

    func testDisabledRoleRefused() {
        assertDenied("Artwork/People/Radiohead.jpg", .artistPicture)
        assertDenied("Music/A/01.lrc8", .lyrics)
        assertDenied("Playlists/Mix.m3u8", .playlist)
    }

    func testArtistPictureWhenEnabled() {
        let pictures = DeviceWritePolicy(musicSubpath: "Music", enabledRoles: [.artistPicture])
        assertAllowed("Artwork/People/Radiohead.jpg", .artistPicture, policy: pictures)
        assertAllowed("artwork/people/Sigur Rós.JPG", .artistPicture, policy: pictures)
        assertDenied("Artwork/People/sub/x.jpg", .artistPicture, policy: pictures)
        assertDenied("Artwork/People/x.png", .artistPicture, policy: pictures)
        assertDenied("Artwork/x.jpg", .artistPicture, policy: pictures)
        assertDenied("Music/A/x.mp3", .audio, policy: pictures) // audio is not enabled there
    }

    func testOtherPhaseRolesFollowTheirRow() {
        let all = DeviceWritePolicy(musicSubpath: "Music", playlistDirectory: "Playlists", enabledRoles: allRoles)
        assertAllowed("Music/A/folder.jpg", .artistFolderPicture, policy: all)
        assertDenied("Music/folder.jpg", .artistFolderPicture, policy: all)
        assertAllowed("Music/A/B/01.lrc8", .lyrics, policy: all)
        assertDenied("Music/A/B/01.lrc", .lyrics, policy: all)
        assertAllowed("Playlists/Road Trip.m3u8", .playlist, policy: all)
        assertDenied("Playlists/sub/Road Trip.m3u8", .playlist, policy: all)
        assertDenied("Music/Road Trip.m3u8", .playlist, policy: all)
        assertAllowed("Artwork/Covers/Radiohead - OK Computer.jpg", .centralCover, policy: all)
        assertDenied("Artwork/Covers/x.png", .centralCover, policy: all)
        assertAllowed("Music/A/database.ignore", .ignoreMarker, policy: all)
        assertAllowed("Music/A/database.unignore", .ignoreMarker, policy: all)
        assertDenied("Music/A/database.txt", .ignoreMarker, policy: all)
        assertDenied("Music/A/._01.m4a", .audio, policy: all) // never write into the AppleDouble namespace
    }

    func testKnownArtistsIsTheOnlyRockboxException() {
        let path = ".rockbox/library/user/known_artists.txt"
        assertDenied(path, .knownArtists) // not enabled by default
        let enabled = DeviceWritePolicy(musicSubpath: "Music", enabledRoles: [.knownArtists, .audio])
        assertAllowed(path, .knownArtists, policy: enabled)
        assertAllowed(".ROCKBOX/Library/User/Known_Artists.txt", .knownArtists, policy: enabled)
        assertDenied(path, .audio, policy: enabled)
        assertDenied(".rockbox/library/user/player_name.txt", .knownArtists, policy: enabled)
        assertDenied("Music/known_artists.txt", .knownArtists, policy: enabled)
        XCTAssertFalse(deleteAllowed(path, .ownedByCrateDigger, policy: enabled))
        XCTAssertFalse(deleteAllowed(path + ".cdtmp", .staleTemp, policy: enabled))
        assertDenied(path + ".cdtmp", .temp, policy: DeviceWritePolicy(musicSubpath: "Music",
                                                                    enabledRoles: [.knownArtists, .temp]))
    }

    func testAppleDoubleDeleteAnywhereOutsideDeniedTrees() {
        XCTAssertTrue(deleteAllowed("Music/A/._01.m4a", .appleDouble))
        XCTAssertTrue(deleteAllowed("Books/._Moby Dick.EPUB", .appleDouble))
        XCTAssertTrue(deleteAllowed("Playlists/._Mix.m3u8", .appleDouble))
        XCTAssertFalse(deleteAllowed(".rockbox/themes/._x.cfg", .appleDouble))
        XCTAssertFalse(deleteAllowed("._", .appleDouble))
        XCTAssertFalse(deleteAllowed("Music/._", .appleDouble))
        XCTAssertFalse(deleteAllowed("Music/A/01.m4a", .appleDouble))
    }

    func testAppleDoubleDeleteOnlyForTwinsOfMediaFiles() {
        // Spec D21: the owner's Notes and Contacts are not ours to tidy.
        XCTAssertFalse(deleteAllowed("Notes/._a.txt", .appleDouble))
        XCTAssertFalse(deleteAllowed("._Music", .appleDouble))
        XCTAssertFalse(deleteAllowed("Contacts/._card.vcf", .appleDouble))
        XCTAssertTrue(deleteAllowed("Notes/._scan.pdf", .appleDouble))
        // The policy's own audio extensions count too.
        let custom = DeviceWritePolicy(musicSubpath: "Music", audioExtensions: ["wv"])
        XCTAssertTrue(deleteAllowed("Music/._01.wv", .appleDouble, policy: custom))
    }

    func testNamesFATWouldChangeAreRefused() {
        for path in ["Music/A./01.m4a", "Music/A /01.m4a", "Music/A/01.m4a.", "Music/A/01.m4a ",
                     "Music/TRACK~1.M4A", "Music/A~9/01.m4a"] {
            assertDenied(path, .audio)
            XCTAssertFalse(deleteAllowed(path, .userReplace), path)
        }
        assertAllowed("Music/A~B/01 ~ Live.m4a", .audio) // a tilde alone is fine
        assertAllowed("Music/Vol. 2/01.m4a", .audio)
    }

    func testUserReplaceOnlyAudioUnderMusic() {
        XCTAssertTrue(deleteAllowed("Music/A/B/01.m4a", .userReplace))
        XCTAssertFalse(deleteAllowed("Music/A/B/cover.jpg", .userReplace))
        XCTAssertFalse(deleteAllowed("Other/01.m4a", .userReplace))
        XCTAssertFalse(deleteAllowed(".rockbox/01.m4a", .userReplace))
    }

    func testOwnedAndStaleTempDeletesFollowTheWriteRules() {
        XCTAssertTrue(deleteAllowed("Music/A/cover.jpg", .ownedByCrateDigger))
        XCTAssertFalse(deleteAllowed("Artwork/People/x.jpg", .ownedByCrateDigger)) // role not enabled
        XCTAssertTrue(deleteAllowed("Music/A/01.m4a.cdtmp", .staleTemp))
        XCTAssertFalse(deleteAllowed("Music/A/01.m4a", .staleTemp))
    }

    func testKeyFoldsCaseNFCAndTrailingDots() {
        let nfd = "Music/Gdan\u{0301}sk/01.m4a"
        let nfc = "Music/Gda\u{0144}sk/01.m4a"
        XCTAssertEqual(DeviceWritePolicy.key(forRelativePath: nfd), DeviceWritePolicy.key(forRelativePath: nfc))
        XCTAssertEqual(DeviceWritePolicy.key(forRelativePath: "\u{0131}Pod_Control"), "ipod_control")
        XCTAssertEqual(DeviceWritePolicy.key(forRelativePath: ".Tra\u{017F}hes"), ".trashes")
        XCTAssertEqual(DeviceWritePolicy.key(forRelativePath: "MUSIC/A./B /01.M4A"), "music/a/b/01.m4a")
        XCTAssertEqual(DeviceWritePolicy.key(forRelativePath: ".ROCKBOX. "), ".rockbox")
    }

    func testRelativePathResolvesSymlinksAndRefusesEscapes() throws {
        let iPod = try FakeIPod()
        let music = iPod.root.appendingPathComponent("Music")
        try FileManager.default.createSymbolicLink(atPath: music.appendingPathComponent("link").path,
                                                   withDestinationPath: "../.rockbox")
        let outside = FileManager.default.temporaryDirectory
        try FileManager.default.createSymbolicLink(atPath: music.appendingPathComponent("away").path,
                                                   withDestinationPath: outside.path)
        try FileManager.default.createSymbolicLink(atPath: music.appendingPathComponent("dangling").path,
                                                   withDestinationPath: "/nonexistent-\(UUID().uuidString)")

        XCTAssertEqual(DeviceWritePolicy.relativePath(of: music.appendingPathComponent("A/new.m4a"),
                                                      under: iPod.root), "Music/A/new.m4a")
        XCTAssertEqual(DeviceWritePolicy.relativePath(of: music.appendingPathComponent("link/x.mp3"),
                                                      under: iPod.root), ".rockbox/x.mp3")
        XCTAssertEqual(DeviceWritePolicy.relativePath(of: iPod.root, under: iPod.root), "")
        XCTAssertNil(DeviceWritePolicy.relativePath(of: music.appendingPathComponent("away/x.mp3"),
                                                    under: iPod.root))
        XCTAssertNil(DeviceWritePolicy.relativePath(of: music.appendingPathComponent("dangling/x.mp3"),
                                                    under: iPod.root))
        XCTAssertNil(DeviceWritePolicy.relativePath(of: URL(fileURLWithPath: music.path + "/../../x.mp3"),
                                                    under: iPod.root))
    }

    func testGeneratedPathsNeverReachDeniedTrees() {
        let components = ["Music", ".rockbox", ".ROCKBOX", "..", ".", "a", "b.mp3", "._x.m4a", "iPod_Control"]
        let deniedKeys = Set(DeviceWritePolicy.deniedTrees.map { DeviceWritePolicy.key(forRelativePath: $0) })
        let policies = [
            DeviceWritePolicy(musicSubpath: "Music"),
            DeviceWritePolicy(musicSubpath: "", enabledRoles: allRoles),
            DeviceWritePolicy(musicSubpath: "Music", enabledRoles: allRoles),
        ]
        var seed: UInt64 = 0x5eed
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }
        var allowedCount = 0
        for _ in 0..<500 {
            let length = 1 + next(5)
            let path = (0..<length).map { _ in components[next(components.count)] }.joined(separator: "/")
            for policy in policies {
                var passed = allRoles.contains { (try? policy.checkWrite(path, role: $0)) != nil }
                passed = passed || allReasons.contains { (try? policy.checkDelete(path, reason: $0)) != nil }
                guard passed else { continue }
                allowedCount += 1
                for component in path.split(separator: "/", omittingEmptySubsequences: false) {
                    XCTAssertFalse(deniedKeys.contains(DeviceWritePolicy.key(forRelativePath: String(component))),
                                   "\(path) passed but names a denied tree")
                    XCTAssertFalse(component == ".." || component == ".", "\(path) passed with traversal")
                }
            }
        }
        XCTAssertGreaterThan(allowedCount, 0, "the generator never produced an allowed path")
    }
}
