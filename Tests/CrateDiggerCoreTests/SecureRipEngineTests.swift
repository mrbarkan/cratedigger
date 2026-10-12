#if canImport(XCTest)
import Foundation
import XCTest
@testable import CrateDiggerCore

/// A disc in memory. Every sector has a true value; a sector can be scripted to
/// read differently on its next C2 reads (the reads secure extraction makes of
/// the track itself), after which it reads true and clean. Cache-defeating
/// flush reads ask for no C2 and consume nothing.
private final class FakeCDReader: CDSectorReading {
    enum Outcome {
        case clean
        /// A wrong value, the same for the same seed, with no C2 errors: the
        /// kind of misread only comparing two reads can catch.
        case corrupt(UInt8)
        /// C2 errors flagged, over a wrong value or (nil) the true one.
        case c2(corrupt: UInt8?)
        case unreadable
    }

    let sectorCount: Int
    var scripts: [Int: [Outcome]] = [:]
    private(set) var log: [(lba: Int, count: Int, c2: Bool)] = []
    /// The errno a plain (no C2) read starting at this sector fails with.
    var plainError: (Int) -> Int32? = { _ in nil }
    /// The errno every C2 read fails with: a drive that can't do C2.
    var c2Error: Int32?
    /// A clock the engine can read; every C2 read moves it on.
    var now: TimeInterval = 0
    var secondsPerC2Read: TimeInterval = 0

    init(sectorCount: Int) { self.sectorCount = sectorCount }

    static func truth(_ lba: Int) -> Data {
        var state = UInt32(truncatingIfNeeded: lba &* 2_654_435_761 &+ 12345)
        var out = Data(count: CDSector.audioBytes)
        for i in 0..<CDSector.audioBytes {
            state = state &* 1_664_525 &+ 1_013_904_223
            out[i] = UInt8(truncatingIfNeeded: state >> 24)
        }
        return out
    }

    static func corrupted(_ lba: Int, seed: UInt8) -> Data {
        var data = truth(lba)
        for i in stride(from: Int(seed) % 7, to: data.count, by: 97) { data[i] ^= seed | 1 }
        return data
    }

    func readSectors(at lba: Int, count: Int, c2: Bool) throws -> CDSectorRead {
        log.append((lba, count, c2))
        precondition(lba >= 0 && lba + count <= sectorCount, "read past the disc")
        if !c2, let code = plainError(lba) {
            throw CDSectorReadError.readFailed(lba: lba, count: count, errno: code)
        }
        if c2, let code = c2Error {
            throw CDSectorReadError.readFailed(lba: lba, count: count, errno: code)
        }
        if c2 { now += secondsPerC2Read }
        if c2 {
            // A multi-sector read over an unreadable sector fails whole, and
            // consumes nothing: the engine then reads sector by sector.
            let hitsUnreadable = (lba ..< lba + count).contains {
                if case .unreadable? = scripts[$0]?.first { return true } else { return false }
            }
            if hitsUnreadable {
                if count == 1 { scripts[lba]!.removeFirst() }
                throw CDSectorReadError.readFailed(lba: lba, count: count, errno: EIO)
            }
        }
        var audio = Data(capacity: count * CDSector.audioBytes)
        var flags = Data(capacity: count * CDSector.c2Bytes)
        for sector in lba ..< lba + count {
            var outcome = Outcome.clean
            if c2, var script = scripts[sector], !script.isEmpty {
                outcome = script.removeFirst()
                scripts[sector] = script
            }
            var flag = Data(count: CDSector.c2Bytes)
            switch outcome {
            case .clean, .unreadable:
                audio.append(Self.truth(sector))
            case .corrupt(let seed):
                audio.append(Self.corrupted(sector, seed: seed))
            case .c2(let seed):
                audio.append(seed.map { Self.corrupted(sector, seed: $0) } ?? Self.truth(sector))
                flag[10] = 0x40
            }
            flags.append(flag)
        }
        return CDSectorRead(audio: audio, c2: c2 ? flags : nil)
    }
}

