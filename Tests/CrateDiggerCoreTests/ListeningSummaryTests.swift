#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

final class ListeningSummaryTests: XCTestCase {

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    /// 2026-09-03T12:00:00Z
    private let now = Date(timeIntervalSince1970: 1_788_436_800)
    private let added = Date(timeIntervalSince1970: 1_700_000_000)

    private func track(_ path: String, title: String, artist: String, album: String, duration: Double) -> LoadedTrack {
        LoadedTrack(
            track: AudioTrack(fileURL: URL(fileURLWithPath: path), title: title, artist: artist,
                              album: album, durationSeconds: duration, artworkSource: .none),
            metadata: ConversionMetadata(title: title, artist: artist, album: album)
        )
    }

    private func stats(playCount: Int = 0, months: [String: Int] = [:]) -> ListeningStats {
        ListeningStats(playCount: playCount, dateAdded: added, playsByMonth: months)
    }

    private lazy var library: [String: LoadedTrack] = [
        "/m/kob/1.flac": track("/m/kob/1.flac", title: "So What", artist: "Miles Davis", album: "Kind of Blue", duration: 540),
        "/m/kob/2.flac": track("/m/kob/2.flac", title: "Freddie Freeloader", artist: "Miles Davis", album: "Kind of Blue", duration: 580),
        "/m/bb/1.flac":  track("/m/bb/1.flac", title: "Birdland", artist: "Weather Report", album: "Heavy Weather", duration: 360),
    ]

    private func resolve(_ path: String) -> LoadedTrack? { library[path] }

    // MARK: Windows

    func testTheWindowsCycleMonthYearAllTime() {
        XCTAssertEqual(ListeningWindow.month.next, .year)
        XCTAssertEqual(ListeningWindow.year.next, .allTime)
        XCTAssertEqual(ListeningWindow.allTime.next, .month)
    }

    func testWindowTitlesReadLikeTheGlass() {
        XCTAssertEqual(ListeningWindow.month.title(now: now, calendar: utc), "SEPTEMBER 2026")
        XCTAssertEqual(ListeningWindow.year.title(now: now, calendar: utc), "2026")
        XCTAssertEqual(ListeningWindow.allTime.title(now: now, calendar: utc), "ALL TIME")
    }

    func testWindowKeysCoverExactlyTheirMonths() {
        XCTAssertEqual(ListeningWindow.month.monthKeys(now: now, calendar: utc), ["2026-09"])
        let year = ListeningWindow.year.monthKeys(now: now, calendar: utc)
        XCTAssertEqual(year?.count, 12)
        XCTAssertTrue(year?.contains("2026-01") == true)
        XCTAssertTrue(year?.contains("2026-12") == true)
        XCTAssertFalse(year?.contains("2025-12") == true)
        XCTAssertNil(ListeningWindow.allTime.monthKeys(now: now, calendar: utc))
    }

    // MARK: Counting

    func testMonthWindowReadsOnlyThisMonth() {
        let all = [
            "/m/kob/1.flac": stats(playCount: 10, months: ["2026-09": 3, "2026-08": 7]),
        ]
        let summary = ListeningSummary.compute(stats: all, window: .month, now: now, calendar: utc, resolve: resolve)
        XCTAssertEqual(summary.plays, 3)
        XCTAssertEqual(summary.tracksTouched, 1)
        XCTAssertEqual(summary.listenedSeconds, 3 * 540)
    }

    func testYearWindowSumsTheCalendarYear() {
        let all = [
            "/m/kob/1.flac": stats(playCount: 10, months: ["2026-01": 2, "2026-09": 3, "2025-12": 5]),
        ]
        let summary = ListeningSummary.compute(stats: all, window: .year, now: now, calendar: utc, resolve: resolve)
        XCTAssertEqual(summary.plays, 5, "December 2025 is not this year")
    }

    func testAllTimeReadsPlayCountEvenWithNoHistogram() {
        let all = ["/m/kob/1.flac": stats(playCount: 42)]
        let summary = ListeningSummary.compute(stats: all, window: .allTime, now: now, calendar: utc, resolve: resolve)
        XCTAssertEqual(summary.plays, 42)
        XCTAssertEqual(summary.topTrack?.name, "So What")
    }

    func testAnEmptyWindowIsEmpty() {
        let all = ["/m/kob/1.flac": stats(playCount: 5, months: ["2026-08": 5])]
        let summary = ListeningSummary.compute(stats: all, window: .month, now: now, calendar: utc, resolve: resolve)
        XCTAssertTrue(summary.isEmpty)
        XCTAssertNil(summary.topRecord)
        XCTAssertNil(summary.topArtist)
        XCTAssertNil(summary.topTrack)
        XCTAssertEqual(summary.recordsTouched, 0)
    }

    // MARK: Grouping

    func testTopRecordGroupsTracksOfOneAlbum() {
        let all = [
            "/m/kob/1.flac": stats(months: ["2026-09": 2]),
            "/m/kob/2.flac": stats(months: ["2026-09": 2]),
            "/m/bb/1.flac":  stats(months: ["2026-09": 3]),
        ]
        let summary = ListeningSummary.compute(stats: all, window: .month, now: now, calendar: utc, resolve: resolve)
        XCTAssertEqual(summary.topRecord?.name, "Kind of Blue", "two tracks of one record outvote one track of another")
        XCTAssertEqual(summary.topRecord?.detail, "Miles Davis")
        XCTAssertEqual(summary.topRecord?.plays, 4)
        XCTAssertEqual(summary.topArtist?.name, "Miles Davis")
        XCTAssertEqual(summary.topTrack?.name, "Birdland", "but the single most played track is still the other one")
        XCTAssertEqual(summary.recordsTouched, 2)
        XCTAssertEqual(summary.tracksTouched, 3)
    }

    func testTiesBreakByNameSoTheAnswerIsStable() {
        let all = [
            "/m/kob/1.flac": stats(months: ["2026-09": 1]),
            "/m/bb/1.flac":  stats(months: ["2026-09": 1]),
        ]
        let summary = ListeningSummary.compute(stats: all, window: .month, now: now, calendar: utc, resolve: resolve)
        XCTAssertEqual(summary.topTrack?.name, "Birdland")
        XCTAssertEqual(summary.topRecord?.name, "Heavy Weather")
    }

    func testAForgottenPathCountsButCannotBeNamed() {
        let all = [
            "/gone/x.flac":  stats(months: ["2026-09": 9]),
            "/m/bb/1.flac":  stats(months: ["2026-09": 1]),
        ]
        let summary = ListeningSummary.compute(stats: all, window: .month, now: now, calendar: utc, resolve: resolve)
        XCTAssertEqual(summary.plays, 10)
        XCTAssertEqual(summary.tracksTouched, 2)
        XCTAssertEqual(summary.recordsTouched, 1)
        XCTAssertEqual(summary.topTrack?.name, "Birdland")
        XCTAssertEqual(summary.listenedSeconds, 360, "no duration for a track nobody can name")
    }
}
#endif
