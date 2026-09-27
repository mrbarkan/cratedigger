import AppKit
import CrateDiggerCore
import Foundation

/// Identifying an audio CD before it is ripped.
///
/// The order matters more than it looks. Ripping bakes tags into filenames and
/// into the folder tree the output planner builds, so fixing them afterwards
/// means moving and renaming files, not just retagging — and a CD arrives with
/// no tags to fix *from*: macOS mounts it as "1 Audio Track.aiff" on a volume
/// called "Audio CD". Identifying the disc first turns the whole rip into a
/// normal, correctly-tagged conversion.
@MainActor
extension LibraryViewModel {

    /// Look the disc up by its TOC. Safe to call repeatedly — it no-ops while a
    /// lookup is in flight and when the disc has already been identified.
    func detectAudioCD(_ info: AudioCDInfo, force: Bool = false) {
        guard let toc = info.toc else {
            cdDetectionState = .unavailable
            return
        }
        // `selectCD` calls this, and adopting a match rebuilds through
        // `selectSource` — so without a settled-state guard, identifying a disc
        // would re-enter the lookup, and a disc MusicBrainz doesn't have would
        // be re-queried on every refresh of the browser.
        if !force, cdDetectionState.isSettled || cdMatchedRelease != nil { return }

        cdDetectionState = .looking
        cdDiscMatches = []
        showOLEDNotice("IDENTIFYING DISC…")

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let candidates = try await self.discLookup.lookup(toc: toc)
                guard !candidates.isEmpty else {
                    self.cdDetectionState = .notFound(toc: toc)
                    self.showOLEDNotice("DISC NOT IN DATABASE")
                    return
                }
                self.cdDiscMatches = candidates
                // One match is not a choice — adopt it. Several means the same
                // pressing appears standalone and inside box sets, which changes
                // the album tag, so that is the user's call.
                if candidates.count == 1 {
                    self.applyDiscMatch(candidates[0], to: info)
                } else {
                    self.cdDetectionState = .choosing
                    self.showOLEDNotice("\(candidates.count) RELEASES MATCH")
                }
            } catch CDDiscLookupError.discNotFound {
                self.cdDetectionState = .notFound(toc: toc)
                self.showOLEDNotice("DISC NOT IN DATABASE")
            } catch {
                self.cdDetectionState = .failed(error.localizedDescription)
                self.showOLEDNotice("LOOKUP FAILED")
            }
        }
    }

    /// Adopt a release: retag the mounted CD's tracks in place so the browser,
    /// the inspector and the rip all agree before a single sector is read.
    func applyDiscMatch(_ candidate: ReleaseCandidate, to info: AudioCDInfo) {
        cdMatchedRelease = candidate
        // Staged edits are whole tag sets made against the previous release;
        // kept, they would pin its album and artist over this one.
        cdStagedEdits = [:]
        cdDetectionState = .identified(candidate)
        cdDiscMatches = []
        cdCoverArtwork = nil
        rebuildCDIndex(for: info)
        showOLEDNotice("DISC IDENTIFIED")
        fetchDiscCover(for: candidate, info: info)
    }

    /// Pull the identified release's cover so the rip can embed it.
    ///
    /// Without this a rip produced a perfectly tagged album with a blank cover,
    /// and the user had to run artwork search afterwards for something we
    /// already knew — the disc ID resolves to a release, and Cover Art Archive
    /// serves that release's front by MBID.
    private func fetchDiscCover(for candidate: ReleaseCandidate, info: AudioCDInfo) {
        guard let url = candidate.artworkURL else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let asset = try? await self.remoteArtworkService.fetchArtwork(from: url) else { return }
            // A release with no art in the archive is normal; the rip just
            // carries no cover, exactly as before.
            self.artworkService.ingest(asset)
            self.cdCoverArtwork = asset
            self.rebuildCDIndex(for: info)
        }
    }

    /// Forget the match and go back to the raw disc.
    func clearDiscMatch(for info: AudioCDInfo) {
        resetDiscMatch()
        rebuildCDIndex(for: info)
    }

    func resetDiscMatch() {
        cdMatchedRelease = nil
        cdStagedEdits = [:]
        cdDetectionState = .idle
        cdDiscMatches = []
        cdCoverArtwork = nil
    }

    /// Putting a disc in the drive is asking to dub it: open it on the DUB
    /// screen, which also starts the lookup. Only discs macOS wrote a TOC for,
    /// so a drive that merely has AIFFs at its root never takes over the browser.
    func selectInsertedCD(excluding known: Set<String> = []) {
        guard let cd = mountedCDs.first(where: { $0.toc != nil && !known.contains($0.volumeURL.path) }) else { return }
        selectSource(.cd(volumePath: cd.volumeURL.path))
    }

    /// The tracks the CD source shows and the rip tags: the matched release's
    /// tags when we have one, otherwise whatever macOS gave us, with the user's
    /// staged edits on top. See `CDRipTagPlanner`.
    func cdTracks(for info: AudioCDInfo) -> [LoadedTrack] {
        CDRipTagPlanner.tracks(for: info, release: cdMatchedRelease, cover: cdCoverArtwork,
                               stagedEdits: cdStagedEdits)
    }

    /// Which disc of a multi-disc release this CD is. See
    /// `CDRipTagPlanner.discNumber(in:trackCount:)`.
    var cdMatchedDiscNumber: Int {
        guard let release = cdMatchedRelease, let info = currentAudioCD else { return 1 }
        return CDRipTagPlanner.discNumber(in: release, trackCount: info.tracks.count)
    }

    /// Tag edits aimed at a disc's tracks can't be written: the volume is
    /// read-only, and the files are about to be ripped anyway. Stage them for
    /// the rip instead and hand back the updates that are real files. Both
    /// tag-write paths (the inspector's editor and FIX TAGS) start here.
    func stagingCDEdits(
        _ updates: [(track: LoadedTrack, metadata: ConversionMetadata)]
    ) -> [(track: LoadedTrack, metadata: ConversionMetadata)] {
        let discRoots = mountedCDs.map { $0.volumeURL.standardizedFileURL.path + "/" }
        guard !discRoots.isEmpty else { return updates }
        var rest: [(track: LoadedTrack, metadata: ConversionMetadata)] = []
        var staged = 0
        for update in updates {
            let path = update.track.track.fileURL.standardizedFileURL.path
            guard discRoots.contains(where: { path.hasPrefix($0) }) else {
                rest.append(update)
                continue
            }
            cdStagedEdits[update.track.track.fileURL.path] = update.metadata
            staged += 1
        }
        guard staged > 0 else { return rest }
        if let info = currentAudioCD { rebuildCDIndex(for: info) }
        showOLEDNotice(staged == 1 ? "STAGED FOR RIP" : "\(staged) STAGED FOR RIP")
        return rest
    }

    /// The CD currently being browsed, if any.
    var currentAudioCD: AudioCDInfo? {
        guard case .cd(let path) = currentSource else { return nil }
        return mountedCDs.first { $0.volumeURL.path == path }
    }

    /// Rebuild the CD's view after the match changes. Goes through
    /// `selectSource` so there is one place that builds a CD index.
    func rebuildCDIndex(for info: AudioCDInfo) {
        guard case .cd(let path) = currentSource, path == info.volumeURL.path else { return }
        selectSource(currentSource)
    }

    /// Open the MusicBrainz page for attaching this disc to a release — the one
    /// useful action when a disc isn't in the database yet.
    func submitDiscToMusicBrainz(_ toc: CompactDiscTOC) {
        guard let url = MusicBrainzDiscClient.submissionURL(for: toc) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Where disc identification has got to.
enum CDDetectionState: Equatable {
    case idle
    case looking
    /// Several pressings share this TOC; the user picks.
    case choosing
    case identified(ReleaseCandidate)
    /// Valid TOC, but MusicBrainz has never seen this pressing.
    case notFound(toc: CompactDiscTOC)
    case failed(String)
    /// No TOC on the volume — not an audio CD, or macOS didn't write one.
    case unavailable

    var isBusy: Bool { self == .looking }

    /// True once this disc has been dealt with — in flight, answered, or known
    /// to have no answer. Only `.idle` invites a fresh lookup; anything else
    /// needs an explicit retry.
    var isSettled: Bool { self != .idle }
}
