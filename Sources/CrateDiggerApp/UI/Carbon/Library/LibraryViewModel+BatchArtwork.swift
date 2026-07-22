import AppKit
import CryptoKit
import CrateDiggerCore
import Foundation

/// Batch cover fetch: pick the best iTunes match per album by metadata, write a
/// device-ready cover into the album folder, and rebuild the indexes **once**.
///
/// For people who want covers everywhere without curating each one. Detailed
/// per-album search stays available in the Inspector's ART tab afterwards.
@MainActor
extension LibraryViewModel {

    /// Long edge of the written cover. 600px baseline JPEG is what legacy players
    /// and Rockbox can read, so the art is device-ready as written — no second
    /// pass needed before a transfer.
    private static let batchCoverMaxDimension = 600
    /// Matches the per-file cap in `embedCoverIntoTracksInBackground`, and keeps
    /// us from hammering iTunes.
    private static let batchCoverConcurrency = 4

    /// One album to fetch for: its folder, and its tracks captured up front.
    ///
    /// Captured rather than re-looked-up by id: version-group members aren't
    /// addressable via `index.album(id:)`, and the index is rebuilt underneath us
    /// at the end anyway.
    private struct CoverTarget: Sendable {
        let albumID: String
        let artistName: String
        let albumTitle: String
        let folder: URL
        let trackIDs: [UUID]
        let filePaths: [String]
    }

    func searchAndAddCovers(for albums: [Album]) {
        // Flatten version groups to their member pressings — a group has no folder
        // of its own to write into; each pressing does.
        let targets: [CoverTarget] = albums
            .flatMap { $0.versions ?? [$0] }
            .filter { $0.artworkHash == nil && $0.booklet?.frontCoverURL == nil }
            .compactMap { album in
                guard let first = album.tracks.first?.track.fileURL, first.isFileURL else { return nil }
                return CoverTarget(
                    albumID: album.id,
                    artistName: album.artistName,
                    albumTitle: album.title,
                    folder: first.deletingLastPathComponent(),
                    trackIDs: album.tracks.map { $0.track.id },
                    filePaths: album.tracks.map { $0.track.fileURL.path }
                )
            }

        guard !targets.isEmpty else {
            appAlert = .info(
                title: "Nothing to do",
                message: "Every album you selected already has a cover."
            )
            return
        }

        for target in targets { albumsFetchingArtwork.insert(target.albumID) }

        let service = remoteArtworkService
        let maxDimension = Self.batchCoverMaxDimension
        let concurrency = Self.batchCoverConcurrency

        // @MainActor on the Task: `found` and albumsFetchingArtwork are then
        // plain main-actor state, with no inout-across-await or sendability
        // puzzle to solve.
        Task { @MainActor [weak self] in
            var found: [(target: CoverTarget, asset: ArtworkAsset)] = []

            // Chunked rather than a sliding window: one barrier per chunk costs a
            // little throughput on a network-bound batch and buys a loop anyone
            // can read at 3am.
            var start = 0
            while start < targets.count {
                let chunk = Array(targets[start..<min(start + concurrency, targets.count)])
                start += concurrency

                let results = await withTaskGroup(
                    of: (CoverTarget, ArtworkAsset?).self
                ) { group -> [(CoverTarget, ArtworkAsset?)] in
                    for target in chunk {
                        group.addTask {
                            (target, await Self.fetchAndWriteCover(
                                target: target, service: service, maxDimension: maxDimension
                            ))
                        }
                    }
                    var collected: [(CoverTarget, ArtworkAsset?)] = []
                    for await result in group { collected.append(result) }
                    return collected
                }

                for (target, asset) in results {
                    self?.albumsFetchingArtwork.remove(target.albumID)
                    if let asset { found.append((target, asset)) }
                }
            }

            guard let self else { return }
            self.applyBatchCovers(found)
            let matched = found.count
            let missed = targets.count - matched
            self.appAlert = .info(
                title: matched == 0 ? "No covers found" : "Added \(matched) cover\(matched == 1 ? "" : "s")",
                message: missed == 0
                    ? "All \(matched) album\(matched == 1 ? "" : "s") matched."
                    : "\(missed) album\(missed == 1 ? "" : "s") had no match — try the ART tab's Search Online for those."
            )
        }
    }

    /// Off the main actor: match, downscale, write `cover.jpg` + manifest.
    /// Returns nil for a no-match or any write failure — both are counted, not alerted.
    private nonisolated static func fetchAndWriteCover(
        target: CoverTarget,
        service: RemoteArtworkService,
        maxDimension: Int
    ) async -> ArtworkAsset? {
        do {
            let remote = try await service.fetchArtwork(artist: target.artistName, album: target.albumTitle)
            let sized = try ArtworkService().prepareCompatibleArtwork(
                asset: remote, profile: .generic, maxDimension: maxDimension
            )
            guard !sized.data.isEmpty else { return nil }

            let coverURL = target.folder.appendingPathComponent("cover.jpg")
            try sized.data.write(to: coverURL, options: .atomic)

            var manifest = ArtworkManifest.load(from: target.folder) ?? ArtworkManifest()
            manifest.roles["cover.jpg"] = .cover
            try? manifest.save(to: target.folder)

            // Re-hash the bytes we actually wrote — prepareCompatibleArtwork
            // re-encodes, so the remote asset's hash no longer addresses them.
            let hash = SHA256.hash(data: sized.data).compactMap { String(format: "%02x", $0) }.joined()
            return ArtworkAsset(
                source: .folderImage,
                hash: hash,
                dimensions: sized.dimensions,
                data: sized.data
            )
        } catch {
            AppLog.library.warning(
                "Batch cover fetch failed for \(target.albumTitle): \(String(describing: error))"
            )
            return nil
        }
    }

    /// Rebuild the indexes **once** for the whole batch.
    ///
    /// applyImportedArtwork rebuilds all three indexes per call, which is fine for
    /// one album and a freeze for a hundred at 14k tracks — hence this variant.
    /// The actual index rewrite lives in `applyFolderCovers` back in
    /// LibraryViewModel.swift: `index`/`localIndex` are `private(set)`, writable
    /// only from the file that declares them.
    private func applyBatchCovers(_ found: [(target: CoverTarget, asset: ArtworkAsset)]) {
        guard !found.isEmpty else { return }

        var assetByTrackID: [UUID: ArtworkAsset] = [:]
        for (target, asset) in found {
            artworkService.ingest(asset)
            indexDiskCache.invalidate(albumFolderPath: target.folder.path, filePaths: target.filePaths)
            for id in target.trackIDs { assetByTrackID[id] = asset }
        }

        applyFolderCovers(assetByTrackID)
    }
}
