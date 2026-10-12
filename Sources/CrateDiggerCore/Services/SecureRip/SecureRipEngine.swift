import Foundation

/// Verified ("secure") extraction of one CD track to a WAV file.
///
/// A drive reading audio has no checksum to fail on: a scratch it can't
/// correct comes back as plausible-looking samples. So every sector is read
/// twice and the two compared, with the drive's C2 error pointers as a second
/// witness, and anything doubtful is re-read until it reads the same twice
/// with no C2 errors:
///
/// 1. Pass 1 reads the track in order, streaming the audio to the WAV and
///    keeping a 64-bit hash per sector plus the sectors C2 flagged.
/// 2. Pass 2 reads it again and compares. A drive caches what it just read,
///    though, and a second pass served from that cache proves nothing, so a
///    track shorter than the cache is preceded by a "flush" read of audio far
///    away. A longer track pushes its own start out of the cache.
/// 3. Every sector that differed, or carried C2 errors in either pass, is
///    re-read (adjacent ones together, each attempt after its own flush) until
///    one value has been read twice with no C2 errors. That value goes into
///    the WAV. A sector that never gets there within `maxAttempts`, or before
///    the track's retry budget runs out, keeps the value read most often and
///    is reported as suspicious.
///
/// A track the drive mostly can't read at all is not ripped: past
/// `maxUnreadableRun` consecutive unreadable sectors, or `maxUnreadableFraction`
/// of the track, pass 1 stops with `CDSectorReadError.tooManyUnreadable`. Those
/// sectors would otherwise go into the file as silence.
///
/// Memory stays bounded by a chunk and one batch's candidate values; the track
/// itself only ever lives in the file.
///
/// Out of scope here: the drive's read offset, and AccurateRip / CTDB, which
/// check against other people's rips rather than against this drive.
public struct SecureRipEngine {
    public struct Configuration: Sendable, Equatable {
        /// Sectors per sequential read. Bigger reads stream faster; this is
        /// also how often cancellation is checked (128 ≈ 1.7 s of audio).
        public var chunkSectors: Int
        /// The cache-defeating read. 4500 sectors ≈ 10 MB, past the cache of
        /// any drive in common use (2 to 8 MB).
        public var flushSectors: Int
        /// Re-reads per doubtful sector before giving up on agreement.
        public var maxAttempts: Int
        /// Adjacent doubtful sectors re-read in one go. A scratch spans a run
        /// of them, and one read of the run beats one seek per sector.
        public var maxBatchSectors: Int
        /// Seconds the retry phase may spend on one track. Every attempt costs
        /// a full flush (about 14 s on a 4x drive), so a disc with many bad
        /// spots could otherwise re-read for hours. What is still doubtful
        /// when it runs out keeps its most frequent value and is suspicious.
        public var retryBudget: TimeInterval
        /// Consecutive unreadable sectors in pass 1 that stop the rip. 750 is
        /// ten seconds of audio: past a scratch, into a disc that's gone.
        public var maxUnreadableRun: Int
        /// Share of a track unreadable in pass 1 that stops the rip.
        public var maxUnreadableFraction: Double

        public init(chunkSectors: Int = 128, flushSectors: Int = 4500,
                    maxAttempts: Int = 20, maxBatchSectors: Int = 64,
                    retryBudget: TimeInterval = 600,
                    maxUnreadableRun: Int = 750, maxUnreadableFraction: Double = 0.05) {
            self.chunkSectors = max(1, chunkSectors)
            self.flushSectors = max(0, flushSectors)
            self.maxAttempts = max(1, maxAttempts)
            self.maxBatchSectors = max(1, maxBatchSectors)
            self.retryBudget = max(0, retryBudget)
            self.maxUnreadableRun = max(1, maxUnreadableRun)
            self.maxUnreadableFraction = min(max(0, maxUnreadableFraction), 1)
        }

        public static let standard = Configuration()
    }

    public enum Phase: String, Sendable, Equatable {
        case pass1, pass2, retry
    }

    public struct Progress: Sendable, Equatable {
        public var trackNumber: Int
        public var phase: Phase
        /// 0…1 within the phase.
        public var fraction: Double
        /// Sector re-reads so far on this track.
        public var rereads: Int

        public init(trackNumber: Int, phase: Phase, fraction: Double, rereads: Int) {
            self.trackNumber = trackNumber
            self.phase = phase
            self.fraction = fraction
            self.rereads = rereads
        }
    }

