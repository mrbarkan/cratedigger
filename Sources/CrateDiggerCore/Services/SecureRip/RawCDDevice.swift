import Foundation

/// `CDSectorReading` over the drive itself, through `DKIOCCDREAD` on the raw
/// device node behind a mounted audio CD.
///
/// cddafs (the filesystem that shows a CD as `.aiff` files) already does its
/// own reads, but it hides everything secure extraction needs: it can't be
/// asked for the C2 error pointers, and its cache answers a re-read from
/// memory. The ioctl gets both, and needs no root: the console user owns the
/// device node of a disc they inserted.
public final class RawCDDevice: CDSectorReading {
    public let devicePath: String
    private let fd: Int32

    /// `dk_cd_read_t` from `<IOKit/storage/IOCDMediaBSDClient.h>`, laid out
    /// field for field (32 bytes). Swift doesn't import the header's struct
    /// usefully, nor the `_IOWR` macro below.
    private struct DKCDRead {
        var offset: UInt64 = 0
        var sectorArea: UInt8 = 0
        var sectorType: UInt8 = 0
        var reserved: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
            = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var bufferLength: UInt32 = 0
        var buffer: UnsafeMutableRawPointer?
    }

    /// `_IOWR('d', 96, dk_cd_read_t)`.
    private static let DKIOCCDREAD: UInt = 0xC020_6460
    private static let sectorTypeCDDA: UInt8 = 0x01
    private static let areaUser: UInt8 = 0x10
    private static let areaErrorFlags: UInt8 = 0x02

    /// Open the raw node behind the CD mounted at `volumeURL`. statfs names the
    /// block device (`/dev/disk13`); the raw `rdisk` node skips the buffer
    /// cache, which would otherwise satisfy a re-read without touching the disc.
    public convenience init(volumeURL: URL) throws {
        var info = statfs()
        guard statfs(volumeURL.path, &info) == 0 else {
            throw CDSectorReadError.deviceUnavailable(path: volumeURL.path, errno: errno)
        }
        let device = withUnsafeBytes(of: info.f_mntfromname) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        guard let path = Self.rawDevicePath(forMountedFrom: device) else {
            throw CDSectorReadError.deviceUnavailable(path: device, errno: ENODEV)
        }
        try self.init(devicePath: path)
    }

    public init(devicePath: String) throws {
        let fd = open(devicePath, O_RDONLY)
        guard fd >= 0 else {
            throw CDSectorReadError.deviceUnavailable(path: devicePath, errno: errno)
        }
        self.devicePath = devicePath
        self.fd = fd
    }

    deinit { close(fd) }

    /// `/dev/disk13` → `/dev/rdisk13`. Nil for anything that isn't a disk node
    /// (a network or disk-image mount reaching here would be a bug upstream).
    public static func rawDevicePath(forMountedFrom device: String) -> String? {
        guard device.hasPrefix("/dev/disk") else { return nil }
        return "/dev/r" + device.dropFirst("/dev/".count)
    }

    public func readSectors(at lba: Int, count: Int, c2: Bool) throws -> CDSectorRead {
        precondition(lba >= 0 && count > 0, "Bad sector range \(lba)+\(count)")
        let stride = CDSector.audioBytes + (c2 ? CDSector.c2Bytes : 0)
        var buffer = Data(count: stride * count)
        let rc = buffer.withUnsafeMutableBytes { raw -> Int32 in
            var request = DKCDRead()
            // The offset is in bytes of whatever area was asked for, so it
            // scales with the C2 bytes too.
            request.offset = UInt64(lba) * UInt64(stride)
            request.sectorArea = Self.areaUser | (c2 ? Self.areaErrorFlags : 0)
            request.sectorType = Self.sectorTypeCDDA
            request.bufferLength = UInt32(raw.count)
            request.buffer = raw.baseAddress
            return ioctl(fd, Self.DKIOCCDREAD, &request)
        }
        guard rc == 0 else {
            throw CDSectorReadError.readFailed(lba: lba, count: count, errno: errno)
        }
        guard c2 else { return CDSectorRead(audio: buffer, c2: nil) }
        return Self.splitInterleaved(buffer, count: count)
    }

    /// The drive interleaves per sector: 2352 audio bytes, then that sector's
    /// 294 flag bytes. Split them so callers see two planes.
    static func splitInterleaved(_ buffer: Data, count: Int) -> CDSectorRead {
        let stride = CDSector.audioBytes + CDSector.c2Bytes
        precondition(buffer.count == stride * count, "\(buffer.count) bytes isn't \(count) sectors with C2")
        var audio = Data(capacity: CDSector.audioBytes * count)
        var flags = Data(capacity: CDSector.c2Bytes * count)
        buffer.withUnsafeBytes { raw in
            for sector in 0..<count {
                let base = sector * stride
                audio.append(contentsOf: raw[base ..< base + CDSector.audioBytes])
                flags.append(contentsOf: raw[base + CDSector.audioBytes ..< base + stride])
            }
        }
        return CDSectorRead(audio: audio, c2: flags)
    }
}
