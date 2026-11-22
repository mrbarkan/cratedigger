import Foundation

/// Room left in the player's central art table. PodBox holds at most 2,048
/// files across `/Artwork/People` and `/Artwork/Covers` with a 48 KB pool for
/// their names (`AA_CENTRAL_MAX`, `AA_CENTRAL_NAMES`); a file past either
/// limit is silently never shown. CrateDigger stops short of both, at 1,900
/// files and 44 KB, so the owner's own additions still have room. Every
/// existing file counts, whoever put it there.
public struct PodBoxArtworkBudget: Sendable {
    public static let files = 1_900, nameBytes = 44 * 1024, people = 8_192

    private var usedFiles: Int
    private var usedNameBytes: Int

    /// `existingNames`: the file names already in People and Covers, anyone's.
    public init(existingNames: [String]) {
        usedFiles = existingNames.count
        usedNameBytes = existingNames.reduce(0) { $0 + Self.cost(of: $1) }
    }

    public var remainingFiles: Int { max(0, Self.files - usedFiles) }
    public var remainingNameBytes: Int { max(0, Self.nameBytes - usedNameBytes) }

    /// Reserves room for one more file. false, changing nothing, when it
    /// would pass either limit.
    public mutating func take(fileName: String) -> Bool {
        let cost = Self.cost(of: fileName)
        guard remainingFiles >= 1, remainingNameBytes >= cost else { return false }
        usedFiles += 1
        usedNameBytes += cost
        return true
    }

    /// A name's share of the pool: its UTF-8 bytes and a terminator.
    private static func cost(of name: String) -> Int { name.utf8.count + 1 }
}