final class SecureRipEngineTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecureRipEngineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func engine(_ reader: FakeCDReader, maxAttempts: Int = 20, flush: Int = 100,
                        retryBudget: TimeInterval = 600, maxUnreadableRun: Int = 750) -> SecureRipEngine {
        SecureRipEngine(reader: reader, configuration: .init(
            chunkSectors: 8, flushSectors: flush, maxAttempts: maxAttempts, maxBatchSectors: 4,
            retryBudget: retryBudget, maxUnreadableRun: maxUnreadableRun
        ), clock: { reader.now })
    }

    private func pcm(_ url: URL) throws -> Data {
        try Data(contentsOf: url).dropFirst(WAVFileWriter.headerSize)
    }

    private func truth(_ range: Range<Int>) -> Data {
        range.reduce(into: Data()) { $0.append(FakeCDReader.truth($1)) }
    }

    // MARK: - The algorithm

    func testCleanDiscNeedsNoRetriesAndCopiesTheSource() throws {
        let reader = FakeCDReader(sectorCount: 1000)
        let url = dir.appendingPathComponent("clean.wav")
        let result = try engine(reader).ripTrack(number: 1, sectors: 200..<230, audioArea: 0..<1000, to: url)

        XCTAssertTrue(result.verified)
        XCTAssertEqual(result.sectorCount, 30)
        XCTAssertEqual(result.retriedSectors, 0)
        XCTAssertEqual(result.rereads, 0)
        XCTAssertEqual(result.c2Sectors, 0)
        XCTAssertEqual(try pcm(url), truth(200..<230))
        let file = try Data(contentsOf: url)
        XCTAssertEqual(file.prefix(WAVFileWriter.headerSize), WAVFileWriter.header(dataBytes: 30 * 2352))
    }

    func testSectorThatMisreadsOnceIsReReadAndAccepted() throws {
        let reader = FakeCDReader(sectorCount: 1000)
        reader.scripts[205] = [.corrupt(3)]   // pass 1 wrong, then true from pass 2 on
        let url = dir.appendingPathComponent("once.wav")
        let result = try engine(reader).ripTrack(number: 2, sectors: 200..<230, audioArea: 0..<1000, to: url)

        XCTAssertTrue(result.verified)
        XCTAssertEqual(result.retriedSectors, 1)
        XCTAssertEqual(result.rereads, 1, "pass 2 and one clean re-read agree")
        XCTAssertEqual(try pcm(url), truth(200..<230), "the bad pass-1 value was replaced")
    }

    func testPass2MisreadKeepsPass1ValueOnceARetryAgrees() throws {
        let reader = FakeCDReader(sectorCount: 1000)
        reader.scripts[210] = [.clean, .corrupt(5)]
        let url = dir.appendingPathComponent("pass2.wav")
        let result = try engine(reader).ripTrack(number: 1, sectors: 200..<230, audioArea: 0..<1000, to: url)

        XCTAssertTrue(result.verified)
        XCTAssertEqual(result.retriedSectors, 1)
        XCTAssertEqual(try pcm(url), truth(200..<230))
    }

    func testC2FlaggedSectorThatClearsOnRetryIsAccepted() throws {
        let reader = FakeCDReader(sectorCount: 1000)
        // Pass 1 flags C2 over a wrong value; pass 2 and the retry read clean.
        reader.scripts[201] = [.c2(corrupt: 9)]
        // C2 over the right value is still doubtful until read clean twice.
        reader.scripts[220] = [.clean, .c2(corrupt: nil)]
        let url = dir.appendingPathComponent("c2.wav")
        let result = try engine(reader).ripTrack(number: 1, sectors: 200..<230, audioArea: 0..<1000, to: url)

        XCTAssertTrue(result.verified)
        XCTAssertEqual(result.c2Sectors, 2)
        XCTAssertEqual(result.retriedSectors, 2)
        XCTAssertEqual(result.rereads, 2)
        XCTAssertEqual(try pcm(url), truth(200..<230))
    }

    func testSectorThatNeverAgreesIsSuspiciousAndKeepsTheMostFrequentValue() throws {
        let reader = FakeCDReader(sectorCount: 1000)
        // Six re-reads: value 9 comes back three times but always with C2
        // errors, so it can never be accepted, yet it's the most frequent.
        reader.scripts[207] = [.corrupt(1), .corrupt(2),
                               .c2(corrupt: 9), .corrupt(11), .c2(corrupt: 9),
                               .corrupt(13), .c2(corrupt: 9), .corrupt(15)]
        let url = dir.appendingPathComponent("never.wav")
        let result = try engine(reader, maxAttempts: 6)
            .ripTrack(number: 4, sectors: 200..<230, audioArea: 0..<1000, to: url)

        XCTAssertFalse(result.verified)
        XCTAssertEqual(result.suspiciousSectors, [7])
        XCTAssertEqual(result.suspiciousRanges, [7...7])
        XCTAssertEqual(result.rereads, 6)
        var expected = truth(200..<230)
        expected.replaceSubrange(7 * 2352 ..< 8 * 2352, with: FakeCDReader.corrupted(207, seed: 9))
        XCTAssertEqual(try pcm(url), expected)
    }

    func testUnreadableSectorIsRecoveredFromLaterReads() throws {
        let reader = FakeCDReader(sectorCount: 1000)
        reader.scripts[212] = [.unreadable]
        let url = dir.appendingPathComponent("eio.wav")
        let result = try engine(reader).ripTrack(number: 1, sectors: 200..<230, audioArea: 0..<1000, to: url)

        XCTAssertTrue(result.verified)
        XCTAssertEqual(result.retriedSectors, 1)
        XCTAssertEqual(try pcm(url), truth(200..<230), "pass 2's read replaced the silence")
    }

    func testAdjacentDoubtfulSectorsAreReReadTogether() throws {
        let reader = FakeCDReader(sectorCount: 1000)
        for sector in 203...205 { reader.scripts[sector] = [.corrupt(2)] }
        let url = dir.appendingPathComponent("run.wav")
        _ = try engine(reader).ripTrack(number: 1, sectors: 200..<230, audioArea: 0..<1000, to: url)

        let retryReads = reader.log.filter { $0.c2 && $0.lba == 203 && $0.count == 3 }
        XCTAssertEqual(retryReads.count, 1, "one read covers the run")
    }

    // MARK: - Defeating the drive cache

    func testShortTrackFlushesFarAwayBeforePass2() throws {
        let reader = FakeCDReader(sectorCount: 1000)
        let url = dir.appendingPathComponent("flush.wav")
        _ = try engine(reader, flush: 100).ripTrack(number: 1, sectors: 0..<20, audioArea: 0..<1000, to: url)

        let trackReads = reader.log.indices.filter { reader.log[$0].c2 && reader.log[$0].lba == 0 }
        XCTAssertEqual(trackReads.count, 2, "pass 1 and pass 2 each start at the track")
        // Pass 1 is reads 0, 8 and 16; everything from there to pass 2 is flush.
        XCTAssertEqual(reader.log[trackReads[0] + 2].lba, 16)
        let between = reader.log[(trackReads[0] + 3) ..< trackReads[1]]
        XCTAssertFalse(between.isEmpty)
        XCTAssertTrue(between.allSatisfy { !$0.c2 && $0.lba >= 900 }, "flush reads the far end of the disc")
        XCTAssertEqual(between.map(\.count).reduce(0, +), 100)
    }

    func testLongTrackFlushesItself() throws {
        let reader = FakeCDReader(sectorCount: 1000)
        let url = dir.appendingPathComponent("long.wav")
        _ = try engine(reader, flush: 100).ripTrack(number: 1, sectors: 0..<150, audioArea: 0..<1000, to: url)
        XCTAssertTrue(reader.log.allSatisfy(\.c2), "no separate flush read")
    }

    func testEveryRetryAttemptIsPrecededByAFlush() throws {
        let reader = FakeCDReader(sectorCount: 1000)
        reader.scripts[905] = [.corrupt(1), .corrupt(2), .corrupt(3)]
        let url = dir.appendingPathComponent("retry-flush.wav")
        _ = try engine(reader, flush: 100).ripTrack(number: 1, sectors: 900..<910, audioArea: 0..<1000, to: url)

        // Passes 1 and 2 and the first re-read all differ; re-reads two and
        // three agree. Each comes straight after a flush at the far (head) end.
        let retries = reader.log.indices.filter { reader.log[$0].c2 && reader.log[$0].lba == 905 }
        XCTAssertEqual(retries.count, 3)
        for index in retries {
            XCTAssertFalse(reader.log[index - 1].c2)
            XCTAssertLessThan(reader.log[index - 1].lba, 100)
        }
    }

    func testFlushRegionPicksTheFarEndAndClamps() {
        XCTAssertEqual(SecureRipEngine.flushRegion(awayFrom: 0..<20, audioArea: 0..<1000, length: 100), 900..<1000)
        XCTAssertEqual(SecureRipEngine.flushRegion(awayFrom: 950..<990, audioArea: 0..<1000, length: 100), 0..<100)
        // Too short for a whole flush: what there is beside the range, never the range itself.
        XCTAssertEqual(SecureRipEngine.flushRegion(awayFrom: 0..<20, audioArea: 0..<60, length: 4500), 20..<60)
        XCTAssertEqual(SecureRipEngine.flushRegion(awayFrom: 30..<40, audioArea: 0..<60, length: 4500), 0..<30)
        XCTAssertNil(SecureRipEngine.flushRegion(awayFrom: 0..<20, audioArea: 0..<0, length: 4500))
        XCTAssertNil(SecureRipEngine.flushRegion(awayFrom: 0..<60, audioArea: 0..<60, length: 4500), "a one-track disc has nowhere else")
    }

    /// Reading the sectors about to be re-read would put them back in the cache.
    func testFlushRegionNeverOverlapsWhatIsAboutToBeReRead() {
        for area in [0..<60, 0..<150, 0..<1000, 300..<400] {
            for lower in stride(from: area.lowerBound, to: area.upperBound, by: 7) {
                for length in [1, 5, 40] where lower + length <= area.upperBound {
                    let range = lower ..< lower + length
                    for flush in [10, 100, 4500] {
                        guard let region = SecureRipEngine.flushRegion(awayFrom: range, audioArea: area, length: flush) else {
                            XCTAssertEqual(range, area)
                            continue
                        }
                        XCTAssertFalse(region.overlaps(range), "\(region) overlaps \(range) in \(area)")
                        XCTAssertTrue(region.lowerBound >= area.lowerBound && region.upperBound <= area.upperBound)
                        XCTAssertLessThanOrEqual(region.count, flush)
                    }
                }
            }
        }
    }

    func testBatchesSplitAtGapsAndAtTheLimit() {
        XCTAssertEqual(SecureRipEngine.batches([1, 2, 3, 7, 8, 20], maxLength: 2), [[1, 2], [3], [7, 8], [20]])
        XCTAssertEqual(SecureRipEngine.batches([], maxLength: 4), [])
    }

    // MARK: - Control

    func testCancellationStopsBetweenReadsAndRemovesThePartialFile() throws {
        let reader = FakeCDReader(sectorCount: 1000)
        let url = dir.appendingPathComponent("cancel.wav")
        var polls = 0
        XCTAssertThrowsError(try engine(reader).ripTrack(
            number: 1, sectors: 0..<200, audioArea: 0..<1000, to: url,
            isCancelled: { polls += 1; return polls > 3 }
        )) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(reader.log.count, 3, "stopped at the next chunk boundary")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// A scratch the drive can't read sends the engine sector by sector, and a
    /// drive retrying a bad sector can take seconds on each one. Cancel has to
    /// land between those reads, not only once the whole chunk is done.
    func testCancellationIsHeardWhileReadingABadPatchSectorBySector() throws {
        let reader = FakeCDReader(sectorCount: 1000)
        for sector in 0..<8 { reader.scripts[sector] = [.unreadable] }
        let url = dir.appendingPathComponent("cancel-bad.wav")
        var polls = 0
        XCTAssertThrowsError(try engine(reader).ripTrack(
            number: 1, sectors: 0..<200, audioArea: 0..<1000, to: url,
            isCancelled: { polls += 1; return polls > 2 }
        )) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(reader.log.count, 2, "the failed chunk read and one single-sector read")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testProgressWalksThePhasesInOrder() throws {
        let reader = FakeCDReader(sectorCount: 1000)
        reader.scripts[3] = [.corrupt(1)]
        let url = dir.appendingPathComponent("progress.wav")
        var seen: [SecureRipEngine.Progress] = []
        _ = try engine(reader).ripTrack(number: 6, sectors: 0..<30, audioArea: 0..<1000, to: url,
                                        progress: { seen.append($0) })
        let phases = seen.map(\.phase).reduce(into: [SecureRipEngine.Phase]()) { if $0.last != $1 { $0.append($1) } }
        XCTAssertEqual(phases, [.pass1, .pass2, .retry])
        XCTAssertTrue(seen.allSatisfy { $0.trackNumber == 6 })
        XCTAssertEqual(seen.last?.fraction, 1)
        XCTAssertEqual(seen.last?.rereads, 1)
    }

    func testAReadErrorThatIsNotTheDiscEndsTheRip() {
        final class EjectedReader: CDSectorReading {
            func readSectors(at lba: Int, count: Int, c2: Bool) throws -> CDSectorRead {
                throw CDSectorReadError.readFailed(lba: lba, count: count, errno: ENXIO)
            }
        }
        let url = dir.appendingPathComponent("ejected.wav")
        XCTAssertThrowsError(try SecureRipEngine(reader: EjectedReader())
            .ripTrack(number: 1, sectors: 0..<10, audioArea: 0..<100, to: url)) { error in
            XCTAssertEqual(error as? CDSectorReadError, .readFailed(lba: 0, count: 10, errno: ENXIO))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testADriveThatIgnoresTheC2RequestFailsLoudly() {
        final class NoC2Reader: CDSectorReading {
            func readSectors(at lba: Int, count: Int, c2: Bool) throws -> CDSectorRead {
                CDSectorRead(audio: Data(count: count * CDSector.audioBytes), c2: nil)
            }
        }
        XCTAssertThrowsError(try SecureRipEngine(reader: NoC2Reader())
            .ripTrack(number: 1, sectors: 0..<10, audioArea: 0..<100,
                      to: dir.appendingPathComponent("noc2.wav"))) { error in
            XCTAssertEqual(error as? CDSectorReadError, .shortRead(expectedSectors: 10))
        }
    }

    // MARK: - A whole disc

    func testDiscRipReadsEachTrackInOrderAndCountsReReadsAcrossTheDisc() throws {
        let reader = FakeCDReader(sectorCount: 1000)
        reader.scripts[2] = [.corrupt(1)]
        reader.scripts[45] = [.corrupt(1)]
        let volume = URL(fileURLWithPath: "/Volumes/Audio CD")
        let plans = [
            SecureRipTrackPlan(trackNumber: 1, sourceURL: volume.appendingPathComponent("1 Audio Track.aiff"), sectors: 0..<40),
            SecureRipTrackPlan(trackNumber: 2, sourceURL: volume.appendingPathComponent("2 Audio Track.aiff"), sectors: 40..<70)
        ]
        var seen: [SecureDiscRip.Progress] = []
        let outputs = try SecureDiscRip.run(plans: plans, audioArea: 0..<1000, engine: engine(reader),
                                            into: dir, progress: { seen.append($0) })

        XCTAssertEqual(outputs.map(\.plan), plans)
        XCTAssertEqual(outputs.map(\.wavURL.lastPathComponent), ["track-01.wav", "track-02.wav"])
        XCTAssertTrue(outputs.allSatisfy(\.result.verified))
        XCTAssertEqual(try pcm(outputs[1].wavURL), truth(40..<70))
        XCTAssertEqual(Set(seen.map(\.trackCount)), [2])
        XCTAssertEqual(seen.first?.trackOrdinal, 1)
        XCTAssertEqual(seen.last?.trackOrdinal, 2)
        XCTAssertEqual(seen.last?.discRereads, 2, "track 1's re-read carries into track 2's count")
    }

    func testFailureMessagesSayHowToRipAnyway() {
        let messages = [
            SecureDiscRip.failureMessage(for: CDSectorReadError.deviceUnavailable(path: "/dev/rdisk9", errno: EACCES)),
            SecureDiscRip.failureMessage(for: CDSectorReadError.readFailed(lba: 0, count: 128, errno: ENXIO)),
            SecureDiscRip.failureMessage(for: CDSectorReadError.shortRead(expectedSectors: 128)),
            SecureDiscRip.failureMessage(for: SecureRipTrackPlan.PlanError.noTableOfContents),
            SecureDiscRip.failureMessage(for: CocoaError(.fileWriteOutOfSpace))
        ]
        for message in messages {
            XCTAssertTrue(message.localizedCaseInsensitiveContains("turn Secure Mode off to rip normally"), message)
            XCTAssertFalse(message.contains("\u{2014}") || message.contains("\u{2013}"), "no em or en dashes: \(message)")
        }
        XCTAssertTrue(messages[0].contains("errno \(EACCES)"))
        XCTAssertTrue(messages[1].contains("errno \(ENXIO)"))
    }

    func testCancellationFlag() {
        let flag = SecureRipCancellation()
        XCTAssertFalse(flag.isCancelled)
        flag.cancel()
        XCTAssertTrue(flag.isCancelled)
    }

    // MARK: - Unreadable tracks

    /// Ten seconds of audio the drive can't read in a row is not a scratch to
    /// re-read: the disc is gone or ruined, and going on would write silence.
    func testALongRunOfUnreadableSectorsStopsTheRip() throws {
        let reader = FakeCDReader(sectorCount: 3000)
        for sector in 1000...1750 { reader.scripts[sector] = [.unreadable] }   // 751 in a row
        let url = dir.appendingPathComponent("gone.wav")
        // 5% of 20,000 sectors is 1,000, so only the run rule can stop this.
        let big = FakeCDReader(sectorCount: 20_000)
        big.scripts = reader.scripts
        XCTAssertThrowsError(try engine(big).ripTrack(number: 3, sectors: 0..<20_000, audioArea: 0..<20_000, to: url)) {
            XCTAssertEqual($0 as? CDSectorReadError, .tooManyUnreadable(track: 3, sectors: 751))
        }
        XCTAssertFalse(big.log.contains { $0.lba >= 1760 }, "stopped in pass 1, at the run")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testARunJustUnderTheLimitIsReReadAsUsual() throws {
        let reader = FakeCDReader(sectorCount: 1000)
        for sector in 210..<215 { reader.scripts[sector] = [.unreadable] }   // 5 in a row
        let url = dir.appendingPathComponent("short-run.wav")
        let result = try engine(reader, maxUnreadableRun: 5)
            .ripTrack(number: 1, sectors: 200..<400, audioArea: 0..<1000, to: url)
        XCTAssertTrue(result.verified)
        XCTAssertEqual(try pcm(url), truth(200..<400))

        let worse = FakeCDReader(sectorCount: 1000)
        for sector in 210..<216 { worse.scripts[sector] = [.unreadable] }    // 6 in a row
        XCTAssertThrowsError(try engine(worse, maxUnreadableRun: 5)
            .ripTrack(number: 1, sectors: 200..<400, audioArea: 0..<1000, to: url)) {
            XCTAssertEqual($0 as? CDSectorReadError, .tooManyUnreadable(track: 1, sectors: 6))
        }
    }

    /// Scattered, but more than 5% of the track.
    func testTooLargeAShareOfUnreadableSectorsStopsTheRip() throws {
        let fine = FakeCDReader(sectorCount: 1000)
        for sector in stride(from: 105, to: 155, by: 10) { fine.scripts[sector] = [.unreadable] }   // 5 of 100
        let url = dir.appendingPathComponent("share.wav")
        XCTAssertTrue(try engine(fine).ripTrack(number: 2, sectors: 100..<200, audioArea: 0..<1000, to: url).verified)

        let bad = FakeCDReader(sectorCount: 1000)
        for sector in stride(from: 105, to: 165, by: 10) { bad.scripts[sector] = [.unreadable] }    // 6 of 100
        XCTAssertThrowsError(try engine(bad).ripTrack(number: 2, sectors: 100..<200, audioArea: 0..<1000, to: url)) {
            XCTAssertEqual($0 as? CDSectorReadError, .tooManyUnreadable(track: 2, sectors: 6))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let message = SecureDiscRip.failureMessage(for: CDSectorReadError.tooManyUnreadable(track: 2, sectors: 900))
        XCTAssertTrue(message.contains("track 2") && message.contains("12 seconds") && message.contains("ejected"), message)
    }

    // MARK: - Retry budget

    /// Each re-read here costs a minute of the fake clock, so a ten-minute
    /// budget buys ten attempts. Sector 5 never agrees and spends all of it;
    /// sector 25, which one more read would have settled, never gets a turn.
    func testRetryBudgetStopsRetryingAndMarksTheRestSuspicious() throws {
        let reader = FakeCDReader(sectorCount: 1000)
        reader.secondsPerC2Read = 60
        reader.scripts[205] = (1...40).map { .corrupt(UInt8($0)) }
        reader.scripts[225] = [.corrupt(7)]
        let url = dir.appendingPathComponent("budget.wav")
        let result = try engine(reader, retryBudget: 600)
            .ripTrack(number: 5, sectors: 200..<230, audioArea: 0..<1000, to: url)

        XCTAssertEqual(result.retriedSectors, 2)
        XCTAssertEqual(result.rereads, 10)
        XCTAssertEqual(result.suspiciousSectors, [5, 25])
        XCTAssertEqual(result.retryBudgetExhausted, 600)
        XCTAssertFalse(reader.log.contains { $0.c2 && $0.lba == 225 && $0.count == 1 }, "no attempt after the budget")
        // Sector 25 keeps pass 1's value, the one already in the file.
        var expected = truth(200..<230)
        expected.replaceSubrange(25 * 2352 ..< 26 * 2352, with: FakeCDReader.corrupted(225, seed: 7))
        expected.replaceSubrange(5 * 2352 ..< 6 * 2352, with: FakeCDReader.corrupted(205, seed: 1))
        XCTAssertEqual(try pcm(url), expected)
        XCTAssertTrue(SecureRipReport.summary([result]).contains("Track 5: retrying stopped after 10 minutes, so it couldn't verify 00:00."),
                      SecureRipReport.summary([result]))
    }

    func testRetryingThatFinishesInsideTheBudgetIsNotReportedAsCut() throws {
        let reader = FakeCDReader(sectorCount: 1000)
        reader.secondsPerC2Read = 60
        reader.scripts[205] = [.corrupt(1)]
        let result = try engine(reader, retryBudget: 600)
            .ripTrack(number: 1, sectors: 200..<230, audioArea: 0..<1000, to: dir.appendingPathComponent("in-budget.wav"))
        XCTAssertTrue(result.verified)
        XCTAssertNil(result.retryBudgetExhausted)
    }

    // MARK: - Probing the drive

    private func twoTrackPlans() -> [SecureRipTrackPlan] {
        let volume = URL(fileURLWithPath: "/Volumes/Audio CD")
        return [
            SecureRipTrackPlan(trackNumber: 1, sourceURL: volume.appendingPathComponent("1 Audio Track.aiff"), sectors: 0..<40),
            SecureRipTrackPlan(trackNumber: 2, sourceURL: volume.appendingPathComponent("2 Audio Track.aiff"), sectors: 40..<70)
        ]
    }

    private func wavs() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".wav") }
    }

    func testProbeReadsTheStartMiddleAndEndBeforeRipping() throws {
        let reader = FakeCDReader(sectorCount: 1000)
        _ = try SecureDiscRip.run(plans: twoTrackPlans(), audioArea: 0..<70, engine: engine(reader), into: dir)
        XCTAssertEqual(reader.log.first.map { [$0.lba, $0.count] }, [0, 1])
        XCTAssertEqual(Array(reader.log.prefix(3).map(\.lba)), [0, 35, 69])
        XCTAssertTrue(reader.log.prefix(3).allSatisfy { !$0.c2 })
        XCTAssertTrue(reader.log[3].c2 && reader.log[3].count == 1, "then one C2 read")
    }

    func testADriveThatCantReadTheDiscRawStopsBeforeAnythingIsRipped() throws {
        let reader = FakeCDReader(sectorCount: 1000)
        reader.plainError = { _ in EIO }
        reader.c2Error = EIO
        XCTAssertThrowsError(try SecureDiscRip.run(plans: twoTrackPlans(), audioArea: 0..<70, engine: engine(reader), into: dir)) {
            XCTAssertEqual(($0 as? CDSectorReadError)?.isMediaError, true)
            XCTAssertTrue(SecureDiscRip.failureMessage(for: $0).contains("couldn't read the disc directly"))
        }
        XCTAssertEqual(reader.log.count, 3, "the three probes, nothing more")
        XCTAssertEqual(try wavs(), [])
    }

    func testADriveWithoutC2StopsBeforeAnythingIsRipped() throws {
        let reader = FakeCDReader(sectorCount: 1000)
        reader.c2Error = EIO
        XCTAssertThrowsError(try SecureDiscRip.run(plans: twoTrackPlans(), audioArea: 0..<70, engine: engine(reader), into: dir)) {
            XCTAssertEqual($0 as? CDSectorReadError, .noC2Support)
            let message = SecureDiscRip.failureMessage(for: $0)
            XCTAssertTrue(message.contains("can't report read errors (C2)") && message.contains("Turn Secure Mode off to rip normally"), message)
        }
        XCTAssertEqual(reader.log.count, 6, "three plain probes and three C2 probes")
        XCTAssertEqual(try wavs(), [])

        let refusing = FakeCDReader(sectorCount: 1000)
        refusing.c2Error = EINVAL
        XCTAssertThrowsError(try SecureDiscRip.run(plans: twoTrackPlans(), audioArea: 0..<70, engine: engine(refusing), into: dir)) {
            XCTAssertEqual($0 as? CDSectorReadError, .noC2Support)
        }
    }

    func testOneScratchedProbeSpotDoesNotCondemnTheDrive() throws {
        let reader = FakeCDReader(sectorCount: 1000)
        reader.plainError = { $0 == 0 ? EIO : nil }
        let outputs = try SecureDiscRip.run(plans: twoTrackPlans(), audioArea: 0..<70, engine: engine(reader), into: dir)
        XCTAssertEqual(outputs.count, 2)
    }

    func testADriveThatVanishesDuringTheProbeIsReportedAsThat() throws {
        let reader = FakeCDReader(sectorCount: 1000)
        reader.plainError = { _ in ENXIO }
        XCTAssertThrowsError(try SecureDiscRip.run(plans: twoTrackPlans(), audioArea: 0..<70, engine: engine(reader), into: dir)) {
            XCTAssertEqual($0 as? CDSectorReadError, .readFailed(lba: 0, count: 1, errno: ENXIO))
        }
    }

    // MARK: - Hashing

    /// Pass 1 and pass 2 are compared by hash alone, so two different reads
    /// must not hash alike. Plain FNV-1a over 64-bit words could not see a
    /// difference confined to bit 63 of two words: the multiply carries only
    /// upward, so the first flip survives untouched until the second cancels
    /// it. Here that is the sign bit of two right-channel samples.
    func testSectorHashSeesTopBitFlipsThatWouldCancel() {
        let truth = FakeCDReader.truth(5)
        var twoSignBits = truth
        twoSignBits[7] ^= 0x80
        twoSignBits[15] ^= 0x80
        XCTAssertNotEqual(SectorHash.hash(truth), SectorHash.hash(twoSignBits))

        var fourSignBits = twoSignBits
        fourSignBits[2343] ^= 0x80
        fourSignBits[2351] ^= 0x80
        XCTAssertNotEqual(SectorHash.hash(truth), SectorHash.hash(fourSignBits))
    }

    func testSectorHashSeesEverySingleBitFlip() {
        let truth = FakeCDReader.truth(9)
        let base = SectorHash.hash(truth)
        for byte in stride(from: 0, to: CDSector.audioBytes, by: 37) {
            for bit in 0..<8 {
                var flipped = truth
                flipped[byte] ^= UInt8(1 << bit)
                XCTAssertNotEqual(SectorHash.hash(flipped), base, "byte \(byte) bit \(bit)")
            }
        }
    }

    // MARK: - Tallying

    func testMostFrequentPrefersAValueThatCanBeWritten() {
        var tally = SectorTally()
        tally.vote(hash: 1, clean: false, bytes: nil)   // pass 1, in the file
        tally.onDisk = 1
        tally.vote(hash: 2, clean: true, bytes: nil)    // pass 2, bytes not kept
        XCTAssertEqual(tally.mostFrequent()?.hash, 1)
        tally.vote(hash: 3, clean: true, bytes: Data([0]))
        tally.vote(hash: 3, clean: false, bytes: Data([0]))
        XCTAssertEqual(tally.mostFrequent()?.hash, 3)
    }
}

// MARK: - WAV, positions, TOC

final class SecureRipFormatTests: XCTestCase {
    func testWAVHeaderBytes() {
        let header = WAVFileWriter.header(dataBytes: 2352 * 75)   // one second
        let expected: [UInt8] = [
            0x52, 0x49, 0x46, 0x46,  0x34, 0xB1, 0x02, 0x00,  // "RIFF", 36 + 176400
            0x57, 0x41, 0x56, 0x45,                           // "WAVE"
            0x66, 0x6D, 0x74, 0x20,  0x10, 0x00, 0x00, 0x00,  // "fmt ", 16
            0x01, 0x00,  0x02, 0x00,                          // PCM, stereo
            0x44, 0xAC, 0x00, 0x00,                           // 44100
            0x10, 0xB1, 0x02, 0x00,                           // 176400 bytes/s
            0x04, 0x00,  0x10, 0x00,                          // align 4, 16-bit
            0x64, 0x61, 0x74, 0x61,  0x10, 0xB1, 0x02, 0x00   // "data", 176400
        ]
        XCTAssertEqual(Array(header), expected)
    }

    func testWriterPatchesSizesAndReplacesSectorsInPlace() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wav-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WAVFileWriter(url: url)
        try writer.append(Data(repeating: 1, count: 2352 * 2))
        try writer.replaceSector(0, with: Data(repeating: 7, count: 2352))
        try writer.append(Data(repeating: 2, count: 2352))
        try writer.finish()

        let file = try Data(contentsOf: url)
        XCTAssertEqual(file.prefix(44), WAVFileWriter.header(dataBytes: 2352 * 3))
        let pcm = Array(file.dropFirst(44))
        XCTAssertEqual(pcm.count, 2352 * 3)
        XCTAssertEqual(Set(pcm[0..<2352]), [7])
        XCTAssertEqual(Set(pcm[2352..<4704]), [1])
        XCTAssertEqual(Set(pcm[4704...]), [2])
    }

    func testTimecodes() {
        XCTAssertEqual(CDTimecode.format(sector: 0), "00:00.00")
        XCTAssertEqual(CDTimecode.format(sector: 74), "00:00.74")
        XCTAssertEqual(CDTimecode.format(sector: 75), "00:01.00")
        XCTAssertEqual(CDTimecode.format(sector: 4501), "01:00.01")
        XCTAssertEqual(CDTimecode.format(sector: 75 * 754 + 12), "12:34.12")
        XCTAssertEqual(CDTimecode.formatMinutesSeconds(sector: 75 * 134 + 70), "02:14")
    }

    func testSuspiciousRangesCollapseRuns() {
        let result = SecureRipTrackResult(trackNumber: 1, sectorCount: 100, retriedSectors: 5, rereads: 100,
                                          c2Sectors: 5, suspiciousSectors: [40, 3, 4, 5, 41],
                                          timing: .init())
        XCTAssertEqual(result.suspiciousRanges, [3...5, 40...41])
    }

    func testSummaryWhenEverythingVerified() {
        let results = (1...14).map {
            SecureRipTrackResult(trackNumber: $0, sectorCount: 10, retriedSectors: 0, rereads: 0,
                                 c2Sectors: 0, suspiciousSectors: [], timing: .init())
        }
        XCTAssertEqual(SecureRipReport.summary(results), "All 14 tracks verified: every sector read identically.")
    }

    func testSummaryNamesUnverifiedPositions() {
        let ok = SecureRipTrackResult(trackNumber: 1, sectorCount: 10, retriedSectors: 0, rereads: 0,
                                      c2Sectors: 0, suspiciousSectors: [], timing: .init())
        let bad = SecureRipTrackResult(trackNumber: 3, sectorCount: 30_000, retriedSectors: 9, rereads: 180,
                                       c2Sectors: 9, suspiciousSectors: [75 * 62, 75 * 130, 75 * 130 + 1, 75 * 134],
                                       timing: .init())
        XCTAssertEqual(SecureRipReport.summary([ok, bad]), """
        1 of 2 tracks verified.
        Track 3: couldn't verify 01:02, 02:10, 02:14.
        Clean the disc and re-rip that track.
        """)
        let run = SecureRipTrackResult(trackNumber: 2, sectorCount: 30_000, retriedSectors: 9, rereads: 180,
                                       c2Sectors: 9, suspiciousSectors: Array(75 * 10 ... 75 * 12),
                                       timing: .init())
        XCTAssertTrue(SecureRipReport.summary([run]).contains("00:10 to 00:12"))
    }

    /// The disc this was built against: three tracks, read raw and compared
    /// with cddafs's own `.aiff` files byte for byte.
    func testTOCMapsToLogicalBlocks() throws {
        let toc = CompactDiscTOC(firstTrack: 1, lastTrack: 3, leadoutBlock: 96550,
                                 trackOffsets: [150, 11382, 43252])
        XCTAssertEqual(toc.trackLBARanges, [0..<11232, 11232..<43102, 43102..<96400])
        XCTAssertEqual(toc.audioLBARange, 0..<96400)

        let volume = URL(fileURLWithPath: "/Volumes/Audio CD")
        let tracks = (1...3).reversed().map {
            CDTrack(fileURL: volume.appendingPathComponent("\($0) Audio Track.aiff"), title: "\($0) Audio Track", trackNumber: $0)
        }
        let plans = try SecureRipTrackPlan.plans(for: tracks, toc: toc)
        XCTAssertEqual(plans.map(\.trackNumber), [1, 2, 3])
        XCTAssertEqual(plans.map(\.sectors), toc.trackLBARanges)
        XCTAssertEqual(plans[1].sourceURL.lastPathComponent, "2 Audio Track.aiff")

        XCTAssertThrowsError(try SecureRipTrackPlan.plans(for: Array(tracks.prefix(2)), toc: toc)) {
            XCTAssertEqual($0 as? SecureRipTrackPlan.PlanError, .trackCountMismatch(files: 2, toc: 3))
        }
        XCTAssertThrowsError(try SecureRipTrackPlan.plans(for: tracks, toc: nil))
    }

    /// Checked against a real drive too: the audio plane of a C2 read matched
    /// cddafs's `.aiff` byte for byte. This pins which bytes are which.
    func testC2ReadSplitsEachSectorsAudioFromItsFlags() {
        var interleaved = Data()
        for sector in 0..<3 {
            interleaved.append(Data(repeating: UInt8(0x10 + sector), count: CDSector.audioBytes))
            interleaved.append(Data(repeating: UInt8(0xF0 + sector), count: CDSector.c2Bytes))
        }
        let read = RawCDDevice.splitInterleaved(interleaved, count: 3)
        XCTAssertEqual(read.audio.count, 3 * 2352)
        XCTAssertEqual(read.c2?.count, 3 * 294)
        for sector in 0..<3 {
            XCTAssertEqual(Set(read.audio[sector * 2352 ..< (sector + 1) * 2352]), [UInt8(0x10 + sector)])
            XCTAssertEqual(Set(read.c2![sector * 294 ..< (sector + 1) * 294]), [UInt8(0xF0 + sector)])
        }
    }

    func testRawDevicePath() {
        XCTAssertEqual(RawCDDevice.rawDevicePath(forMountedFrom: "/dev/disk13"), "/dev/rdisk13")
        XCTAssertNil(RawCDDevice.rawDevicePath(forMountedFrom: "map auto_home"))
    }

    func testSecureModeIsOffByDefault() {
        let suite = "SecureRipFormatTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = PreferencesStore(defaults: defaults)
        XCTAssertFalse(prefs.secureRipEnabled)
        prefs.secureRipEnabled = true
        XCTAssertTrue(PreferencesStore(defaults: defaults).secureRipEnabled)
    }
}
#endif
