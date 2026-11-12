import CryptoKit
import Foundation

/// One person the player would show a picture for, from the device catalog:
/// every spelling the player takes for the same person (by its key or alt
/// key) is one entry.
public struct ArtistOnDevice: Hashable, Sendable {
    /// The most common spelling (ties: the first in sort order).
    public let name: String
    /// `PodBoxArtName.folded(name)`; empty for a name the player cannot key.
    public let foldedKey: String
    /// Device-relative folders holding the person's tracks, sorted.
    public let albumFolders: [String]
    public let albumTitles: [String]
    public let trackCount: Int

    public init(name: String, foldedKey: String? = nil, albumFolders: [String], albumTitles: [String] = [],
                trackCount: Int) {
        self.name = name
        self.foldedKey = foldedKey ?? PodBoxArtName.folded(name)
        self.albumFolders = albumFolders
        self.albumTitles = albumTitles
        self.trackCount = trackCount
    }

    /// One per person, most tracks first (then by name). The person is the
    /// album artist, else the artist (`DeviceArtTree.person`); Various
    /// Artists and the like are left out. Tracks not on `volumeRoot` are skipped.
    public static func all(in catalog: [LoadedTrack], volumeRoot: URL) -> [ArtistOnDevice] {
        let paths = DeviceArtTree.DevicePaths(root: volumeRoot)
        var groups: [Group] = []
        var groupByKey: [UInt32: Int] = [:]
        var groupByUnkeyed: [String: Int] = [:]

        for loaded in catalog {
            guard let person = DeviceArtTree.person(for: loaded),
                  let relative = paths.relative(loaded.track.fileURL),
                  let folder = DeviceArtTree.parent(of: relative)
            else { continue }
            let keys = [PodBoxArtName.key(person), PodBoxArtName.altKey(person)].filter { $0 != 0 }

            // The group(s) this spelling belongs to; two groups it bridges become one.
            var found = Set(keys.compactMap { groupByKey[$0] })
            if keys.isEmpty, let index = groupByUnkeyed[person.lowercased()] { found.insert(index) }
            let index: Int
            if let first = found.min() {
                index = first
                for other in found where other != first {
                    groups[first].absorb(groups[other])
                    groups[other] = Group()
                    for (key, value) in groupByKey where value == other { groupByKey[key] = first }
                }
            } else {
                index = groups.count
                groups.append(Group())
            }
            for key in keys { groupByKey[key] = index }
            if keys.isEmpty { groupByUnkeyed[person.lowercased()] = index }
            groups[index].add(spelling: person, folder: folder, album: loaded.metadata.album ?? loaded.track.album)
        }

        return groups.filter { $0.trackCount > 0 }
            .map(\.artist)
            .sorted { ($0.trackCount, $1.name) > ($1.trackCount, $0.name) }
    }

    private struct Group {
        var spellings: [String: Int] = [:]
        var folders = Set<String>()
        var albums = Set<String>()
        var trackCount = 0

        mutating func add(spelling: String, folder: String, album: String?) {
            spellings[spelling, default: 0] += 1
            folders.insert(folder)
            if let album = album?.trimmingCharacters(in: .whitespacesAndNewlines), !album.isEmpty { albums.insert(album) }
            trackCount += 1
        }

        mutating func absorb(_ other: Group) {
            spellings.merge(other.spellings, uniquingKeysWith: +)
            folders.formUnion(other.folders)
            albums.formUnion(other.albums)
            trackCount += other.trackCount
        }

        var artist: ArtistOnDevice {
            let name = spellings.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.first?.key ?? ""
            return ArtistOnDevice(name: name, albumFolders: folders.sorted(), albumTitles: albums.sorted(),
                                  trackCount: trackCount)
        }
    }
}

/// What to write for the device's artists, and why each of the others gets nothing.
public struct ArtistPicturePlan: Sendable {
    /// Writes only, sorted by path.
    public let operations: [DeviceFileOperation]
    /// The player already shows a picture for these, the owner's or CrateDigger's own unchanged one.
    public let alreadyHasPicture: [String]
    /// No prepared picture yet (or pictures are switched off).
    public let noPictureYet: [String]
    /// The player's `/Artwork` limits are reached and no artist folder could take the picture.
    public let overBudget: [String]
    /// The player cannot match any file name to these names.
    public let unnameable: [String]
    /// A picture CrateDigger wrote that has since been changed on the iPod: the owner's now.
    public let foreign: [String]
    /// The simulation cannot tell what the player shows for these, so nothing is written.
    public let uncertain: [String]
    /// Why, per name, for every name in the lists above that is not being written.
    public let reasons: [String: String]
}

