import Foundation

/// File and folder names a FAT32 iPod can hold, and the path length the
/// player can open. Pure string rules: nothing here touches a disk.
public enum FATName {
    /// The longest path the player opens, in UTF-8 bytes, counted with its
    /// volume prefix (`/<HDD0>` on an iPod).
    public static let maximumPlayerPathBytes = 252
    /// FAT's limit for one long name, in UTF-16 units.
    public static let maximumComponentUnits = 255
    static let defaultPlayerPrefix = "/<HDD0>"

    /// Stems FAT and the tools around it refuse or treat as devices, in any case.
    static let reservedStems: Set<String> = {
        var stems: Set<String> = ["CON", "PRN", "AUX", "NUL"]
        for digit in 1...9 {
            stems.insert("COM\(digit)")
            stems.insert("LPT\(digit)")
        }
        return stems
    }()

    /// One path component safe to create on FAT, or nil when nothing usable
    /// is left. NFC first; `?` and `*` removed; `"` becomes `'`; `< > | / \ :`
    /// become `-`; control characters become `_`; trailing dots and spaces
    /// are trimmed and leading dots removed; a reserved stem gets a trailing
    /// `_`; the whole name (stem, dot, extension) is cut to 255 UTF-16 units
    /// on a grapheme boundary, keeping the extension.
    public static func component(_ raw: String, extension ext: String?) -> String? {
        var stem = ""
        for scalar in raw.precomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar {
            case "?", "*":
                continue
            case "\"":
                stem.unicodeScalars.append("'")
            case "<", ">", "|", "/", "\\", ":":
                stem.unicodeScalars.append("-")
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                stem.unicodeScalars.append("_")
            default:
                stem.unicodeScalars.append(scalar)
            }
        }
        stem = tidied(stem)
        if reservedStems.contains(stem.uppercased()) { stem += "_" }

        let suffix = (ext?.isEmpty == false) ? "." + ext! : ""
        let budget = maximumComponentUnits - suffix.utf16.count
        if stem.utf16.count > budget {
            var cut = ""
            var units = 0
            for character in stem {
                let width = String(character).utf16.count
                if units + width > budget { break }
                cut.append(character)
                units += width
            }
            // A cut can leave a dot or a space at the end again.
            stem = tidied(cut)
        }
        guard !stem.isEmpty else { return nil }
        return stem + suffix
    }

    /// Whether the player can open `relativePath` (relative to the volume
    /// root): its UTF-8 length with the prefix and one slash is at most 252.
    public static func fitsPlayerPath(_ relativePath: String, prefix: String?) -> Bool {
        let full = (prefix ?? defaultPlayerPrefix) + "/" + relativePath
        return full.utf8.count <= maximumPlayerPathBytes
    }

    /// FAT treats the two names as the same file: equal after NFC and case folding.
    public static func collides(_ a: String, _ b: String) -> Bool {
        folded(a) == folded(b)
    }

    // MARK: - Private

    private static func folded(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.uppercased().lowercased()
    }

    /// Trailing dots and spaces trimmed (FAT drops them, so the name would
    /// change on disk), then leading dots removed (a hidden file on the Mac).
    private static func tidied(_ stem: String) -> String {
        var result = stem
        while let last = result.last, last == "." || last == " " { result.removeLast() }
        while result.first == "." { result.removeFirst() }
        return result
    }
}
