#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

final class StreamDownloaderTests: XCTestCase {
    private func stream(kind: StreamKind = .mix, title: String = "Deep House Mix", channel: String = "Some Channel") -> StreamSource {
        StreamSource(id: "abc", url: "https://youtu.be/abc", title: title, channel: channel,
                     kind: kind, hue: 0, addedAt: Date(timeIntervalSince1970: 0))
    }
    private let root = URL(fileURLWithPath: "/Music/Library")

    func testPlanIsChannelThenTitle() throws {
        let plan = try StreamDownloader.plan(for: stream(), in: root)
        XCTAssertEqual(plan.folder.path, "/Music/Library/Some Channel/Deep House Mix")
        XCTAssertEqual(plan.fileURL.path, "/Music/Library/Some Channel/Deep House Mix/Deep House Mix.m4a")
    }

    func testPlanSanitisesAndSurvivesAnEmptyChannel() throws {
        let plan = try StreamDownloader.plan(for: stream(title: "A/B: 100% live", channel: ""), in: root)
        XCTAssertFalse(plan.baseName.contains("/"))
        XCTAssertEqual(plan.folder.deletingLastPathComponent().lastPathComponent, "Unknown Channel")
    }

    func testLiveAndPlaylistAreRefused() {
        XCTAssertThrowsError(try StreamDownloader.plan(for: stream(kind: .live), in: root)) {
            XCTAssertEqual($0 as? StreamDownloadError, .notDownloadable(.live))
        }
        XCTAssertThrowsError(try StreamDownloader.plan(for: stream(kind: .playlist), in: root)) {
            XCTAssertEqual($0 as? StreamDownloadError, .notDownloadable(.playlist))
        }
    }

    func testArguments() throws {
        // Both path components carry a literal %, so both must survive escaped.
        let s = stream(title: "100% live", channel: "100% Channel")
        let plan = try StreamDownloader.plan(for: s, in: root)
        let args = StreamDownloader.arguments(for: s, plan: plan, ffmpegURL: URL(fileURLWithPath: "/opt/ffmpeg"))
        XCTAssertEqual(Array(args.suffix(2)), ["--", "https://youtu.be/abc"])   // "--" so a URL is never a flag
        XCTAssertTrue(args.contains("--no-playlist"))
        XCTAssertTrue(args.contains("--newline"))
        XCTAssertEqual(args[args.firstIndex(of: "-f")! + 1], "bestaudio[ext=m4a]/bestaudio")
        XCTAssertEqual(args[args.firstIndex(of: "--audio-format")! + 1], "m4a")
        XCTAssertEqual(args[args.firstIndex(of: "--ffmpeg-location")! + 1], "/opt/ffmpeg")
        // A literal % in the channel folder AND the title must not be read as an output-template field.
        let template = args[args.firstIndex(of: "-o")! + 1]
        XCTAssertTrue(template.contains("/100%% Channel/100%% live/100%% live.%(ext)s"), template)
    }

    func testArgumentsWithoutFfmpegOmitTheLocation() throws {
        let s = stream()
        let args = StreamDownloader.arguments(for: s, plan: try StreamDownloader.plan(for: s, in: root), ffmpegURL: nil)
        XCTAssertFalse(args.contains("--ffmpeg-location"))
    }

    func testProgressParsing() {
        XCTAssertEqual(StreamDownloader.progress(fromLine: "CDPROGRESS 500 1000 NA")!, 0.5, accuracy: 0.001)
        XCTAssertEqual(StreamDownloader.progress(fromLine: "CDPROGRESS 250 NA 1000")!, 0.25, accuracy: 0.001) // estimate
        XCTAssertEqual(StreamDownloader.progress(fromLine: "CDPROGRESS 2000 1000 NA")!, 1, accuracy: 0.001)   // clamped
        XCTAssertNil(StreamDownloader.progress(fromLine: "CDPROGRESS 500 NA NA"))
        XCTAssertNil(StreamDownloader.progress(fromLine: "CDPROGRESS 500 0 NA"))
        XCTAssertNil(StreamDownloader.progress(fromLine: "[download] Destination: x.m4a"))
        XCTAssertNil(StreamDownloader.progress(fromLine: ""))
    }

    // MARK: - isDownloadFolder / isDisposableLeftover (Remove Download cleanup)

    func testIsDownloadFolderMatchesThePlannedFolder() throws {
        let s = stream()
        let plan = try StreamDownloader.plan(for: s, in: root)
        XCTAssertTrue(StreamDownloader.isDownloadFolder(plan.folder, for: s))
    }

    func testIsDownloadFolderRejectsAFolderARepointMovedTheTrackInto() {
        // The exact scenario Remove Download must not trash: a retag or an
        // auto-organize repoints `downloadedPath` into a folder the app never
        // created, named for the artist/album rather than the sanitized title.
        let s = stream(title: "Deep House Mix")
        let userOwnedAlbumFolder = URL(fileURLWithPath: "/Music/Library/Some Artist/Some Album")
        XCTAssertFalse(StreamDownloader.isDownloadFolder(userOwnedAlbumFolder, for: s))
    }

    func testIsDownloadFolderRejectsARightTitleUnderTheWrongChannel() {
        // The leaf name alone used to be the whole check, so an ordinary album
        // folder that happened to be named exactly like the sanitized title
        // (just filed under a different artist/channel folder) would pass.
        // The parent component must match the sanitized channel too.
        let s = stream(title: "Deep House Mix", channel: "Some Channel")
        let wrongChannelFolder = URL(fileURLWithPath: "/Music/Library/Some Other Channel/Deep House Mix")
        XCTAssertFalse(StreamDownloader.isDownloadFolder(wrongChannelFolder, for: s))
    }

    func testIsDownloadFolderUsesTheSameSanitizingAsPlan() {
        // A title with characters `plan` sanitizes (":" -> "-") must still
        // match the folder `plan` itself would have produced.
        let s = stream(title: "A/B: 100% live")
        let sanitizedFolder = URL(fileURLWithPath: "/Music/Library/Some Channel/A-B- 100% live")
        XCTAssertTrue(StreamDownloader.isDownloadFolder(sanitizedFolder, for: s))
    }

    func testIsDisposableLeftoverAllowsOnlyCoverAndDSStore() {
        XCTAssertTrue(StreamDownloader.isDisposableLeftover(contents: []))
        XCTAssertTrue(StreamDownloader.isDisposableLeftover(contents: ["cover.jpg"]))
        XCTAssertTrue(StreamDownloader.isDisposableLeftover(contents: ["cover.jpg", ".DS_Store"]))
        XCTAssertFalse(StreamDownloader.isDisposableLeftover(contents: ["cover.jpg", "01 Track.flac"]))
        XCTAssertFalse(StreamDownloader.isDisposableLeftover(contents: ["booklet.pdf"]))
    }
}
#endif
