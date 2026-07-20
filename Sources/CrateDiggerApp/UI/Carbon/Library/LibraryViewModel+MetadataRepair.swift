import Foundation
import CrateDiggerCore

/// One track's stored-vs-file tag disagreements, held with the fresh probe so
/// the review sheet can adopt chosen file values without re-probing.
struct MetadataRepairConflictGroup: Identifiable {
    let trackID: UUID
    let trackTitle: String
    let fileURL: URL
    let probed: ConversionMetadata
    let conflicts: [MetadataFieldConflict]
    var id: UUID { trackID }
}

/// One album's worth of FIX TAGS online matches, queued for sequential review.
struct AlbumMatchBatch: Identifiable {
    let id = UUID()
    let albumLabel: String
    let matches: [ReleaseMatch]
}

struct MatchQueueProgress: Equatable {
    var current: Int
    var total: Int
}

// MARK: - Metadata repair (FIX TAGS)

extension LibraryViewModel {

    /// FIX TAGS only makes sense where tracks are crate-backed local files.
    var canRepairMetadata: Bool {
        if case .prepCrate = currentSource { return true }
        return isLocalSource
    }

    /// One-press repair.
    ///
    /// **With a selection** (the everyday case): re-probe every selected track,
    /// heal blank tags from the file, then look the release up online and offer
    /// the differences for review — the user picks which fields to overwrite.
    /// The local probe runs first on purpose: filling blanks from the file's own
    /// tags gives the lookup better search terms than an empty crate row would.
    ///
    /// **With nothing selected**: the whole source, but only tracks whose number
    /// is missing OR duplicated within its album (an album of all "11"s is as
    /// broken as one with blanks) — probing an entire library on every press is
    /// too slow, and looking every album up online would hammer the services.
    /// This path stays local-only and never writes to the audio files.
    func repairMissingMetadata() {
        guard canRepairMetadata, !isRepairingMetadata else { return }

        // Duplicated (disc, track#) within an album — cheap, in-memory, over the
        // whole index. Selected tracks live in this index, so their dup status
        // (used by the filename-inference below) is captured here regardless of
        // scope.
        var duplicatedIDs: Set<UUID> = []
        for artist in index.artists {
            for album in artist.albums {
                duplicatedIDs.formUnion(MetadataRepairPlanner.duplicatedNumberTrackIDs(in: album.tracks))
            }
        }

        let hasSelection = !selectedTrackIDs.isEmpty || !selectedAlbumIDs.isEmpty || !selectedArtistIDs.isEmpty
        let candidates = hasSelection
            ? selectedTracksForCrateAdd()
            : index.allTracks.filter {
                MetadataRepairPlanner.needsRepair($0.metadata) || duplicatedIDs.contains($0.track.id)
            }
        guard !candidates.isEmpty else {
            appAlert = .info(title: "Tags Check Out",
                             message: "Every track in this source has a track number, with no duplicates inside an album.")
            return
        }

        isRepairingMetadata = true
        showOLEDNotice("CHECKING TAGS…")

        let scanner = self.scanner
        let dupIDs = duplicatedIDs
        let total = candidates.count
        let scoped = hasSelection

        // Detached: the probes must not touch the main actor at all — the first
        // (sequential, main-inherited) version of this loop froze the app for
        // the whole run on a big crate. Strong self is fine: the view model is
        // app-lifetime and @MainActor (Sendable); it's only touched via
        // MainActor.run.
        Task.detached(priority: .userInitiated) {
            typealias ProbeResult = (track: LoadedTrack, outcome: MetadataRepairOutcome, probed: ConversionMetadata)?
            var repaired: [LoadedTrack] = []
            var conflictGroups: [MetadataRepairConflictGroup] = []
            var unreadable = 0
            var completed = 0

            func collect(_ result: ProbeResult) async {
                completed += 1
                if completed % 10 == 0 || completed == total {
                    let done = completed
                    await MainActor.run { self.showOLEDNotice("CHECKING TAGS… \(done)/\(total)") }
                }
                guard let result else {
                    unreadable += 1
                    return
                }
                if result.outcome.didFill {
                    repaired.append(Self.applying(result.outcome.metadata, to: result.track))
                }
                if !result.outcome.conflicts.isEmpty {
                    conflictGroups.append(MetadataRepairConflictGroup(
                        trackID: result.track.track.id,
                        trackTitle: result.track.track.title,
                        fileURL: result.track.track.fileURL,
                        probed: result.probed,
                        conflicts: result.outcome.conflicts
                    ))
                }
            }

            await withTaskGroup(of: ProbeResult.self) { group in
                // ponytail: fixed width 6 — enough to hide ffprobe spawn latency
                // without contending with playback; tune if a huge crate crawls.
                var inFlight = 0
                for track in candidates {
                    if inFlight >= 6, let done = await group.next() {
                        inFlight -= 1
                        await collect(done)
                    }
                    group.addTask {
                        guard let fresh = await scanner.reloadTrack(at: track.track.fileURL) else { return nil }
                        var probed = fresh.metadata
                        // The all-tracks-are-"11" case: the file's tag just
                        // echoes the same duplicated number (the crate was
                        // scanned from these files), so tag-vs-tag comparison
                        // sees nothing. The filename ("03 - Song.flac") is the
                        // remaining honest signal — offer its number as the
                        // conflict's file value.
                        if dupIDs.contains(track.track.id),
                           probed.trackNumber == track.metadata.trackNumber,
                           let inferred = MetadataNormalization.trackNumber(
                               fromFilename: track.track.fileURL.deletingPathExtension().lastPathComponent),
                           inferred != track.metadata.trackNumber {
                            probed.trackNumber = inferred
                        }
                        return (track, MetadataRepairPlanner.repair(stored: track.metadata, probed: probed), probed)
                    }
                    inFlight += 1
                }
                for await done in group {
                    await collect(done)
                }
            }

            let finalRepaired = repaired
            let finalGroups = conflictGroups
            let finalUnreadable = unreadable
            await MainActor.run {
                if !finalRepaired.isEmpty {
                    self.updateTrackURLsInIndex(finalRepaired)
                }
                self.showOLEDNotice(finalRepaired.isEmpty ? "TAGS CHECKED" : "TAGS REPAIRED")
            }

            guard scoped else {
                await MainActor.run {
                    self.isRepairingMetadata = false
                    self.metadataRepairConflicts = finalGroups

                    var lines = ["Checked \(total) track\(total == 1 ? "" : "s") with a missing or duplicated track number."]
                    lines.append(finalRepaired.isEmpty
                        ? "No fixes found in the files' tags."
                        : "Filled tags on \(finalRepaired.count) track\(finalRepaired.count == 1 ? "" : "s") from the files.")
                    if finalUnreadable > 0 { lines.append("\(finalUnreadable) file\(finalUnreadable == 1 ? "" : "s") couldn't be read.") }
                    if !finalGroups.isEmpty { lines.append("\(finalGroups.count) track\(finalGroups.count == 1 ? "" : "s") have tags that differ from the files — review them next.") }
                    self.appAlert = .info(title: "Tag Check Complete", message: lines.joined(separator: " "))
                }
                return
            }

            // Hand the *healed* tracks to the lookup, not the stale originals.
            let healedByID = Dictionary(uniqueKeysWithValues: finalRepaired.map { ($0.track.id, $0) })
            let healed = candidates.map { healedByID[$0.track.id] ?? $0 }
            await self.matchSelectionOnline(tracks: healed, localConflicts: finalGroups, unreadable: finalUnreadable)
        }
    }

