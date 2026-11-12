import Foundation

/// How PodBox keys a person's name when it looks for an artist picture,
/// ported from the description of the player's `art_name.c` in the PodBox
/// brief (Appendix A), and checked against vectors produced by that C
/// (`scripts/podbox-artname-vectors.sh`). A picture CrateDigger writes is
/// found by the player only when its file or folder name has the same key
/// as the tag, so this must match the player exactly. It is not
/// `DeviceAlbumIdentity.fold` and must never be swapped for it: that fold
/// answers a different question (are two albums the same) with different rules.
///
/// The rules in short: only letters and digits count; ASCII is lowercased;
/// `&` reads as `and`; Latin-1 and Latin Extended-A letters fold to plain
/// ones by a fixed table; combining marks, general punctuation, CJK
/// punctuation and variation selectors are dropped; fullwidth ASCII folds to
/// ASCII; every other script is kept exactly, never lowercased. A leading
/// `The ` and a trailing `, the` are ignored, and a name with one comma also
/// matches reversed. The kept code points are FNV-1a hashed.
public enum PodBoxArtName {
    static let seed: UInt32 = 0x811C_9DC5 ^ 0x5A5A_5A5A
    static let prime: UInt32 = 16_777_619

    /// U+00C0 to U+017F, 32 per row: `-` drops the letter, a lowercase
    /// letter is kept, an uppercase one stands for the pair in `pairs`.
    static let latinFold: [UInt8] = Array((
        "aaaaaaAceeeeiiiidnooooo-ouuuuyTS" +
        "aaaaaaAceeeeiiiidnooooo-ouuuuyTy" +
        "aaaaaaccccccccddddeeeeeeeeeegggg" +
        "gggghhhhiiiiiiiiiiIIjjkkklllllll" +
        "lllnnnnnnnnnooooooOOrrrrrrssssss" +
        "ssttttttuuuuuuuuuuuuwwyyyzzzzzzs"
    ).utf8)
    static let pairs: [UInt8: (UInt8, UInt8)] = [
        UInt8(ascii: "A"): (UInt8(ascii: "a"), UInt8(ascii: "e")),
        UInt8(ascii: "O"): (UInt8(ascii: "o"), UInt8(ascii: "e")),
        UInt8(ascii: "S"): (UInt8(ascii: "s"), UInt8(ascii: "s")),
        UInt8(ascii: "T"): (UInt8(ascii: "t"), UInt8(ascii: "h")),
        UInt8(ascii: "I"): (UInt8(ascii: "i"), UInt8(ascii: "j")),
    ]

    // MARK: - Public

    /// The person's key, as the player computes it for a tag, a file stem
    /// or a folder name. 0 when nothing in the name counts.
    public static func key(_ name: String) -> UInt32 {
        var hasher = Hasher()
        foldKey(name, into: &hasher)
        return hasher.finish()
    }

    /// The key of the name read with the part after its one comma first
    /// ("Herbert, Frank" as "Frank Herbert"). 0 unless there is exactly one comma.
    public static func altKey(_ name: String) -> UInt32 {
        var hasher = Hasher()
        guard foldAltKey(name, into: &hasher) else { return 0 }
        return hasher.finish()
    }

    /// Whether the player would take one name's picture for the other: any
    /// non-zero key of one equals any non-zero key of the other.
    public static func matches(_ a: String, _ b: String) -> Bool {
        let left = [key(a), altKey(a)].filter { $0 != 0 }
        let right = Set([key(b), altKey(b)].filter { $0 != 0 })
        return left.contains { right.contains($0) }
    }

    /// The code points `key` hashes, as text: `The Beatles` gives `beatles`.
    /// Stable under itself, and its key is the name's key.
    public static func folded(_ name: String) -> String {
        var hasher = Hasher(collectsScalars: true)
        foldKey(name, into: &hasher)
        var result = String.UnicodeScalarView()
        for value in hasher.scalars {
            if let scalar = Unicode.Scalar(value) { result.append(scalar) }
        }
        return String(result)
    }

    /// A file stem for `<stem>.jpg` that the player keys exactly as it keys
    /// `name`: the name's FAT-safe form (`AC/DC` gives `AC-DC`) when that
    /// keeps the key, else the folded name. Room is left for a `.jpg`
    /// extension. nil when the key is 0, or when neither form fits one FAT
    /// name with the key intact (the caller reports the artist as unnameable).
    public static func fileStem(for name: String) -> String? {
        let target = key(name)
        guard target != 0 else { return nil }
        for candidate in [name, folded(name)] {
            if let stem = fatStem(candidate), key(stem) == target { return stem }
        }
        return nil
    }