    public let reader: CDSectorReading
    public let configuration: Configuration
    private let clock: () -> TimeInterval

    public init(reader: CDSectorReading, configuration: Configuration = .standard,
                clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.reader = reader
        self.configuration = configuration
        self.clock = clock
    }

    /// Extract `sectors` (logical blocks) to a WAV at `url`.
    ///
    /// - Parameters:
    ///   - audioArea: every logical block of audio on the disc, which bounds
    ///     where a cache-defeating read may go.
    ///   - isCancelled: polled between reads; a true answer throws
    ///     `CancellationError` and removes the partial file.
    /// - Throws: `CDSectorReadError` when the drive can't be read at all (a
    ///   media error on a bad sector is not that: it's re-read), file errors,
    ///   or `CancellationError`.
    public func ripTrack(
        number: Int,
        sectors: Range<Int>,
        audioArea: Range<Int>,
        to url: URL,
        isCancelled: () -> Bool = { false },
        progress: (Progress) -> Void = { _ in }
    ) throws -> SecureRipTrackResult {
        let writer = try WAVFileWriter(url: url)
        var finished = false
        defer {
            if !finished { try? FileManager.default.removeItem(at: url) }
        }
        func checkCancel() throws {
            if isCancelled() { throw CancellationError() }
        }

        let count = sectors.count
        var timing = SecureRipTrackResult.Timing()

        // MARK: Pass 1: stream to the file, remember what each sector was.
        var start = clock()
        var pass1Hash = [UInt64](repeating: 0, count: count)
        // Doubtful = C2 flagged, or unreadable. Unreadable sectors went into
        // the file as silence and have no value to vote with.
        var pass1Doubtful = Set<Int>()
        var pass1Unreadable = Set<Int>()
        // Past either limit this is not a scratch to re-read but a disc that
        // is gone, damaged past reading, or a drive that stopped answering.
        // Checked as pass 1 goes, so an ejected disc stops the rip at once
        // rather than after a retry phase that could only ever write silence.
        let unreadableLimit = Int(Double(count) * configuration.maxUnreadableFraction)
        var unreadableRun = 0
        var offset = 0
        while offset < count {
            try checkCancel()
            let n = min(configuration.chunkSectors, count - offset)
            let chunk = try read(at: sectors.lowerBound + offset, count: n, checkCancel: checkCancel)
            for i in 0..<n {
                pass1Hash[offset + i] = chunk.hash(i)
                if chunk.unreadable[i] {
                    pass1Unreadable.insert(offset + i)
                    unreadableRun += 1
                } else {
                    unreadableRun = 0
                }
                if chunk.flagged(i) { pass1Doubtful.insert(offset + i) }
                if unreadableRun > configuration.maxUnreadableRun || pass1Unreadable.count > unreadableLimit {
                    throw CDSectorReadError.tooManyUnreadable(track: number, sectors: pass1Unreadable.count)
                }
            }
            try writer.append(chunk.audio)
            offset += n
            progress(Progress(trackNumber: number, phase: .pass1, fraction: Double(offset) / Double(max(count, 1)), rereads: 0))
        }
        timing.pass1 = clock() - start

        // MARK: Pass 2: read again, from the disc rather than the cache.
        start = clock()
        progress(Progress(trackNumber: number, phase: .pass2, fraction: 0, rereads: 0))
        if count < configuration.flushSectors {
            try flush(awayFrom: sectors, audioArea: audioArea, checkCancel: checkCancel)
        }
        var c2Sectors = pass1Doubtful.subtracting(pass1Unreadable)
        var tallies: [Int: SectorTally] = [:]
        offset = 0
        while offset < count {
            try checkCancel()
            let n = min(configuration.chunkSectors, count - offset)
            let chunk = try read(at: sectors.lowerBound + offset, count: n, checkCancel: checkCancel)
            for i in 0..<n {
                let index = offset + i
                let hash = chunk.hash(i)
                if chunk.c2Flagged(i) { c2Sectors.insert(index) }
                let differs = hash != pass1Hash[index] || chunk.unreadable[i] || pass1Unreadable.contains(index)
                guard differs || chunk.flagged(i) || pass1Doubtful.contains(index) else { continue }

                // Both passes vote. The file holds pass 1's value, unless pass 1
                // couldn't read the sector at all and pass 2 could, in which
                // case pass 2's goes in now rather than leaving silence there.
                var tally = SectorTally()
                if !pass1Unreadable.contains(index) {
                    tally.vote(hash: pass1Hash[index], clean: !pass1Doubtful.contains(index), bytes: nil)
                    tally.onDisk = pass1Hash[index]
                }
                if !chunk.unreadable[i] {
                    tally.vote(hash: hash, clean: !chunk.flagged(i), bytes: nil)
                    if tally.onDisk == nil {
                        try writer.replaceSector(index, with: chunk.sector(i))
                        tally.onDisk = hash
                    }
                }
                tallies[index] = tally
            }
            offset += n
            progress(Progress(trackNumber: number, phase: .pass2, fraction: Double(offset) / Double(max(count, 1)), rereads: 0))
        }
        timing.pass2 = clock() - start

        // MARK: Retry: re-read each doubtful run until it agrees with itself.
        start = clock()
        let retryList = tallies.keys.sorted()
        var rereads = 0
        var suspicious: [Int] = []
        var settled = 0
        var budgetRanOut = false
        if !retryList.isEmpty {
            progress(Progress(trackNumber: number, phase: .retry, fraction: 0, rereads: 0))
        }
        for batch in Self.batches(retryList, maxLength: configuration.maxBatchSectors) {
            var pending = batch
            var attempt = 0
            while !pending.isEmpty, attempt < configuration.maxAttempts, !budgetRanOut {
                try checkCancel()
                // Checked before the flush, the costly part of an attempt.
                if clock() - start >= configuration.retryBudget {
                    budgetRanOut = true
                    break
                }
                attempt += 1
                let first = pending.first!, last = pending.last!
                let range = (sectors.lowerBound + first) ..< (sectors.lowerBound + last + 1)
                try flush(awayFrom: range, audioArea: audioArea, checkCancel: checkCancel)
                let chunk = try read(at: range.lowerBound, count: range.count, checkCancel: checkCancel)
                var stillPending: [Int] = []
                for index in pending {
                    rereads += 1
                    let i = index - first
                    var tally = tallies[index]!
                    if !chunk.unreadable[i] {
                        let hash = chunk.hash(i)
                        tally.vote(hash: hash, clean: !chunk.flagged(i), bytes: chunk.sector(i))
                        if tally.cleanCount(hash) >= 2 {
                            // Accepted. Only touch the file when it holds
                            // something else.
                            if tally.onDisk != hash {
                                try writer.replaceSector(index, with: chunk.sector(i))
                            }
                            tallies[index] = nil
                            settled += 1
                            continue
                        }
                    }
                    tallies[index] = tally
                    stillPending.append(index)
                }
                pending = stillPending
                progress(Progress(trackNumber: number, phase: .retry,
                                  fraction: Double(settled) / Double(retryList.count), rereads: rereads))
            }
            // Never agreed: keep the value read most often.
            for index in pending {
                let tally = tallies[index]!
                if let best = tally.mostFrequent(), best.hash != tally.onDisk, let bytes = best.bytes {
                    try writer.replaceSector(index, with: bytes)
                }
                tallies[index] = nil
                suspicious.append(index)
                settled += 1
            }
            progress(Progress(trackNumber: number, phase: .retry,
                              fraction: Double(settled) / Double(retryList.count), rereads: rereads))
        }
        timing.retry = clock() - start

        try writer.finish()
        finished = true
        return SecureRipTrackResult(
            trackNumber: number,
            sectorCount: count,
            retriedSectors: retryList.count,
            rereads: rereads,
            c2Sectors: c2Sectors.count,
            suspiciousSectors: suspicious.sorted(),
            timing: timing,
            retryBudgetExhausted: budgetRanOut ? configuration.retryBudget : nil
        )
    }

