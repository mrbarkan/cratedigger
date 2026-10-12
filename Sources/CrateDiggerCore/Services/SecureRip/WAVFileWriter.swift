import Foundation

/// Streams CD audio into a 16-bit stereo 44.1 kHz WAV file.
///
/// Secure extraction writes a track front to back, then patches individual
/// sectors in place once a re-read settles them, so this writes through a
/// file handle rather than building the file in memory: a 70-minute track is
/// 740 MB.
public final class WAVFileWriter {
    public static let headerSize = 44
    public let url: URL
    private let handle: FileHandle
    private var dataBytes: UInt64 = 0
    private var isClosed = false

    public init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        self.url = url
        self.handle = try FileHandle(forUpdating: url)
        // Sizes are placeholders until `finish()`: the real length is only
        // known once the last sector is in.
        try handle.write(contentsOf: Self.header(dataBytes: 0))
    }

    deinit { try? handle.close() }

    /// Append PCM after everything written so far.
    public func append(_ pcm: Data) throws {
        try handle.seek(toOffset: UInt64(Self.headerSize) + dataBytes)
        try handle.write(contentsOf: pcm)
        dataBytes += UInt64(pcm.count)
    }

    /// Overwrite one sector already written.
    public func replaceSector(_ index: Int, with pcm: Data) throws {
        precondition(pcm.count == CDSector.audioBytes, "A sector is \(CDSector.audioBytes) bytes")
        let offset = UInt64(index) * UInt64(CDSector.audioBytes)
        precondition(offset + UInt64(pcm.count) <= dataBytes, "Sector \(index) hasn't been written yet")
        try handle.seek(toOffset: UInt64(Self.headerSize) + offset)
        try handle.write(contentsOf: pcm)
    }

    /// Patch the sizes into the header and close the file.
    public func finish() throws {
        guard !isClosed else { return }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(dataBytes: dataBytes))
        try handle.synchronize()
        try handle.close()
        isClosed = true
    }

    /// The canonical 44-byte RIFF/WAVE header for CD audio.
    public static func header(dataBytes: UInt64) -> Data {
        // RIFF sizes are 32-bit; a CD track can't come near 4 GB, but clamp
        // rather than wrap if something ever passes one.
        let data = UInt32(clamping: dataBytes)
        let channels: UInt16 = 2, bitsPerSample: UInt16 = 16, sampleRate: UInt32 = 44_100
        let blockAlign = channels * bitsPerSample / 8
        var out = Data(capacity: headerSize)
        func le<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        }
        out.append(contentsOf: Array("RIFF".utf8)); le(UInt32(clamping: 36 + UInt64(data)))
        out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8)); le(UInt32(16))
        le(UInt16(1))                       // PCM
        le(channels)
        le(sampleRate)
        le(sampleRate * UInt32(blockAlign)) // byte rate
        le(blockAlign)
        le(bitsPerSample)
        out.append(contentsOf: Array("data".utf8)); le(data)
        return out
    }
}
