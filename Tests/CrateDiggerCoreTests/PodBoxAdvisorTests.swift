import XCTest
@testable import CrateDiggerCore

/// Readiness notes: read-only advice about what the iPod will make of the
/// music on it. One test per note present and one absent.
final class PodBoxAdvisorTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/FakePodForNotes", isDirectory: true) // never read: the advisor does no IO

    private func firmware(_ config: String = "", flavour: RockboxFlavour = .podBox, layout: Int? = 5,
                          macFiles: Int = 0, prefix: String? = "/<HDD0>") -> DeviceFirmware {
        DeviceFirmware(flavour: flavour, layout: layout, build: nil,
                       config: PodBoxConfig(defaultConfig: nil, config: config),
                       playerPathPrefix: prefix, unreadableAppleDoubleCount: macFiles)
    }

    private func track(_ relative: String, artist: String, albumArtist: String? = nil) -> LoadedTrack {
        LoadedTrack(track: AudioTrack(fileURL: root.appendingPathComponent(relative), title: "t", artist: artist),
                    metadata: ConversionMetadata(artist: artist, albumArtist: albumArtist))
    }

    private let tidy = [LoadedTrack]()

    private func notes(_ firmware: DeviceFirmware, catalog: [LoadedTrack] = [], music: String = "Music") -> [PodBoxNote] {
        PodBoxAdvisor.deviceNotes(catalog: catalog, firmware: firmware, musicSubpath: music, volumeRoot: root)
    }

    private func note(_ kind: PodBoxNote.Kind, in notes: [PodBoxNote]) -> PodBoxNote? {
        notes.first { $0.kind == kind }
    }

    func testCleanPodBoxHasNoNotes() {
        XCTAssertEqual(notes(firmware(), catalog: [track("Music/Air/Moon Safari/01.mp3", artist: "Air")]), [])
    }

    func testMacFilesNote() throws {
        let found = try XCTUnwrap(note(.macFiles, in: notes(firmware(macFiles: 3))))
        XCTAssertEqual(found.text, "PodBox is reading 3 Mac files as music.")
        XCTAssertNil(found.menuPath)
        XCTAssertEqual(note(.macFiles, in: notes(firmware(macFiles: 1)))?.text, "PodBox is reading 1 Mac file as music.")
    }

    func testNoMacFilesNoteAtZero() {
        XCTAssertNil(note(.macFiles, in: notes(firmware(macFiles: 0))))
    }

    func testArtistArtOff() throws {
        let found = try XCTUnwrap(note(.artistArtOff, in: notes(firmware("database artist art: off\n"))))
        XCTAssertEqual(found.text, "Artist pictures are switched off on this iPod.")
        XCTAssertEqual(found.menuPath, "Settings ▸ Library ▸ Art Cache")
        XCTAssertNil(note(.artistArtOff, in: notes(firmware("database artist art: on\n"))))
    }

    func testMusicOutsideScanPaths() throws {
        let found = try XCTUnwrap(note(.musicNotScanned,
                                       in: notes(firmware("database scan paths: /Podcasts:/Mus\n"))))
        XCTAssertEqual(found.text, "This iPod only scans /Podcasts, /Mus. Music in /Music will not appear.")
    }

    func testScanRootCoversEverything() {
        XCTAssertNil(note(.musicNotScanned, in: notes(firmware("database scan paths: /\n"))))
        XCTAssertNil(note(.musicNotScanned, in: notes(firmware("database scan paths: /Podcasts:/music/\n"))),
                     "FAT ignores case, and a trailing slash is the same folder")
        XCTAssertNil(note(.musicNotScanned, in: notes(firmware("database scan paths: /Media\n"), music: "Media/Music")))
    }

    func testPlayLogOff() throws {
        let found = try XCTUnwrap(note(.playLogOff, in: notes(firmware("play log: off\n"))))
        XCTAssertEqual(found.text, "The play log is off on this iPod, so plays cannot be imported.")
        XCTAssertNil(note(.playLogOff, in: notes(firmware("play log: last.fm\n"))))
    }

    func testUnnameableArtistsListed() throws {
        let catalog = [track("Music/Chk/Myth Takes/01.mp3", artist: "!!!"),
                       track("Music/Hot Band/Riffs/01.mp3", artist: "Hot \u{1F3B8} Band"),
                       track("Music/Air/Moon Safari/01.mp3", artist: "Air")]
        let found = try XCTUnwrap(note(.unnameableArtists, in: notes(firmware(), catalog: catalog)))
        XCTAssertEqual(found.text, "PodBox cannot match a picture to 2 artist names.")
        XCTAssertEqual(Set(found.items), ["!!!", "Hot \u{1F3B8} Band"])
    }

    func testLongPathListed() throws {
        let long = "Music/" + String(repeating: "a", count: 200) + "/" + String(repeating: "b", count: 50) + ".mp3"
        let catalog = [track(long, artist: "Air"), track("Music/Air/Moon Safari/01.mp3", artist: "Air")]
        let found = try XCTUnwrap(note(.pathTooLong, in: notes(firmware(), catalog: catalog)))
        XCTAssertEqual(found.text, "1 file has a path too long for the player.")
        XCTAssertEqual(found.items, [long])
        let two = notes(firmware(), catalog: [track(long, artist: "Air"), track(long + "x.mp3", artist: "Air")])
        XCTAssertEqual(note(.pathTooLong, in: two)?.text, "2 files have paths too long for the player.")
    }

    func testCompilationWithoutAlbumArtist() throws {
        let catalog = [track("Music/Comp/Now 99/01.mp3", artist: "Beck"),
                       track("Music/Comp/Now 99/02.mp3", artist: "Air"),
                       track("Music/Air/Moon Safari/01.mp3", artist: "Air"),
                       track("Music/Air/Moon Safari/02.mp3", artist: "AIR ")]
        let found = try XCTUnwrap(note(.compilationWithoutAlbumArtist, in: notes(firmware(), catalog: catalog)))
        XCTAssertEqual(found.text, "1 compilation has no album artist and will be split by artist.")
        XCTAssertEqual(found.items, ["Music/Comp/Now 99"])
    }

    func testCompilationWithAlbumArtistIsFine() {
        let catalog = [track("Music/Comp/Now 99/01.mp3", artist: "Beck", albumArtist: "Various Artists"),
                       track("Music/Comp/Now 99/02.mp3", artist: "Air", albumArtist: "Various Artists")]
        XCTAssertNil(note(.compilationWithoutAlbumArtist, in: notes(firmware(), catalog: catalog)))
    }

    func testEmbeddedOnly() throws {
        let found = try XCTUnwrap(note(.embeddedArtOnly, in: notes(firmware("art cache album source: embedded\n"))))
        XCTAssertEqual(found.text, "This iPod is set to use embedded covers only.")
        XCTAssertEqual(found.menuPath, "Settings ▸ Library ▸ Art Cache ▸ Album Art Source")
        for mixed in ["files", "files then embedded", "embedded then files", "Image Files, Then Embedded"] {
            XCTAssertNil(note(.embeddedArtOnly, in: notes(firmware("art cache album source: \(mixed)\n"))), mixed)
        }
    }

    func testNewerLayout() throws {
        let found = try XCTUnwrap(note(.newerLayout, in: notes(firmware(layout: 6))))
        XCTAssertEqual(found.text, "This iPod runs a newer PodBox library layout (6) than CrateDigger knows (5)")
        XCTAssertNil(note(.newerLayout, in: notes(firmware(layout: 5))))
    }

    func testNotBooted() throws {
        let found = try XCTUnwrap(note(.notBooted, in: notes(firmware(layout: nil))))
        XCTAssertEqual(found.text, "Start the iPod once so PodBox can finish setting up")
    }

    func testOrderFollowsTheKinds() {
        let catalog = [track("Music/Chk/Myth Takes/01.mp3", artist: "!!!")]
        let all = notes(firmware("play log: off\ndatabase artist art: off\ndatabase scan paths: /Podcasts\nart cache album source: embedded\n",
                                 layout: 7, macFiles: 2), catalog: catalog)
        XCTAssertEqual(all.map(\.kind), [.macFiles, .artistArtOff, .musicNotScanned, .playLogOff, .unnameableArtists,
                                         .embeddedArtOnly, .newerLayout])
    }

    func testStockRockboxGetsOnlyGenericNotes() {
        let long = "Music/" + String(repeating: "a", count: 260) + ".mp3"
        let catalog = [track(long, artist: "!!!"),
                       track("Music/Comp/X/01.mp3", artist: "Beck"), track("Music/Comp/X/02.mp3", artist: "Air")]
        for flavour in [RockboxFlavour.stockRockbox, .unknownRockbox] {
            let found = notes(firmware("play log: off\ndatabase artist art: off\ndatabase scan paths: /Podcasts\n",
                                       flavour: flavour, layout: nil, macFiles: 2), catalog: catalog)
            XCTAssertEqual(found.map(\.kind), [.macFiles, .pathTooLong], "\(flavour)")
        }
    }

    func testNoEmDashInAnyText() {
        let catalog = [track("Music/Chk/Myth Takes/01.mp3", artist: "!!!"),
                       track("Music/" + String(repeating: "a", count: 260) + ".mp3", artist: "Air"),
                       track("Music/Comp/X/01.mp3", artist: "Beck"), track("Music/Comp/X/02.mp3", artist: "Air")]
        var all = notes(firmware("play log: off\ndatabase artist art: off\ndatabase scan paths: /Podcasts\nart cache album source: embedded\n",
                                 layout: 7, macFiles: 2), catalog: catalog)
        all += notes(firmware(layout: nil))
        XCTAssertEqual(Set(all.map(\.kind)).count, PodBoxNote.Kind.allCases.count, "every kind was made")
        for note in all {
            for text in [note.text, note.menuPath ?? ""] {
                XCTAssertFalse(text.contains("\u{2014}") || text.contains("\u{2013}"), text)
            }
        }
    }
}
