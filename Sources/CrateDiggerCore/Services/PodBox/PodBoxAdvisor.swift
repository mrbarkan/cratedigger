import Foundation

/// One piece of advice about what the iPod will make of the music on it,
/// shown as a caption in Preferences ▸ Devices.
public struct PodBoxNote: Identifiable, Hashable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case macFiles, artistArtOff, musicNotScanned, playLogOff, unnameableArtists,
             pathTooLong, compilationWithoutAlbumArtist, embeddedArtOnly, newerLayout, notBooted
    }

    public let kind: Kind, text: String, items: [String], menuPath: String?
    public var id: String { kind.rawValue }

    public init(kind: Kind, text: String, items: [String] = [], menuPath: String? = nil) {
        self.kind = kind
        self.text = text
        self.items = items
        self.menuPath = menuPath
    }
}

/// Readiness notes, worked out from the device catalog and what the
/// firmware probe read. Read-only: it opens nothing on the device. A stock
/// or unknown Rockbox gets only the notes that hold for any Rockbox (Mac
/// files, paths too long); the rest are about PodBox's own settings.
public enum PodBoxAdvisor {
    public static func deviceNotes(catalog: [LoadedTrack], firmware: DeviceFirmware, musicSubpath: String,
                                   volumeRoot: URL) -> [PodBoxNote] {
        let podBox = firmware.flavour == .podBox
        let config = firmware.config
        var notes: [PodBoxNote] = []

        let macFiles = firmware.unreadableAppleDoubleCount
        if macFiles > 0 {
            notes.append(PodBoxNote(kind: .macFiles,
                                    text: "PodBox is reading \(count(macFiles, "Mac file", "Mac files")) as music."))
        }
        if podBox, !config.artistArt {
            notes.append(PodBoxNote(kind: .artistArtOff, text: "Artist pictures are switched off on this iPod.",
                                    menuPath: "Settings ▸ Library ▸ Art Cache"))
        }
        let music = "/" + DeviceArtTree.trimmedSlashes(musicSubpath)
        if podBox, !config.scanPaths.contains(where: { covers($0, music) }) {
            notes.append(PodBoxNote(kind: .musicNotScanned,
                                    text: "This iPod only scans \(config.scanPaths.joined(separator: ", ")). Music in \(music) will not appear."))
        }
        if podBox, config.playLogMode == .off {
            notes.append(PodBoxNote(kind: .playLogOff, text: "The play log is off on this iPod, so plays cannot be imported."))
        }
        if podBox {
            let unnameable = ArtistOnDevice.all(in: catalog, volumeRoot: volumeRoot)
                .map(\.name)
                .filter { PodBoxArtName.fileStem(for: $0) == nil }
                .sorted()
            if !unnameable.isEmpty {
                notes.append(PodBoxNote(kind: .unnameableArtists,
                                        text: "PodBox cannot match a picture to \(count(unnameable.count, "artist name", "artist names")).",
                                        items: unnameable))
            }
        }

        let paths = DeviceArtTree.DevicePaths(root: volumeRoot)
        let relativePaths = catalog.compactMap { paths.relative($0.track.fileURL) }
        let tooLong = Array(Set(relativePaths.filter { !FATName.fitsPlayerPath($0, prefix: firmware.playerPathPrefix) }))
            .sorted()
        if !tooLong.isEmpty {
            let text = tooLong.count == 1 ? "1 file has a path too long for the player."
                : "\(tooLong.count) files have paths too long for the player."
            notes.append(PodBoxNote(kind: .pathTooLong, text: text, items: tooLong))
        }

        if podBox {
            let compilations = compilationsWithoutAlbumArtist(catalog, paths)
            if !compilations.isEmpty {
                let text = compilations.count == 1
                    ? "1 compilation has no album artist and will be split by artist."
                    : "\(compilations.count) compilations have no album artist and will be split by artist."
                notes.append(PodBoxNote(kind: .compilationWithoutAlbumArtist, text: text, items: compilations))
            }
            if isEmbeddedOnly(config.value("art cache album source")) {
                notes.append(PodBoxNote(kind: .embeddedArtOnly, text: "This iPod is set to use embedded covers only.",
                                        menuPath: "Settings ▸ Library ▸ Art Cache ▸ Album Art Source"))
            }
            if let layout = firmware.layout, layout > DeviceFirmware.knownLayout, let notice = firmware.layoutNotice {
                notes.append(PodBoxNote(kind: .newerLayout, text: notice))
            }
            if firmware.layout == nil, let notice = firmware.layoutNotice {
                notes.append(PodBoxNote(kind: .notBooted, text: notice))
            }
        }
        return notes
    }

    // MARK: - Private

    private static func count(_ number: Int, _ one: String, _ many: String) -> String {
        "\(number) \(number == 1 ? one : many)"
    }

    /// Whether the scan path takes in the music folder: `/`, the folder
    /// itself or one above it, compared without case (FAT ignores it).
    private static func covers(_ scanPath: String, _ music: String) -> Bool {
        let scan = "/" + DeviceArtTree.trimmedSlashes(scanPath).lowercased()
        let folder = music.lowercased()
        return scan == "/" || folder == scan || folder.hasPrefix(scan + "/")
    }

    /// Album folders whose tracks carry more than one artist and none an
    /// album artist: the player files each artist's tracks as its own album.
    private static func compilationsWithoutAlbumArtist(_ catalog: [LoadedTrack],
                                                       _ paths: DeviceArtTree.DevicePaths) -> [String] {
        var artists: [String: Set<String>] = [:]
        var tagged = Set<String>()
        for loaded in catalog {
            guard let relative = paths.relative(loaded.track.fileURL),
                  let folder = DeviceArtTree.parent(of: relative) else { continue }
            if let albumArtist = loaded.metadata.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines),
               !albumArtist.isEmpty {
                tagged.insert(folder)
            }
            let artist = (loaded.metadata.artist ?? loaded.track.artist)
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !artist.isEmpty { artists[folder, default: []].insert(artist) }
        }
        return artists.filter { $0.value.count > 1 && !tagged.contains($0.key) }.keys.sorted()
    }

    /// The setting's saved values are `files`, `files then embedded`,
    /// `embedded then files` and `embedded`; only the last uses no image files.
    /// Its menu labels ("Image Files, Then Embedded") are read the same way.
    private static func isEmbeddedOnly(_ value: String?) -> Bool {
        guard let value = value?.lowercased() else { return false }
        return value.contains("embedded") && !value.contains("image") && !value.contains("file")
    }
}
