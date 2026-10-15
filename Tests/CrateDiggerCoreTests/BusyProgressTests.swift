#if canImport(XCTest)
import XCTest
@testable import CrateDiggerCore

/// The job model every scene reads: progress sanitised on the way in, the
/// secure-read bar moved out of `DubPane`, the short labels a scene prints,
/// and which screen hosts each kind of job.
final class BusyProgressTests: XCTestCase {
    func testFractionIsNilWithoutATotal() {
        for total in [nil, 0, -5] as [Int?] {
            let progress = BusyProgress(completed: 3, total: total)
            XCTAssertNil(progress.fraction, "\(String(describing: total))")
            XCTAssertEqual(progress.total, total, "stored as given")
        }
    }

    func testFractionClampsAndIgnoresNaN() {
        XCTAssertEqual(BusyProgress(completed: 150, total: 100).fraction, 1)
        XCTAssertEqual(BusyProgress(completed: 25, total: 100).fraction, 0.25)

        var negative = BusyProgress(completed: -4, total: 10)
        XCTAssertEqual(negative.completed, 0, "sanitised on init")
        negative.completed = -1
        XCTAssertEqual(negative.completed, 0, "sanitised on set")
        XCTAssertEqual(negative.fraction, 0)

        let track = SecureRipEngine.Progress(trackNumber: 1, phase: .pass1, fraction: .nan, rereads: 0)
        let secure = BusySecureRead(SecureDiscRip.Progress(trackOrdinal: 1, trackCount: 3,
                                                           track: track, discRereads: 0))
        XCTAssertTrue(secure.overall.isFinite)
        XCTAssertTrue((0...1).contains(secure.overall))

        var progress = BusyProgress(secure: secure)
        XCTAssertEqual(progress.fraction, secure.overall, "the secure bar wins over the counts")
        progress.secure?.phaseFraction = .infinity
        XCTAssertNotNil(progress.fraction)
        XCTAssertTrue(progress.fraction!.isFinite)
    }

    func testWithKeepsLosslessAndSecure() {
        let secure = Self.secure(ordinal: 2, of: 4, .pass2, 0.5)
        let progress = BusyProgress(completed: 1, total: 4, lossless: true, secure: secure)
        let next = progress.with(completed: 3, total: 5)
        XCTAssertEqual(next.completed, 3)
        XCTAssertEqual(next.total, 5)
        XCTAssertTrue(next.lossless)
        XCTAssertEqual(next.secure, secure)

        XCTAssertEqual(progress.with(completed: -2, total: nil).completed, 0, "still sanitised")
    }

    /// The table the old `DubPane.secureOverall` produced, track 2 of 4.
    func testSecureOverallMatchesTheDubPaneFormula() {
        let cases: [(SecureRipEngine.Phase, Double, Double)] = [
            (.pass1, 0.5, (1 + 0.24) / 4),
            (.pass2, 0, (1 + 0.48) / 4),
            (.retry, 1, (1 + 1.0) / 4),
        ]
        for (phase, fraction, expected) in cases {
            let overall = Self.secure(ordinal: 2, of: 4, phase, fraction).overall
            XCTAssertEqual(overall, expected, accuracy: 1e-12, "\(phase) at \(fraction)")
        }
        XCTAssertEqual(Self.secure(ordinal: 1, of: 0, .pass1, 0).overall, 0, "no tracks never divides by zero")
    }

    func testSecureReadCopiesTheRipProgress() {
        let track = SecureRipEngine.Progress(trackNumber: 7, phase: .retry, fraction: 0.25, rereads: 12)
        let secure = BusySecureRead(SecureDiscRip.Progress(trackOrdinal: 3, trackCount: 9,
                                                           track: track, discRereads: 40))
        XCTAssertEqual(secure.trackOrdinal, 3)
        XCTAssertEqual(secure.trackCount, 9)
        XCTAssertEqual(secure.phase, .retry)
        XCTAssertEqual(secure.phaseFraction, 0.25)
        XCTAssertEqual(secure.rereads, 12, "this track's re-reads, not the disc's")
    }

    func testLabelsAreUppercasedAndCut() {
        XCTAssertEqual(BusyLabels(source: "flac").source, "FLAC")
        XCTAssertEqual(BusyLabels(target: "  mp3 ").target, "MP3", "trimmed")
        XCTAssertEqual(BusyLabels(source: "abcdefghijklmnopqrst").source, "ABCDEFGHIJKL")
        XCTAssertEqual(BusyLabels(source: "hello world xyz").source, "HELLO WORLD",
                       "a cut that lands on a space leaves no trailing space")
        XCTAssertNil(BusyLabels(source: "").source)
        XCTAssertNil(BusyLabels(target: "   ").target)
        XCTAssertNil(BusyLabels().source)

        var labels = BusyLabels()
        labels.target = "aac lc"
        XCTAssertEqual(labels.target, "AAC LC", "sanitised on set too")
        labels.source = "hello world xyz"
        XCTAssertEqual(labels.source, "HELLO WORLD", "re-trimmed after the cut on set too")
    }

    func testDefaultScreens() {
        for kind in BusyJobKind.allCases {
            let expected: BusyScreen
            switch kind {
            case .rip, .secureRead, .download: expected = .dub
            case .convert: expected = .conversion
            case .scan: expected = .scan
            case .transfer: expected = .devices
            }
            XCTAssertEqual(kind.defaultScreen, expected, "\(kind)")
        }
    }

    func testKindLabels() {
        XCTAssertEqual(BusyJobKind.allCases.map(\.label),
                       ["CD-RIP", "SECURE READ", "CONVERT", "SCAN", "DOWNLOAD", "TRANSFER"])
    }

    private static func secure(ordinal: Int, of count: Int, _ phase: SecureRipEngine.Phase,
                               _ fraction: Double) -> BusySecureRead {
        let track = SecureRipEngine.Progress(trackNumber: ordinal, phase: phase, fraction: fraction, rereads: 0)
        return BusySecureRead(SecureDiscRip.Progress(trackOrdinal: ordinal, trackCount: count,
                                                     track: track, discRereads: 0))
    }
}
#endif
