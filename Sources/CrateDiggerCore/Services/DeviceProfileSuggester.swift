import Foundation

/// Guesses a sensible `ExternalDeviceProfile` for a freshly-detected volume so
/// "Add Device" can pre-fill the kind, mount point, music folder, and transfer
/// settings instead of making the user configure everything by hand.
///
/// The kind → transfer-settings mapping already lives in the `ExternalDeviceProfile`
/// factories (`.rockboxIPod()`, `.genericStorage()`); this only detects *which*
/// factory to use and where the music folder is.
public enum DeviceProfileSuggester {

    /// Detect device kind + music subfolder from a volume's top-level entries.
    /// Pure so the classification is unit-testable — the caller supplies the
    /// directory listing.
    public static func suggest(fromTopLevelEntries entries: [String]) -> (kind: ExternalDeviceKind, musicSubpath: String) {
        // Case-insensitive lookup that keeps the folder's real on-disk casing
        // (so "MUSIC" transfers into "MUSIC", not a second "Music").
        var byLowercase: [String: String] = [:]
        for entry in entries where byLowercase[entry.lowercased()] == nil {
            byLowercase[entry.lowercased()] = entry
        }
        let musicFolder = byLowercase["music"] ?? "Music"

        // Rockbox installs a `.rockbox` firmware/config folder at the volume root —
        // the reliable signal for a Rockbox iPod (which also still carries the
        // stock `iPod_Control` folder).
        if byLowercase[".rockbox"] != nil {
            return (.rockboxIPod, musicFolder)
        }
        return (.genericExternalStorage, musicFolder)
    }

    /// Build a fully pre-filled profile for a mounted volume: detects the kind and
    /// music folder from its contents and remembers the mount point via a bookmark.
    /// Reuses the per-kind settings presets. Unreadable volumes fall back to
    /// generic storage.
    public static func suggestedProfile(
        for device: MountedDevice,
        fileManager: FileManager = .default
    ) -> ExternalDeviceProfile {
        let entries = (try? fileManager.contentsOfDirectory(atPath: device.volumeURL.path)) ?? []
        let (kind, musicSubpath) = suggest(fromTopLevelEntries: entries)
        let bookmark = try? PreferencesStore.makeBookmark(for: device.volumeURL)
        let path = device.volumeURL.path

        var profile: ExternalDeviceProfile
        switch kind {
        case .rockboxIPod:
            profile = .rockboxIPod(name: device.name, rootBookmark: bookmark, rootDisplayPath: path)
        case .genericExternalStorage, .sdCard, .directFilePlayer:
            profile = .genericStorage(name: device.name, rootBookmark: bookmark, rootDisplayPath: path)
        }
        profile.musicDirectorySubpath = ExternalDeviceProfile.normalizedSubpath(musicSubpath)
        profile.volumeUUID = device.volumeUUID
        return profile
    }
}
