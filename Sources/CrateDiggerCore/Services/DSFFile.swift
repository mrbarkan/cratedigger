import Foundation

public enum DSFReadError: Error {
    case notDSF
    case malformedHeader
}

public struct DSFInfo: Equatable, Sendable {
    public let channelCount: Int
    /// The true 1-bit DSD rate (2 822 400 for DSD64) — from the header, NOT
    /// ffprobe's bytes/sec convention.
    public let dsdSampleRateHz: Int
    /// DSF stores each byte LSB-first (bitsPerSample == 1); DFF-style MSB-first
    /// is bitsPerSample == 8.
    public let lsbFirst: Bool
    /// Per-channel sample count in bits.
    public let sampleCountPerChannel: Int64
    /// Per-channel block size — data is [ch0 block][ch1 block][ch0 block]….
    public let blockSizeBytes: Int
    public let dataOffset: Int64
    public let dataByteCountPerChannel: Int64

    public var durationSeconds: Double {
        Double(sampleCountPerChannel) / Double(dsdSampleRateHz)
    }
    /// DoP carries 16 DSD bits per PCM frame: DSD64 → 176.4k, DSD128 → 352.8k.
    public var dopFrameRateHz: Double { Double(dsdSampleRateHz) / 16.0 }
}

/// Reads just the fixed 92-byte DSF prelude ("DSD " + "fmt " + "data" chunk
/// headers, all little-endian) — enough to route, pack, and seek without
/// touching the audio payload.
public enum DSFFile {
    public static func readInfo(url: URL) throws -> DSFInfo {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 28 + 52 + 12), header.count == 92 else {
            throw DSFReadError.notDSF
        }
        func le32(_ offset: Int) -> UInt32 {
            header.subdata(in: offset..<offset + 4)
                .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        }
        func le64(_ offset: Int) -> UInt64 {
            header.subdata(in: offset..<offset + 8)
                .withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
        }
        guard header.prefix(4) == Data("DSD ".utf8) else { throw DSFReadError.notDSF }
        guard header.subdata(in: 28..<32) == Data("fmt ".utf8),
              header.subdata(in: 80..<84) == Data("data".utf8) else {
            throw DSFReadError.malformedHeader
        }
        let channelCount = Int(le32(28 + 24))
        let samplingFrequency = Int(le32(28 + 28))
        let bitsPerSample = le32(28 + 32)
        let sampleCount = Int64(bitPattern: le64(28 + 36))
        let blockSize = Int(le32(28 + 44))
        guard channelCount > 0, samplingFrequency > 0, blockSize > 0, sampleCount > 0,
              bitsPerSample == 1 || bitsPerSample == 8 else {
            throw DSFReadError.malformedHeader
        }
        return DSFInfo(channelCount: channelCount,
                       dsdSampleRateHz: samplingFrequency,
                       lsbFirst: bitsPerSample == 1,
                       sampleCountPerChannel: sampleCount,
                       blockSizeBytes: blockSize,
                       dataOffset: 92,
                       dataByteCountPerChannel: (sampleCount + 7) / 8)
    }
}