    /// The online half of FIX TAGS: partition the selection into albums (the
    /// old code collapsed everything into ONE release query — a multi-album
    /// selection got shoehorned into the majority album), look each album up,
    /// and queue the results for sequential review.
    ///
    /// A dry lookup falls back to whatever the local pass found rather than
    /// throwing that work away — being offline should cost you the online
    /// answers, not the ones already in hand.
    @MainActor
    private func matchSelectionOnline(
        tracks: [LoadedTrack],
        localConflicts: [MetadataRepairConflictGroup],
        unreadable: Int
    ) async {
        let groups = MetadataMatchService.partitionByAlbum(tracks)
        // ponytail: uncapped — 30 loose singles = 30 sequential lookups
        // (~1s each behind the MusicBrainz throttle); the OLED counter keeps
        // the wait visible rather than mysterious.
        var batches: [AlbumMatchBatch] = []
        var noMatch: [String] = []
        let activity = beginActivity("Matching tags online…")

        for (i, group) in groups.enumerated() {
            showOLEDNotice(groups.count == 1
                           ? "MATCHING TAGS…"
                           : "MATCHING TAGS… \(i + 1)/\(groups.count)")
            let label = Self.albumLabel(for: group)
            let matches = await matchService.match(for: group)
            if matches.isEmpty {
                noMatch.append(label)
            } else {
                batches.append(AlbumMatchBatch(albumLabel: label, matches: matches))
            }
        }
        endActivity(activity)
        isRepairingMetadata = false

        if let first = batches.first {
            matchQueueNoMatchLabels = noMatch
            matchQueueProgress = groups.count > 1
                ? MatchQueueProgress(current: 1, total: batches.count)
                : nil
            pendingMatchBatches = Array(batches.dropFirst())
            currentMatchAlbumLabel = first.albumLabel
            metadataMatches = first.matches
            showOLEDNotice("MATCH FOUND")
            return
        }

        if !localConflicts.isEmpty {
            metadataRepairConflicts = localConflicts
            return
        }

        var lines = ["No online release matched \(tracks.count == 1 ? "this track" : "these \(tracks.count) tracks")."]
        lines.append("Check the artist and album tags — they're what the lookup searches with.")
        if unreadable > 0 { lines.append("\(unreadable) file\(unreadable == 1 ? "" : "s") couldn't be read.") }
        appAlert = .info(title: "No Match Found", message: lines.joined(separator: " "))
    }

