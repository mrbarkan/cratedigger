import Foundation

/// What a macOS AppleDouble (`._`) file holds, read from its bytes: its
/// entries, whether its Finder info and resource fork carry anything, and the
/// names of the extended attributes in its `ATTR` block.
///
/// On FAT and exFAT macOS keeps a file's or folder's extended attributes in a
/// `._<name>` sibling laid out as the kernel writes it (xnu `vfs_xattr.c`):
///
/// - the AppleDouble header: magic `00 05 16 07`, version `00 02 00 00`, a
///   16-byte filler, a big-endian u16 entry count, then 12-byte entries
///   (type, offset, length);
/// - entry 9, Finder info, at offset 50: 32 bytes of Finder info, 2 pad
///   bytes, then (at offset 84) the `ATTR` header: magic, debug tag, total
///   size, data start, data length, 12 reserved bytes, flags, a u16 count,
///   and that many attribute entries (offset, length, flags, name length
///   with its NUL, the name), each padded to 4 bytes;
/// - entry 2, the resource fork, which macOS fills with a 286-byte empty
///   placeholder ("This resource fork intentionally left blank").
///
/// Pure: no file system access. `init` returns nil for anything that is not
/// AppleDouble or whose entries or attributes do not fit inside it.
struct AppleDoubleFile: Equatable {
    /// The attribute macOS attaches to everything an assessed (notarized,
    /// downloaded) app creates. It cannot be removed, so on FAT every file and
    /// folder such an app writes gets a `._` twin holding only it.
    static let provenanceAttribute = "com.apple.provenance"

    static let resourceForkType: UInt32 = 2
    static let finderInfoType: UInt32 = 9
    static let finderInfoSize = 32
    /// Where macOS puts the Finder info entry, and with it the `ATTR` header.
    static let finderInfoOffset = 50
    /// Finder info, then 2 pad bytes.
    static let attributeHeaderOffset = finderInfoOffset + finderInfoSize + 2
    static let attributeHeaderSize = 36
    /// `ATTR`.
    static let attributeMagic: UInt32 = 0x4154_5452
    private static let headerSize = 26
    private static let entrySize = 12
    private static let attributeEntryFixedSize = 11

    struct Entry: Equatable {
        let type: UInt32
        let offset: Int
        let length: Int
    }

    let entries: [Entry]
    /// No Finder info entry, or its 32 bytes all zero.
    let finderInfoIsEmpty: Bool
    /// No resource fork entry, an empty one, or exactly the placeholder macOS writes.
    let resourceForkIsEmpty: Bool
    /// The attribute names in the `ATTR` block, in file order; nil when the
    /// file has no `ATTR` block (so it is not a twin macOS made for attributes).
    let attributeNames: [String]?

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= Self.headerSize, DeviceFileIO.isAppleDoubleHeader(data) else { return nil }
        let count = Int(Self.u16(bytes, 24))
        guard Self.headerSize + count * Self.entrySize <= bytes.count else { return nil }

        var entries: [Entry] = []
        for index in 0..<count {
            let at = Self.headerSize + index * Self.entrySize
            let entry = Entry(type: Self.u32(bytes, at), offset: Int(Self.u32(bytes, at + 4)),
                              length: Int(Self.u32(bytes, at + 8)))
            guard entry.offset <= bytes.count, entry.length <= bytes.count - entry.offset else { return nil }
            entries.append(entry)
        }
        self.entries = entries

        let finderInfo = entries.filter { $0.type == Self.finderInfoType }
        let resourceFork = entries.filter { $0.type == Self.resourceForkType }
        guard finderInfo.count <= 1, resourceFork.count <= 1 else { return nil }

        if let info = finderInfo.first {
            guard info.length >= Self.finderInfoSize else { return nil }
            finderInfoIsEmpty = bytes[info.offset..<(info.offset + Self.finderInfoSize)].allSatisfy { $0 == 0 }
            switch Self.attributeBlock(bytes, finderInfo: info) {
            case .absent: attributeNames = nil
            case .names(let names): attributeNames = names
            case .malformed: return nil
            }
        } else {
            finderInfoIsEmpty = true
            attributeNames = nil
        }