/// Plans artist pictures without ever hiding one the owner has.
///
/// A picture is written for a person only when `PodBoxArtLookup` says the
/// player finds none (`.none`). `.found` is left alone unless the file is
/// CrateDigger's own, proven by the journal and by its hash on the device
/// now, and `.uncertain` is always left alone. Every write goes through
/// `DeviceFileExecutor`, which proves ownership again before replacing.
public enum ArtistPicturePlanner {
    public static func plan(artists: [ArtistOnDevice], tree: DeviceArtTree,
                            prepared: [String: Data],
                            destination: ArtistPictureDestination,
                            ownedKeys: (String) -> DeviceFileRecord?,
                            sha256OnDevice: (String) -> String?) -> ArtistPicturePlan {
        var builder = Builder()
        let ordered = artists.sorted { ($0.trackCount, $1.name) > ($1.trackCount, $0.name) }
        guard destination != .off else {
            for artist in ordered { builder.hold(artist.name, in: \.noPictureYet, "artist pictures are off for this iPod") }
            return builder.plan
        }

        var working = tree
        var budget = PodBoxArtworkBudget(existingNames: tree.peopleFiles + tree.coverFiles)
        var plannedKeys: [UInt32: String] = [:]
        var people = 0

        for artist in ordered {
            let name = artist.name
            guard let bytes = prepared[artist.foldedKey] ?? prepared[PodBoxArtName.folded(name)] else {
                builder.hold(name, in: \.noPictureYet, "no picture has been found for this artist yet")
                continue
            }
            guard let stem = PodBoxArtName.fileStem(for: name) else {
                builder.hold(name, in: \.unnameable, "cannot be named on this player")
                continue
            }
            let keys = [PodBoxArtName.key(name), PodBoxArtName.altKey(name)].filter { $0 != 0 }
            if let first = keys.lazy.compactMap({ plannedKeys[$0] }).first {
                builder.hold(name, in: \.alreadyHasPicture, "shares one picture with \(first)")
                continue
            }
            for key in keys { plannedKeys[key] = name }
            people += 1
            guard people <= PodBoxArtworkBudget.people else {
                builder.hold(name, in: \.overBudget, "the player keeps pictures for at most \(PodBoxArtworkBudget.people) people")
                continue
            }
            if let music = tree.musicFolder,
               let outside = artist.albumFolders.first(where: { !DeviceArtTree.isWithin(DeviceArtTree.trimmedSlashes($0), music) }) {
                builder.hold(name, in: \.uncertain, "has tracks outside the music folder (\(outside)), which the simulation does not cover")
                continue
            }

            switch PodBoxArtLookup.artistPicture(for: name, albumFolders: artist.albumFolders, tree: working) {
            case .uncertain(let reason):
                builder.hold(name, in: \.uncertain, reason)

            case .found(let path):
                guard let record = ownedKeys(path), let recorded = record.sha256 else {
                    builder.hold(name, in: \.alreadyHasPicture, "the player already shows \(path)")
                    continue
                }
                guard sha256OnDevice(path) == recorded else {
                    builder.hold(name, in: \.foreign, "\(path) was changed on the iPod after CrateDigger wrote it")
                    continue
                }
                guard SHA256.hash(data: bytes).hexString != recorded else {
                    builder.hold(name, in: \.alreadyHasPicture, "CrateDigger's picture is already on the iPod")
                    continue
                }
                builder.write(path, role: role(of: path), bytes)

            case .none:
                let peopleTarget = DeviceArtTree.peopleFolder + "/" + stem + ".jpg"
                let folderTarget = artistFolderTarget(for: artist, tree: working)
                let preference: [String?] = destination == .artistFolders
                    ? [folderTarget, peopleTarget] : [peopleTarget, folderTarget]
                let targets = preference.compactMap { $0 }

                var written = false
                var overflowed = false
                for target in targets {
                    let isPeople = target == peopleTarget
                    let added = isPeople ? working.adding(peopleFile: stem + ".jpg")
                        : working.adding(image: "folder.jpg", in: DeviceArtTree.parent(of: target) ?? "")
                    // The player must then find exactly this file, or it is no use.
                    guard PodBoxArtLookup.artistPicture(for: name, albumFolders: artist.albumFolders,
                                                        tree: added) == .found(target) else { continue }
                    if isPeople {
                        guard budget.take(fileName: stem + ".jpg") else {
                            overflowed = true
                            continue
                        }
                    }
                    builder.write(target, role: role(of: target), bytes)
                    working = added
                    written = true
                    break
                }
                if !written {
                    if overflowed {
                        builder.hold(name, in: \.overBudget, "the player's /Artwork folder is full")
                    } else {
                        builder.hold(name, in: \.uncertain, "no file name the player would read as this artist's")
                    }
                }
            }
        }
        return builder.plan
    }

