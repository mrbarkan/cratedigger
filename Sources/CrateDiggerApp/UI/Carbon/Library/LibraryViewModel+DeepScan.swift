import Foundation
import CrateDiggerCore

// MARK: - DEEP SCAN (identify by audio)

/// FIX TAGS searches with the tags a file already has, which is no help at all
/// when those tags are blank or belong to a different record. DEEP SCAN is the
/// way through: fingerprint the audio, ask AcoustID what it is, and offer the
/// answer through the same review sheet.
///
/// It is never automatic. Fingerprinting decodes every file, so it runs when
/// the user presses for it — from the match sheet when the proposed release
/// looks wrong, or from the alert that says nothing matched by name.
extension LibraryViewModel {

    /// fpcalc, or nil when it isn't installed.
    private var fingerprintTool: URL? {
        ExternalToolLocator().resolveOptional(.fpcalc)?.url
    }

    var canDeepScan: Bool { fingerprintTool != nil }

    /// DEEP SCAN in the review sheet: listen to the album under review and put
    /// what the audio says at the top of the same candidate list.
    func deepScanCurrentAlbum() {
        runDeepScan(groups: [currentMatchTracks], replacingCurrent: true)
    }

    /// DEEP SCAN from the "didn't match" alert: listen to every album the text
    /// lookup gave up on.
    func deepScanUnmatchedAlbums() {
        let groups = matchQueueNoMatchGroups
        matchQueueNoMatchGroups = []
        runDeepScan(groups: groups, replacingCurrent: false)
    }

    private func runDeepScan(groups: [[LoadedTrack]], replacingCurrent: Bool) {
        guard !isRepairingMetadata else { return }

        guard let fpcalc = fingerprintTool else {
            appAlert = .info(
                title: "Deep Scan Unavailable",
                message: "CrateDigger identifies audio with fpcalc and couldn't find it. "
                    + "Reinstalling CrateDigger restores the bundled copy, or install it "
                    + "yourself with \"brew install chromaprint\"."
            )
            return
        }

        guard AcoustIDClient.applicationKey != AcoustIDClient.placeholderKey else {
            appAlert = acoustIDKeyAlert
            return
        }

        let albums = groups.filter { !$0.isEmpty }
        guard !albums.isEmpty else { return }

        isRepairingMetadata = true
        showOLEDNotice("LISTENING…")
        let activity = beginActivity("Identifying audio…")
        let service = FingerprintMatchService(fpcalcURL: fpcalc)
        // Captured now: the sheet's own list is about to be replaced, and the
        // text matches have to survive as the runners-up.
        let existingMatches = metadataMatches

        // Not detached: everything expensive already leaves the cooperative pool
        // on its own (fpcalc through BlockingWork, the lookups through URLSession),
        // so a main-actor task costs nothing and keeps LoadedTrack off the
        // Sendable-crossing path. Strong self, as elsewhere in this file: the
        // view model is app-lifetime.
        metadataRepairTask = Task {
            var found: [AlbumMatchBatch] = []
            var serviceError: AcoustIDError?

            for (albumIndex, album) in albums.enumerated() {
                if Task.isCancelled { break }
                let label = Self.albumLabel(for: album)
                let result = await service.match(for: album) { done, total in
                    let text = albums.count == 1
                        ? "LISTENING… \(done)/\(total)"
                        : "LISTENING… \(albumIndex + 1)/\(albums.count) · \(done)/\(total)"
                    Task { @MainActor in self.showOLEDNotice(text) }
                }
                if let error = result.serviceError {
                    // AcoustID refused us; the next album would fare no better.
                    serviceError = error
                    break
                }
                if !result.matches.isEmpty {
                    found.append(AlbumMatchBatch(albumLabel: label, tracks: album, matches: result.matches))
                }
            }

            let wasCancelled = Task.isCancelled
            self.finishDeepScan(
                found,
                albumCount: albums.count,
                existingMatches: existingMatches,
                replacingCurrent: replacingCurrent,
                cancelled: wasCancelled,
                serviceError: serviceError,
                activity: activity
            )
        }
    }

    /// One message for both ways the key can be wrong: never set, or set to
    /// something AcoustID won't accept. Names the actual fix, because "invalid
    /// API key" is not something a user can act on.
    private var acoustIDKeyAlert: AppAlert {
        .info(
            title: "Deep Scan Not Configured",
            message: "This build has no valid AcoustID application key, so audio lookups are refused "
                + "before they start. Nothing was changed. Register an application at "
                + "acoustid.org/new-application and put its key in AcoustIDClient.applicationKey. "
                + "The account key on acoustid.org/api-key is a different string and will not work here."
        )
    }

    @MainActor
    private func finishDeepScan(
        _ found: [AlbumMatchBatch],
        albumCount: Int,
        existingMatches: [ReleaseMatch],
        replacingCurrent: Bool,
        cancelled: Bool,
        serviceError: AcoustIDError?,
        activity: UUID
    ) {
        endActivity(activity)
        isRepairingMetadata = false
        metadataRepairTask = nil

        guard !cancelled else {
            showOLEDNotice("DEEP SCAN STOPPED")
            return
        }

        if let serviceError {
            // Never let this read as "your record isn't in the database". It
            // isn't about the record at all.
            showOLEDNotice("DEEP SCAN REFUSED")
            appAlert = serviceError.isInvalidKey
                ? acoustIDKeyAlert
                : .info(
                    title: "Deep Scan Unavailable",
                    message: "AcoustID turned the lookup down: \(serviceError.localizedDescription) "
                        + "Nothing was changed. Try again later."
                )
            return
        }

        guard let first = found.first else {
            showOLEDNotice("NO AUDIO MATCH")
            appAlert = .info(
                title: "No Audio Match",
                message: albumCount == 1
                    ? "The audio didn't match anything in the AcoustID database. Unreleased, "
                        + "self-pressed and very obscure recordings often aren't in it."
                    : "None of the \(albumCount) albums matched by audio. Unreleased, "
                        + "self-pressed and very obscure recordings often aren't in AcoustID."
            )
            return
        }

        if replacingCurrent {
            // The audio's answer leads; the text matches stay behind it in the
            // pager, because a fingerprint can still land on the wrong pressing
            // of the right record and the user may prefer one of the others.
            let audioIDs = Set(first.matches.map(\.id))
            metadataMatches = first.matches + existingMatches.filter { !audioIDs.contains($0.id) }
            currentMatchTracks = first.tracks
        } else {
            pendingMatchBatches = Array(found.dropFirst())
            matchQueueProgress = found.count > 1 ? MatchQueueProgress(current: 1, total: found.count) : nil
            currentMatchAlbumLabel = first.albumLabel
            currentMatchTracks = first.tracks
            metadataMatches = first.matches
        }

        matchRevision += 1
        showOLEDNotice("AUDIO MATCH")
        AppLog.library.notice(
            "DEEP SCAN identified \(found.count, privacy: .public) of \(albumCount, privacy: .public) album(s) by audio"
        )
    }
}