    // MARK: - Internal

    /// The finish step: 0 when nothing was kept, else the hash with 0 moved to 1.
    static func finish(hash: UInt32, kept: Bool) -> UInt32 {
        guard kept else { return 0 }
        return hash == 0 ? 1 : hash
    }

    struct Hasher {
        var hash = PodBoxArtName.seed
        var kept = false
        let collectsScalars: Bool
        var scalars: [UInt32] = []

        init(collectsScalars: Bool = false) { self.collectsScalars = collectsScalars }

        mutating func add(_ value: UInt32) {
            hash = (hash ^ value) &* PodBoxArtName.prime
            kept = true
            if collectsScalars { scalars.append(value) }
        }

        func finish() -> UInt32 { PodBoxArtName.finish(hash: hash, kept: kept) }
    }

    // MARK: - Private

    private static let theBytes = Array("the ".utf8)
    private static let commaTheBytes = Array(", the".utf8)
    private static let jpgSuffix = ".jpg"

    private static func foldKey(_ name: String, into hasher: inout Hasher) {
        let bytes = Array(name.utf8)
        var end = bytes.count
        if end > 5, hasASCIIPrefix(bytes[(end - 5)...], commaTheBytes) { end -= 5 }
        addPart(bytes[..<end], first: true, into: &hasher)
    }

    /// false when the name does not have exactly one comma.
    private static func foldAltKey(_ name: String, into hasher: inout Hasher) -> Bool {
        let bytes = Array(name.utf8)
        let commas = bytes.indices.filter { bytes[$0] == UInt8(ascii: ",") }
        guard commas.count == 1, let comma = commas.first else { return false }
        var after = comma + 1
        if after < bytes.count, bytes[after] == UInt8(ascii: " ") { after += 1 }
        addPart(bytes[after...], first: true, into: &hasher)
        addPart(bytes[..<comma], first: false, into: &hasher)
        return true
    }

    /// The `the ` test is on bytes, before decoding, and needs more than
    /// four bytes, so a lone `The ` is hashed as it is. The C stops at a NUL.
    private static func addPart(_ part: ArraySlice<UInt8>, first: Bool, into hasher: inout Hasher) {
        var start = part.startIndex
        if first, part.count > 4, hasASCIIPrefix(part, theBytes) { start += 4 }
        var body = part[start...]
        if let nul = body.firstIndex(of: 0) { body = body[..<nul] }
        for scalar in String(decoding: body, as: UTF8.self).unicodeScalars {
            addChar(scalar.value, into: &hasher)
        }
    }

    private static func addChar(_ raw: UInt32, into hasher: inout Hasher) {
        var c = raw
        if (0xFF01...0xFF5E).contains(c) { c -= 0xFEE0 } // fullwidth ASCII
        if c < 0x80 {
            switch UInt8(c) {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): hasher.add(c + 0x20)
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"): hasher.add(c)
            case UInt8(ascii: "&"):
                for letter in "and".utf8 { hasher.add(UInt32(letter)) }
            default: break
            }
            return
        }
        if c < 0xC0 { return }                          // Latin-1 symbols
        if (0x0300...0x036F).contains(c) { return }     // combining marks
        if (0x2000...0x2BFF).contains(c) { return }     // punctuation and symbols
        if (0x3000...0x303F).contains(c) { return }     // CJK punctuation
        if (0xFE00...0xFE0F).contains(c) { return }     // variation selectors
        if c < 0x180 {
            let folded = latinFold[Int(c - 0xC0)]
            if folded == UInt8(ascii: "-") { return }
            if let pair = pairs[folded] {
                hasher.add(UInt32(pair.0))
                hasher.add(UInt32(pair.1))
            } else {
                hasher.add(UInt32(folded))
            }
            return
        }
        hasher.add(c)                                   // other scripts, as they are
    }

    private static func hasASCIIPrefix(_ bytes: ArraySlice<UInt8>, _ prefix: [UInt8]) -> Bool {
        guard bytes.count >= prefix.count else { return false }
        return zip(bytes, prefix).allSatisfy { lowercasedASCII($0) == $1 }
    }

    private static func lowercasedASCII(_ byte: UInt8) -> UInt8 {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte + 0x20 : byte
    }

    /// The FAT-safe stem of `name` with room for `.jpg`, or nil.
    private static func fatStem(_ name: String) -> String? {
        guard let component = FATName.component(name, extension: "jpg") else { return nil }
        return String(component.unicodeScalars.dropLast(jpgSuffix.unicodeScalars.count))
    }
}