    // MARK: - Reading

    /// One chunk's worth of sectors, with what the drive said about each.
    private struct Chunk {
        var audio: Data
        var c2: Data?
        var unreadable: [Bool]

        func sector(_ i: Int) -> Data {
            audio.subdata(in: i * CDSector.audioBytes ..< (i + 1) * CDSector.audioBytes)
        }

        func hash(_ i: Int) -> UInt64 {
            audio.withUnsafeBytes { SectorHash.hash($0, sector: i) }
        }

        func c2Flagged(_ i: Int) -> Bool {
            guard let c2, !unreadable[i] else { return false }
            return c2.withUnsafeBytes { raw in
                raw[i * CDSector.c2Bytes ..< (i + 1) * CDSector.c2Bytes].contains { $0 != 0 }
            }
        }

        /// Not to be trusted on its own: C2 errors, or no read at all.
        func flagged(_ i: Int) -> Bool { unreadable[i] || c2Flagged(i) }
    }

    /// Read with C2. A media error fails the whole read, so it's retried one
    /// sector at a time to find which ones the drive can't read; those come
    /// back as silence, marked unreadable. Any other error ends the rip.
    /// Cancellation is polled before each of those single reads: a drive can
    /// spend seconds retrying every bad sector of a scratch on its own.
    private func read(at lba: Int, count: Int, checkCancel: () throws -> Void) throws -> Chunk {
        do {
            let result = try reader.readSectors(at: lba, count: count, c2: true)
            try validate(result, count: count)
            return Chunk(audio: result.audio, c2: result.c2, unreadable: Array(repeating: false, count: count))
        } catch let error as CDSectorReadError where error.isMediaError && count > 1 {
            var audio = Data(capacity: count * CDSector.audioBytes)
            var c2 = Data(capacity: count * CDSector.c2Bytes)
            var unreadable: [Bool] = []
            for i in 0..<count {
                try checkCancel()
                let single = try read(at: lba + i, count: 1, checkCancel: checkCancel)
                audio.append(single.audio)
                c2.append(single.c2 ?? Data(count: CDSector.c2Bytes))
                unreadable.append(single.unreadable[0])
            }
            return Chunk(audio: audio, c2: c2, unreadable: unreadable)
        } catch let error as CDSectorReadError where error.isMediaError {
            return Chunk(audio: Data(count: CDSector.audioBytes), c2: Data(count: CDSector.c2Bytes), unreadable: [true])
        }
    }

