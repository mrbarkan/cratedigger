import Foundation

/// The folder layouts offered for a Rockbox profile. A preset only seeds the
/// profile's own `FolderTemplateConfig`; choosing one never changes an
/// existing profile by itself.
public enum RockboxLayoutPreset: String, Codable, CaseIterable, Sendable {
    /// `Album Artist / YYYY Album`: PodBox sorts albums by the year at the
    /// front of the folder name and reads the artist from the folder above.
    case podBoxRecommended
    /// `Album Artist / Album`, what `ExternalDeviceProfile.rockboxIPod()` builds.
    case artistAlbum
    case custom

    public var title: String {
        switch self {
        case .podBoxRecommended: return "PodBox recommended"
        case .artistAlbum: return "Artist / Album"
        case .custom: return "Custom"
        }
    }

    public var caption: String {
        switch self {
        case .podBoxRecommended: return "Artist / 2010 Album"
        case .artistAlbum: return "Artist / Album"
        case .custom: return "Set in the transfer panel"
        }
    }

    /// nil for `.custom`.
    public var template: FolderTemplateConfig? {
        switch self {
        case .podBoxRecommended:
            return FolderTemplateConfig(preset: .custom, tokenOrder: [.albumArtist, .year, .album, .disabled, .disabled],
                                        separators: [.slash, .space], omitsMissingYear: true)
        case .artistAlbum:
            return FolderTemplateConfig(preset: .custom, tokenOrder: [.albumArtist, .album, .disabled, .disabled, .disabled])
        case .custom:
            return nil
        }
    }

    /// The preset whose template lays folders out the same way: the same
    /// tokens grouped into the same folders, whatever separators sit beside
    /// disabled tokens, and the same missing-year rule. Anything else is `.custom`.
    public static func matching(_ config: FolderTemplateConfig) -> RockboxLayoutPreset {
        let levels = folderLevels(config)
        return [.podBoxRecommended, .artistAlbum].first { preset in
            guard let template = preset.template else { return false }
            return folderLevels(template) == levels && template.omitsMissingYear == config.omitsMissingYear
        } ?? .custom
    }

    /// The tokens of each folder level, as `OutputPathPlanner.buildOutputSubpath` groups them.
    static func folderLevels(_ config: FolderTemplateConfig) -> [[FolderToken]] {
        let order = config.preset == .custom ? config.tokenOrder : config.preset.defaultTokenOrder
        let separators = config.preset == .custom ? config.separators : []
        var levels: [[FolderToken]] = [[]]
        for (index, token) in order.enumerated() {
            if !token.isDisabled { levels[levels.count - 1].append(token) }
            if index < order.count - 1, (index < separators.count ? separators[index] : .slash) == .slash {
                levels.append([])
            }
        }
        return levels.filter { !$0.isEmpty }
    }
}

/// The year PodBox reads from the front of a folder name (`year from folder`).
public enum PodBoxFolderYear {
    /// The first four characters are ASCII digits making 1900 to 2099, and
    /// the fifth, if there is one, is not an ASCII digit.
    public static func parse(_ folderName: String) -> Int? {
        let characters = Array(folderName)
        guard characters.count >= 4, characters.prefix(4).allSatisfy(isASCIIDigit) else { return nil }
        if characters.count > 4, isASCIIDigit(characters[4]) { return nil }
        guard let year = Int(String(characters.prefix(4))), (1900...2099).contains(year) else { return nil }
        return year
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }
}

/// A folder name the player reads as one disc of an album.
public enum PodBoxDiscFolder {
    /// `cd`, `disc` or `disk` in any case, then any of space `-` `_` `.`,
    /// then one or more ASCII digits and nothing else.
    public static func isDiscFolder(_ name: String) -> Bool {
        PodBoxArtLookup.isDiscFolder(name)
    }
}

public enum PodBoxLayoutNotes {
    /// Folder names the player would read with a year the tag does not
    /// carry (`1999` by Prince, tagged 1982), from each folder's last path
    /// component. A folder whose tag has no year counts as different.
    /// Folders come back as given, in order.
    public static func misreadYears(plannedAlbumFolders: [(folder: String, tagYear: Int?)])
        -> [(folder: String, parsed: Int, tag: Int?)] {
        plannedAlbumFolders.compactMap { entry in
            let name = entry.folder.split(separator: "/").last.map(String.init) ?? entry.folder
            guard let parsed = PodBoxFolderYear.parse(name), parsed != entry.tagYear else { return nil }
            return (entry.folder, parsed, entry.tagYear)
        }
    }
}
