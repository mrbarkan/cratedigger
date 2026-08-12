import Foundation

/// Writes a `cover.jpg` sidecar into album folders on a device.
///
/// Rockbox looks for a cover file in the track's own folder before it looks
/// inside the file, and its embedded-JPEG path renders a large cover in
/// greyscale once it has to scale the image down to the theme's art size. A
/// small baseline JPEG sitting next to the tracks is what those players
/// actually want, so Rockbox profiles ship the art as a sidecar and leave it
/// out of the audio files entirely.
public struct FolderCoverArtWriter {
    /// The name Rockbox (and most other players that read folder art) checks first.
    public static let filename = "cover.jpg"
    /// Comfortably above any Rockbox theme's art size while staying small
    /// enough that the decoder never has to scale it far.
    public static let defaultMaxDimension = 400

    private let preparer: ArtworkPreparing
    private let fileManager: FileManager

    public init(preparer: ArtworkPreparing = ArtworkService(), fileManager: FileManager = .default) {
        self.preparer = preparer
        self.fileManager = fileManager
    }

    /// Writes one `cover.jpg` per folder, replacing any file already there —
    /// the transfer that wrote the tracks owns the cover beside them. Folders
    /// that don't exist (nothing landed there) are skipped. Returns the number
    /// of covers written; a cover that can't be encoded is skipped, never fatal
    /// — the music is already on the device.
    @discardableResult
    public func write(
        _ coversByFolder: [URL: ArtworkAsset],
        maxDimension: Int = defaultMaxDimension
    ) -> Int {
        var written = 0
        for (folder, artwork) in coversByFolder {
            guard !artwork.data.isEmpty,
                  fileManager.fileExists(atPath: folder.path),
                  let prepared = try? preparer.prepareCompatibleArtwork(
                    asset: artwork, profile: .generic, maxDimension: maxDimension)
            else { continue }
            let destination = folder.appendingPathComponent(Self.filename)
            // .atomic writes a temp file next to the target and renames — on a
            // FAT device that's still a single visible cover.jpg.
            if (try? prepared.data.write(to: destination, options: .atomic)) != nil {
                written += 1
            }
        }
        return written
    }

    /// One audio file per folder under `root` — the first in name order, so a
    /// repeat run reads the same track's cover. Deep walk; hidden files are
    /// skipped, which on a FAT device also drops the `._` AppleDouble twins
    /// macOS leaves beside every file.
    ///
    /// This is how FIX ART repairs a device that was filled before folder art
    /// existed: the covers come back out of the files already on it, so nothing
    /// has to match them to the library.
    public static func representativeAudioFiles(
        under root: URL,
        extensions: Set<String> = LibraryScanService.defaultSupportedExtensions,
        fileManager: FileManager = .default
    ) -> [URL: URL] {
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [:] }

        var firstByFolder: [URL: URL] = [:]
        while let url = enumerator.nextObject() as? URL {
            guard extensions.contains(url.pathExtension.lowercased()) else { continue }
            let folder = url.deletingLastPathComponent()
            if let current = firstByFolder[folder],
               current.lastPathComponent <= url.lastPathComponent { continue }
            firstByFolder[folder] = url
        }
        return firstByFolder
    }
}