    /// A short read would shift every sector after it, so it's an error, not
    /// something to pad.
    private func validate(_ result: CDSectorRead, count: Int) throws {
        guard result.audio.count == count * CDSector.audioBytes,
              result.c2.map({ $0.count == count * CDSector.c2Bytes }) ?? false
        else {
            throw CDSectorReadError.shortRead(expectedSectors: count)
        }
    }

    /// Read audio far from `range` and throw it away, so the drive's cache no
    /// longer holds `range` and the next read of it comes off the disc.
    private func flush(awayFrom range: Range<Int>, audioArea: Range<Int>, checkCancel: () throws -> Void) throws {
        guard let region = Self.flushRegion(awayFrom: range, audioArea: audioArea,
                                            length: configuration.flushSectors) else { return }
        var lba = region.lowerBound
        while lba < region.upperBound {
            try checkCancel()
            let n = min(configuration.chunkSectors, region.upperBound - lba)
            do {
                _ = try reader.readSectors(at: lba, count: n, c2: false)
            } catch let error as CDSectorReadError where error.isMediaError {
                // The flush only has to move the head and fill the cache; a bad
                // patch in it doesn't matter.
            }
            lba += n
        }
    }

    /// Where a cache-defeating read goes: `length` sectors at whichever end of
    /// the audio is farther from `range`, and never overlapping it, since
    /// reading the sectors about to be re-read would put them back in the
    /// cache.
    ///
    /// On a disc too short to fit `length` sectors on either side of `range`,
    /// it takes the longer of what there is (on a tie, the farther). That
    /// pushes out less than a whole cache, so the next read may still come
    /// partly from it; there is no audio left to read instead. Nil when
    /// `range` covers the whole audio area.
    static func flushRegion(awayFrom range: Range<Int>, audioArea: Range<Int>, length: Int) -> Range<Int>? {
        guard length > 0 else { return nil }
        var candidates: [Range<Int>] = []
        let headEnd = min(audioArea.lowerBound + length, range.lowerBound, audioArea.upperBound)
        if headEnd > audioArea.lowerBound { candidates.append(audioArea.lowerBound ..< headEnd) }
        let tailStart = max(audioArea.upperBound - length, range.upperBound, audioArea.lowerBound)
        if tailStart < audioArea.upperBound { candidates.append(tailStart ..< audioArea.upperBound) }
        func gap(_ region: Range<Int>) -> Int {
            if region.upperBound <= range.lowerBound { return range.lowerBound - region.upperBound }
            if region.lowerBound >= range.upperBound { return region.lowerBound - range.upperBound }
            return 0
        }
        let full = candidates.filter { $0.count == length }
        if !full.isEmpty {
            return full.max { gap($0) < gap($1) }
        }
        return candidates.max { ($0.count, gap($0)) < ($1.count, gap($1)) }
    }