    /// Journal-owned picture files still matching their hash, as deletes.
    /// Only the latest record per path counts, and only a write.
    public static func removalPlan(journalRecords: [DeviceFileRecord],
                                   sha256OnDevice: (String) -> String?) -> [DeviceFileOperation] {
        let roles: Set<String> = [DeviceFileRole.artistPicture.rawValue, DeviceFileRole.artistFolderPicture.rawValue]
        var latest: [String: DeviceFileRecord] = [:]
        for record in journalRecords where record.kind != .tempIntent {
            latest[record.relativeKey] = record
        }
        return latest.values
            .filter { record in
                (record.kind == .created || record.kind == .replaced) && roles.contains(record.role)
                    && record.sha256 != nil && sha256OnDevice(record.relativePath) == record.sha256
            }
            .map(\.relativePath)
            .sorted()
            .map { .delete(relativePath: $0, reason: .ownedByCrateDigger) }
    }

    // MARK: - Private

    private static func role(of path: String) -> DeviceFileRole {
        DeviceArtTree.parent(of: path) == DeviceArtTree.peopleFolder ? .artistPicture : .artistFolderPicture
    }

    /// `<folder>/folder.jpg` when all of the person's albums sit in one
    /// folder that is named for them, holds no audio, holds only their
    /// albums, holds no picture the player would read, and was listed. A
    /// disc folder (`CD1`) stands for the album above it.
    private static func artistFolderTarget(for artist: ArtistOnDevice, tree: DeviceArtTree) -> String? {
        let albums = Set(artist.albumFolders.map { folder -> String in
            let trimmed = DeviceArtTree.trimmedSlashes(folder)
            return PodBoxArtLookup.isDiscFolder(DeviceArtTree.lastComponent(trimmed))
                ? DeviceArtTree.parent(of: trimmed) ?? trimmed : trimmed
        })
        let parents = Set(albums.compactMap { DeviceArtTree.parent(of: $0) })
        guard parents.count == 1, let folder = parents.first, !folder.isEmpty,
              tree.musicFolder.map({ folder != $0 && DeviceArtTree.isWithin(folder, $0) }) ?? true,
              tree.listedFolders?.contains(folder) ?? true,
              PodBoxArtName.matches(DeviceArtTree.lastComponent(folder), artist.name),
              !tree.foldersWithAudio.contains(folder),
              tree.artistsByFolder[folder] == [PodBoxArtName.folded(artist.name)],
              !(tree.folderImages[folder] ?? []).contains(where: { file in
                  let stem = (file as NSString).deletingPathExtension.lowercased()
                  return PodBoxArtLookup.folderImageStems.contains(stem)
              })
        else { return nil }
        return folder + "/folder.jpg"
    }

    private struct Builder {
        var writes: [DeviceFileOperation] = []
        var alreadyHasPicture: [String] = []
        var noPictureYet: [String] = []
        var overBudget: [String] = []
        var unnameable: [String] = []
        var foreign: [String] = []
        var uncertain: [String] = []
        var reasons: [String: String] = [:]

        mutating func hold(_ name: String, in list: WritableKeyPath<Builder, [String]>, _ reason: String) {
            self[keyPath: list].append(name)
            reasons[name] = reason
        }

        mutating func write(_ path: String, role: DeviceFileRole, _ bytes: Data) {
            writes.append(.write(relativePath: path, role: role, contents: .data(bytes)))
        }

        var plan: ArtistPicturePlan {
            ArtistPicturePlan(operations: writes.sorted { $0.relativePath < $1.relativePath },
                              alreadyHasPicture: alreadyHasPicture, noPictureYet: noPictureYet,
                              overBudget: overBudget, unnameable: unnameable, foreign: foreign,
                              uncertain: uncertain, reasons: reasons)
        }
    }
}

extension DeviceArtTree {
    /// This tree with one more file in `/Artwork/People`.
    func adding(peopleFile name: String) -> DeviceArtTree {
        copy(peopleFiles: (peopleFiles + [name]).sorted(), folderImages: folderImages)
    }

    /// This tree with one more image in `folder`.
    func adding(image name: String, in folder: String) -> DeviceArtTree {
        var images = folderImages
        images[folder, default: []].append(name)
        images[folder]?.sort()
        return copy(peopleFiles: peopleFiles, folderImages: images)
    }

    private func copy(peopleFiles: [String], folderImages: [String: [String]]) -> DeviceArtTree {
        DeviceArtTree(peopleFiles: peopleFiles, coverFiles: coverFiles, folderImages: folderImages,
                      foldersWithAudio: foldersWithAudio, artistsByFolder: artistsByFolder,
                      libraryFolders: libraryFolders, libraryTableFull: libraryTableFull,
                      listedFolders: listedFolders, bookFolders: bookFolders, musicFolder: musicFolder)
    }
}