    private static func albumLabel(for group: [LoadedTrack]) -> String {
        let album = group.first?.metadata.album ?? group.first?.track.album
        let trimmed = album?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Unknown Album" : trimmed
    }

    /// Pop the next album's matches into the sheet, or wrap up the queue.
    func advanceMatchQueue() {
        if let next = pendingMatchBatches.first {
            pendingMatchBatches.removeFirst()
            currentMatchAlbumLabel = next.albumLabel
            metadataMatches = next.matches
            if var progress = matchQueueProgress {
                progress.current += 1
                matchQueueProgress = progress
            }
        } else {
            finishMatchQueue()
        }
    }

    /// Closing the sheet abandons the remaining queue — the predictable
    /// escape hatch; SKIP is the per-album pass.
    func cancelMatchQueue() {
        pendingMatchBatches = []
        finishMatchQueue()
    }

    private func finishMatchQueue() {
        metadataMatches = []
        currentMatchAlbumLabel = nil
        matchQueueProgress = nil
        let skipped = matchQueueNoMatchLabels
        matchQueueNoMatchLabels = []
        if !skipped.isEmpty {
            appAlert = .info(
                title: "Some Albums Didn't Match",
                message: "No online release matched: \(skipped.joined(separator: ", ")). Check their artist and album tags."
            )
        }
    }

    /// Apply a reviewed match: for every track, write just the fields the user
    /// checked. Goes through the normal tag-write path, so files are rewritten,
    /// crates re-pointed, and the library re-organised exactly as a hand edit
    /// would be.
    func applyReleaseMatch(_ match: ReleaseMatch, fields: Set<MetadataRepairField>) {
        defer { advanceMatchQueue() }
        guard !fields.isEmpty else { return }

        var written = 0
        for proposal in match.trackProposals {
            let chosen = proposal.changedFields.filter { fields.contains($0) }
            // Re-read the track from the index rather than trusting the snapshot
            // the proposal captured — it may have been healed since.
            guard !chosen.isEmpty,
                  let track = index.allTracks.first(where: { $0.track.id == proposal.trackID })
            else { continue }

            let merged = MetadataRepairPlanner.adopt(chosen, from: proposal.proposed, into: track.metadata)
            guard merged != track.metadata else { continue }
            updateTrackMetadata(track, newMetadata: merged)
            written += 1
        }

        guard written > 0 else { return }
        showOLEDNotice("TAGS MATCHED")
        AppLog.library.notice(
            "Applied \(match.candidate.source.rawValue, privacy: .public) match to \(written) track(s)"
        )
    }

    /// Apply the review sheet's decisions: for each group, adopt the chosen
    /// conflict fields from the file's tags into the stored metadata.
    func resolveMetadataRepairConflicts(_ chosen: [UUID: [MetadataRepairField]]) {
        let groups = metadataRepairConflicts
        metadataRepairConflicts = []
        var updated: [LoadedTrack] = []

        for group in groups {
            guard let fields = chosen[group.trackID], !fields.isEmpty,
                  let track = index.allTracks.first(where: { $0.track.id == group.trackID })
            else { continue }
            let merged = MetadataRepairPlanner.adopt(fields, from: group.probed, into: track.metadata)
            updated.append(Self.applying(merged, to: track))
        }

        guard !updated.isEmpty else { return }
        updateTrackURLsInIndex(updated)
        showOLEDNotice("TAGS UPDATED")
    }

    /// Rebuild a LoadedTrack around repaired metadata, mirroring the surfaced
    /// fields the scanner derives (title/artist/album/year/track/disc) while
    /// keeping identity, file info, markers, and artwork untouched.
    /// `nonisolated`: pure value work, called from the detached probe task.
    nonisolated private static func applying(_ metadata: ConversionMetadata, to loaded: LoadedTrack) -> LoadedTrack {
        var track = loaded.track
        if let title = metadata.title, !title.isEmpty { track.title = title }
        if let artist = metadata.artist { track.artist = artist }
        if let album = metadata.album { track.album = album }
        track.year = metadata.year
        track.trackNumber = metadata.trackNumber
        track.trackTotal = metadata.trackTotal
        track.discNumber = metadata.discNumber
        track.discTotal = metadata.discTotal
        return LoadedTrack(track: track, metadata: metadata, recordMarkers: loaded.recordMarkers)
    }
}