    /// Consecutive runs of `indexes` (sorted), none longer than `maxLength`.
    static func batches(_ indexes: [Int], maxLength: Int) -> [[Int]] {
        var out: [[Int]] = []
        for index in indexes {
            if var last = out.last, let tail = last.last, tail + 1 == index, last.count < maxLength {
                last.append(index)
                out[out.count - 1] = last
            } else {
                out.append([index])
            }
        }
        return out
    }
}

/// Everything read for one doubtful sector.
struct SectorTally {
    struct Candidate {
        var hash: UInt64
        var count = 0
        var cleanCount = 0
        /// Kept only for re-reads; pass 1's value is already in the file and
        /// pass 2's is never needed (see `mostFrequent`).
        var bytes: Data?
        var order: Int
    }

    private(set) var candidates: [UInt64: Candidate] = [:]
    /// The value the output file holds for this sector right now.
    var onDisk: UInt64?

    mutating func vote(hash: UInt64, clean: Bool, bytes: Data?) {
        var candidate = candidates[hash] ?? Candidate(hash: hash, order: candidates.count)
        candidate.count += 1
        if clean { candidate.cleanCount += 1 }
        if candidate.bytes == nil { candidate.bytes = bytes }
        candidates[hash] = candidate
    }

    func cleanCount(_ hash: UInt64) -> Int { candidates[hash]?.cleanCount ?? 0 }

    /// The value read most often; ties go to one already in the file or whose
    /// bytes were kept, then to more clean reads, then to the earliest.
    ///
    /// That order means the winner can always be written. The only value with
    /// neither is one read once, in pass 2 (a re-read keeps its bytes), and the
    /// value in the file has been read at least once too, so it wins the tie.
    /// Keeping pass 2's bytes instead would cost memory per doubtful sector,
    /// and a drive that reports C2 on everything makes that the whole track.
    func mostFrequent() -> Candidate? {
        candidates.values.max { a, b in
            if a.count != b.count { return a.count < b.count }
            let aWritable = a.bytes != nil || a.hash == onDisk
            let bWritable = b.bytes != nil || b.hash == onDisk
            if aWritable != bWritable { return !aWritable }
            if a.cleanCount != b.cleanCount { return a.cleanCount < b.cleanCount }
            return a.order > b.order
        }
    }
}

/// A 64-bit hash of one sector's audio, to compare two reads of it without
/// keeping either. The xxHash64 round (multiply, rotate, multiply) over 64-bit
/// words, then its avalanche: the input is never adversarial, so speed
/// matters more than strength, and 294 words a sector go by far faster than
/// the drive can supply them.
///
/// The rotate is what makes it safe here. Plain FNV-1a over 64-bit words
/// (xor, then multiply) only ever carries a difference upward, so a flip of
/// bit 63 in one word rode through untouched until the same flip in a later
/// word cancelled it: two reads differing in two samples' sign bits hashed
/// alike, and pass 2 would have "verified" a wrong pass 1.
enum SectorHash {
    private static let prime1: UInt64 = 0x9E37_79B1_85EB_CA87
    private static let prime2: UInt64 = 0xC2B2_AE3D_27D4_EB4F
    private static let prime3: UInt64 = 0x1656_67B1_9E37_79F9
    private static let prime5: UInt64 = 0x27D4_EB2F_1656_67C5

    static func hash(_ buffer: UnsafeRawBufferPointer, sector: Int) -> UInt64 {
        var h = prime5 &+ UInt64(CDSector.audioBytes)
        let base = sector * CDSector.audioBytes
        var offset = base
        while offset < base + CDSector.audioBytes {
            h &+= buffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self) &* prime2
            h = (h << 31) | (h >> 33)
            h &*= prime1
            offset += 8
        }
        h ^= h >> 33
        h &*= prime2
        h ^= h >> 29
        h &*= prime3
        h ^= h >> 32
        return h
    }

    static func hash(_ data: Data) -> UInt64 {
        data.withUnsafeBytes { hash($0, sector: 0) }
    }
}