        if let fork = resourceFork.first {
            let forkBytes = Data(bytes[fork.offset..<(fork.offset + fork.length)])
            resourceForkIsEmpty = fork.length == 0 || forkBytes == Self.emptyResourceFork
        } else {
            resourceForkIsEmpty = true
        }
    }

    /// True only for a twin that holds nothing but `com.apple.provenance`:
    /// an `ATTR` block listing no other attribute, no entry but Finder info
    /// and the resource fork, Finder info all zero, and no resource fork
    /// beyond the empty placeholder.
    var holdsOnlyProvenance: Bool {
        guard let attributeNames, finderInfoIsEmpty, resourceForkIsEmpty,
              entries.allSatisfy({ $0.type == Self.finderInfoType || $0.type == Self.resourceForkType })
        else { return false }
        return attributeNames.allSatisfy { $0 == Self.provenanceAttribute }
    }

    /// The 286-byte resource fork macOS writes into every attribute twin
    /// (xnu `init_empty_resource_fork`): a resource header and map with no
    /// resources, tagged "This resource fork intentionally left blank".
    static let emptyResourceFork: Data = {
        var fork = [UInt8](repeating: 0, count: 286)
        func put32(_ value: UInt32, _ at: Int) {
            for shift in 0..<4 { fork[at + shift] = UInt8(truncatingIfNeeded: value >> (24 - 8 * shift)) }
        }
        func put16(_ value: UInt16, _ at: Int) {
            fork[at] = UInt8(value >> 8)
            fork[at + 1] = UInt8(value & 0xFF)
        }
        put32(256, 0) // data offset
        put32(256, 4) // map offset
        put32(30, 12) // map length
        let tag = Array("This resource fork intentionally left blank   ".utf8)
        fork.replaceSubrange(16..<(16 + tag.count), with: tag)
        put32(256, 256) // the map's copy of the header
        put32(256, 260)
        put32(30, 268)
        put16(28, 280) // type list offset
        put16(30, 282) // name list offset
        put16(0xFFFF, 284) // no types
        return Data(fork)
    }()

    // MARK: - Private

    private enum AttributeBlock {
        case absent
        case names([String])
        /// An `ATTR` block is there but its entries do not fit inside it.
        case malformed
    }

    /// The `ATTR` block inside the Finder info entry, where macOS puts it.
    private static func attributeBlock(_ bytes: [UInt8], finderInfo: Entry) -> AttributeBlock {
        let entryEnd = finderInfo.offset + finderInfo.length
        let header = attributeHeaderOffset
        guard finderInfo.offset == finderInfoOffset, header + attributeHeaderSize <= entryEnd,
              u32(bytes, header) == attributeMagic
        else { return .absent }

        let totalSize = Int(u32(bytes, header + 8))
        let count = Int(u16(bytes, header + 34))
        guard totalSize <= entryEnd, totalSize >= header + attributeHeaderSize else { return .malformed }

        var names: [String] = []
        var at = header + attributeHeaderSize
        for _ in 0..<count {
            guard at + attributeEntryFixedSize <= totalSize else { return .malformed }
            let offset = Int(u32(bytes, at))
            let length = Int(u32(bytes, at + 4))
            let nameLength = Int(bytes[at + 10])
            let nameStart = at + attributeEntryFixedSize
            guard nameLength >= 1, nameStart + nameLength <= totalSize, bytes[nameStart + nameLength - 1] == 0,
                  offset <= totalSize, length <= totalSize - offset,
                  let name = String(bytes: bytes[nameStart..<(nameStart + nameLength - 1)], encoding: .utf8)
            else { return .malformed }
            names.append(name)
            at += (attributeEntryFixedSize + nameLength + 3) & ~3
        }
        return .names(names)
    }

    private static func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        bytes[at..<(at + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func u16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1])
    }
}
