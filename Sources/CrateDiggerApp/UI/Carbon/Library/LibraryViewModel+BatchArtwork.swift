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
    /// The library-repair pass isn't writing for a player, it's writing for the
    /// album folder — so it keeps whatever it finds. Well above what iTunes or
    /// Deezer ever return, i.e. a cap that never actually shrinks anything.
    private static let libraryCoverMaxDimension = 3000
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
        /// Longest edge of the cover this album already has, if any. The fetch
        /// refuses to write anything smaller.
        let currentLongEdge: Int?
        /// A folder image whose size still has to be read off disk.
        let coverFileURL: URL?
    }

    /// Which albums a cover run is for.
    enum CoverFetchPolicy {
        /// Albums with no cover at all. Fast: nothing to measure.
        case missingOnly
        /// Also albums whose best cover is a thumbnail. Costs one header read
        /// per folder image, so it runs off the main actor first.
        case missingOrLowResolution
    }

    func searchAndAddCovers(for albums: [Album], policy: CoverFetchPolicy = .missingOnly) {
        // Flatten version groups to their member pressings — a group has no folder
        // of its own to write into; each pressing does.
        let candidates: [CoverTarget] = albums
            .flatMap { $0.versions ?? [$0] }
            .compactMap { album in
                guard let first = album.tracks.first?.track.fileURL, first.isFileURL else { return nil }
                let embedded = album.tracks
                    .compactMap(\.track.artworkDimensions)
                    .map(\.longEdge)
                    .max()
                return CoverTarget(
                    albumID: album.id,
                    artistName: album.artistName,
                    albumTitle: album.title,
                    folder: first.deletingLastPathComponent(),
                    trackIDs: album.tracks.map { $0.track.id },
                    filePaths: album.tracks.map { $0.track.fileURL.path },
                    currentLongEdge: embedded,
                    coverFileURL: album.booklet?.frontCoverURL
                )
            }

        switch policy {
        case .missingOnly:
            let targets = candidates.filter { $0.currentLongEdge == nil && $0.coverFileURL == nil }
            run(targets: targets,
                maxDimension: Self.batchCoverMaxDimension,
                emptyMessage: "Every album you selected already has a cover.")

        case .missingOrLowResolution:
            // Measuring folder images means a header read each — cheap, but not
            // thousands of them on the main actor.
            let activity = beginActivity("Checking artwork…")
            Task.detached(priority: .userInitiated) {
                let measured = candidates.map { target -> CoverTarget in
                    guard let coverURL = target.coverFileURL,
                          let size = ArtworkQuality.pixelSize(ofImageAt: coverURL)
                    else { return target }
                    return CoverTarget(
                        albumID: target.albumID, artistName: target.artistName,
                        albumTitle: target.albumTitle, folder: target.folder,
                        trackIDs: target.trackIDs, filePaths: target.filePaths,
                        currentLongEdge: max(size.longEdge, target.currentLongEdge ?? 0),
                        coverFileURL: coverURL
                    )
                }
                let needing = measured.filter {
                    ArtworkQuality.verdict(longEdges: [$0.currentLongEdge ?? 0]).needsWork
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.endActivity(activity)
                    self.run(targets: needing,
                             maxDimension: Self.libraryCoverMaxDimension,
                             emptyMessage: "Every album already has artwork of at least \(ArtworkQuality.minimumLongEdge) px.")
                }
            }
        }
    }

    private func run(targets: [CoverTarget], maxDimension: Int, emptyMessage: String) {
        guard !targets.isEmpty else {
            appAlert = .info(title: "Nothing to do", message: emptyMessage)
            return
        }

        for target in targets { albumsFetchingArtwork.insert(target.albumID) }

        let service = remoteArtworkService
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
                    : "\(missed) album\(missed == 1 ? "" : "s") had no better cover to offer — try the ART tab's Search Online for those."
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
            // Never trade down. iTunes will answer almost any query with
            // *something*, and a 300 px result over a 480 px cover is a
            // downgrade wearing a repair's clothes.
            guard ArtworkQuality.isUpgrade(from: target.currentLongEdge,
                                           to: sized.dimensions.longEdge) else { return nil }

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

/// One flagged album in the artwork audit.
struct ArtworkAuditRow: Identifiable, Sendable, Equatable {
    let id: String
    let artist: String
    let title: String
    /// Longest edge of the best cover the album has, nil when it has none.
    let longEdge: Int?
    let verdict: ArtworkQuality.Verdict

    var sizeLabel: String {
        guard let longEdge else { return "none" }
        return "\(longEdge) px"
    }
}

// MARK: - Library-wide artwork audit

@MainActor
extension LibraryViewModel {

    /// Sweep the whole local library for albums with no cover, or a cover too
    /// small to look at. Reads image headers only, off the main actor.
    func auditLibraryArtwork() {
        guard !isAuditingArtwork else { return }
        isAuditingArtwork = true

        let albums = index.artists.flatMap(\.albums).flatMap { $0.versions ?? [$0] }
        // Only what the probe needs, so nothing non-Sendable crosses over.
        let probes: [(id: String, coverURL: URL?, embedded: Int?)] = albums.map { album in
            (album.id,
             album.booklet?.frontCoverURL,
             album.tracks.compactMap(\.track.artworkDimensions).map(\.longEdge).max())
        }

        Task.detached(priority: .utility) {
            let best: [String: Int] = probes.reduce(into: [:]) { result, probe in
                var edge = probe.embedded ?? 0
                if let coverURL = probe.coverURL,
                   let size = ArtworkQuality.pixelSize(ofImageAt: coverURL) {
                    edge = max(edge, size.longEdge)
                }
                result[probe.id] = edge
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                var rows: [ArtworkAuditRow] = []
                var flagged: [Album] = []
                for album in albums {
                    let edge = best[album.id] ?? 0
                    let verdict = ArtworkQuality.verdict(longEdges: [edge])
                    guard verdict.needsWork else { continue }
                    rows.append(ArtworkAuditRow(id: album.id,
                                                artist: album.artistName,
                                                title: album.title,
                                                longEdge: edge > 0 ? edge : nil,
                                                verdict: verdict))
                    flagged.append(album)
                }
                // Worst first: the albums with nothing at all are the ones you
                // actually notice in the browser.
                let order: [ArtworkQuality.Verdict: Int] = [.missing: 0, .lowResolution: 1, .adequate: 2]
                self.artworkAudit = rows.sorted {
                    if $0.verdict != $1.verdict {
                        return (order[$0.verdict] ?? 2) < (order[$1.verdict] ?? 2)
                    }
                    return ($0.longEdge ?? 0) < ($1.longEdge ?? 0)
                }
                self.artworkAuditAlbums = flagged
                self.isAuditingArtwork = false
            }
        }
    }

    /// Fetch a better cover for every album the audit flagged.
    func fixAuditedArtwork() {
        searchAndAddCovers(for: artworkAuditAlbums, policy: .missingOrLowResolution)
    }
}
