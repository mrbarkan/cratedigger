import Foundation

/// SACD ISOs can't be mounted by macOS; the reliable tell is the Master TOC
/// magic "SACDMTOC" at sector 510 (verified against a real disc image).
public enum SACDISOInspector {
    private static let magic = Data("SACDMTOC".utf8)
    private static let masterTOCOffset: UInt64 = 510 * 2048

    public static func isSACDISO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: masterTOCOffset)) != nil,
              let bytes = try? handle.read(upToCount: magic.count) else { return false }
        return bytes == magic
    }
}
