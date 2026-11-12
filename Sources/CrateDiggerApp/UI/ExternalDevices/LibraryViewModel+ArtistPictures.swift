import AppKit
import CrateDiggerCore
import Foundation

/// Artist pictures on a PodBox iPod, wired. Every decision is Core's
/// (`ArtistPictureSession`, `ArtistPictureFinder`, `ArtistPicturePlanner`);
/// this gathers what they need, runs the slow parts off the main actor and
/// writes only through the device write door. Nothing here runs at mount:
/// pictures are written inside a session the owner started (a transfer, or
/// Apply in the Artist Pictures sheet), and found online only when the owner
/// asked for it (Find Missing, or the device's own switch, off by default).
extension LibraryViewModel {
    // MARK: - The profiles

    /// Keeps what the finder concluded in the artist profiles (the same
    /// records the artist page shows), under the owner's rules
    /// (`ArtistPictureSession.store`): a failure is never kept, a found
    /// picture is a photo and the default only when there is none, and only
    /// when `ArtistPhotoTrust` takes it (else it is held for the owner).
    /// Writes the library index, so it is refused while the library is
    /// disconnected. Returns the findings as they were kept
    /// (`ArtistPictureSession.vetted`: a held pick reads as uncertain).
    @MainActor
    @discardableResult
    func storeArtistPictureFindings(_ findings: [ArtistPictureFinding]) async -> [ArtistPictureFinding] {
        let storable = findings.filter(\.outcome.isStorable)
        guard !storable.isEmpty else { return findings }
        guard !refuseWhileLibraryDisconnected() else { return findings }
        let saved = await withArtistProfileStore { store -> ([ArtistPictureFinding], String?) in
            let vetted = ArtistPictureSession.vetted(findings, profiles: store)
            ArtistPictureSession.store(vetted, in: store, now: Date())
            do {
                try store.save()
                return (vetted, nil)
            } catch {
                return (vetted, error.localizedDescription)
            }
        }
        reloadArtistProfiles()
        if let failure = saved.1 {
            appAlert = .error(title: "Artist pictures not saved", message: failure)
        }
        return saved.0
    }

    // MARK: - Writing

    /// The permission check for one run, from the profile and the device as
    /// mounted now. `automatic`: inside a transfer.
    func artistPictureInputs(device: MountedDevice, profile: ExternalDeviceProfile,
                             automatic: Bool) -> ArtistPictureSession.Inputs {
        let preferences = profile.podBoxPreferences
        return ArtistPictureSession.Inputs(
            destination: preferences.artistPictures, automatic: automatic,
            matchedByUUID: isMatchedByUUID(device, profile),
            hasCapability: capabilities(for: device).contains(.centralPeopleArtwork),
            passedM5: preferences.passedChecks.contains(ArtistPictureSession.m5Check))
    }

    /// One planned run of pictures for a device: the plan, and what writing
    /// it needs. Made by `planArtistPictures`, written by `writePlannedPictures`.
    struct PlannedArtistPictures {
        let plan: ArtistPicturePlan
        let artists: [ArtistOnDevice]
        let journal: DeviceWriteJournal
        let policy: DeviceWritePolicy
        let volume: URL
        let uuid: String?
    }

    /// Plans the pictures the planner allows for `device`, each artist's
    /// default photo prepared for the iPod, and, with `findMissing`, first
    /// looks up the names whose profile has no picture and no answer yet
    /// (the owner's library folders, then Deezer; Commons is not used inside
    /// a transfer). Reads only, apart from keeping what a find found. A
    /// disconnected library finds nothing and plans from the profiles as
    /// they are. nil with the reason when the run may not write at all or
    /// the device cannot be read.
    @MainActor
    func planArtistPictures(device: MountedDevice, profile: ExternalDeviceProfile, findMissing: Bool,
                            automatic: Bool) async -> (planned: PlannedArtistPictures?, reason: String?) {
        let permission = ArtistPictureSession.mayWrite(
            artistPictureInputs(device: device, profile: profile, automatic: automatic), trigger: .userAction)
        guard permission.allowed else { return (nil, permission.reason) }
        guard let catalog = await currentDeviceCatalog(for: device) else {
            return (nil, "Artist pictures were not written: \(device.name) could not be read.")
        }

        let volume = device.volumeURL
        let uuid = device.volumeUUID
        let music = musicSubpath(for: profile)
        var inputs = artistPictureInputs(device: device, profile: profile, automatic: automatic)
        let scanned = await Task.detached(priority: .userInitiated) {
            (ArtistOnDevice.all(in: catalog, volumeRoot: volume),
             DeviceArtTree.scan(volumeRoot: volume, musicSubpath: music, catalog: catalog))
        }.value
        inputs.artists = scanned.0
        inputs.tree = scanned.1

        if findMissing, !isLibraryDisconnected {
            let lookup = inputs
            let store = await currentArtistProfileStore()
            let names = await Task.detached(priority: .utility) {
                ArtistPictureSession.namesToFind(lookup, profiles: store, now: Date())
            }.value
            if !names.isEmpty {
                let library = currentTrackStore().allTracks
                let fetcher = artistPictureFetcher
                let findings = await Task.detached(priority: .utility) { () -> [ArtistPictureFinding] in
                    let finder = ArtistPictureFinder(sources: [DeezerArtistSource(fetcher: fetcher)], fetcher: fetcher)
                    let folders = ArtistPictureSession.LibraryFolders(tracks: library)
                    return await finder.find(ArtistPictureSession.requests(for: names, library: folders))
                }.value
                await storeArtistPictureFindings(findings)
            }
        }

        let journal = await Self.sharedJournal(for: profile.id)
        let policy = ArtistPictureSession.picturePolicy(from: devicePolicy(for: profile, firmware: firmware(for: device)))
        let destination = profile.podBoxPreferences.artistPictures
        let planned = inputs
        // After any find above has landed, so its pictures are in the plan.
        let store = await currentArtistProfileStore()
        let plan = await Task.detached(priority: .userInitiated) { () -> ArtistPicturePlan in
            ArtistPicturePlanner.plan(
                artists: planned.artists, tree: planned.tree,
                pictures: ArtistPictureSession.pictures(profiles: store, cache: ArtistPicturePreparedCache()),
                destination: destination,
                ownedKeys: { journal.ownedRecord(forKey: $0, volumeUUID: uuid) },
                sha256OnDevice: ArtistPictureSession.deviceHash(volumeRoot: volume))
        }.value
        return (PlannedArtistPictures(plan: plan, artists: planned.artists, journal: journal, policy: policy,
                                      volume: volume, uuid: uuid), nil)
    }

    /// Writes `operations` (all or part of `planned.plan`) through the door,
    /// one session. A refused plan writes nothing. The caller holds the device busy.
    @MainActor
    func writePlannedPictures(_ planned: PlannedArtistPictures,
                              operations: [DeviceFileOperation]) async -> (written: Int, failed: Int) {
        let session = UUID()
        guard planned.plan.refusal == nil, !operations.isEmpty else { return (0, 0) }
        let outcomes = await Task.detached(priority: .userInitiated) { () -> [DeviceFileOutcome] in
            DeviceFileExecutor(volumeRoot: planned.volume, expectedVolumeUUID: planned.uuid, policy: planned.policy,
                               journal: planned.journal)
                .apply(operations, sessionID: session)
        }.value
        let written = outcomes.filter { $0 == .written }.count
        let unchanged = outcomes.filter { $0 == .unchanged }.count
        logSessionBackups(journal: planned.journal, sessionID: session, what: "Artist pictures")
        return (written, outcomes.count - written - unchanged)
    }

    /// Writes every picture the planner allows for `device` (inside a
    /// transfer: `automatic`, which needs check M5). The caller holds the
    /// device busy. Never throws and never fails the session it is part of:
    /// a problem is the line.
    @MainActor
    func writeArtistPictures(device: MountedDevice, profile: ExternalDeviceProfile, findMissing: Bool,
                             automatic: Bool = true) async -> (written: Int, line: String?) {
        let planning = await planArtistPictures(device: device, profile: profile, findMissing: findMissing,
                                                automatic: automatic)
        guard let planned = planning.planned else { return (0, planning.reason) }
        let result = await writePlannedPictures(planned, operations: planned.plan.operations)
        AppLog.conversion.notice("Artist pictures for \(profile.name, privacy: .private): wrote \(result.written) of \(planned.plan.operations.count), \(result.failed) failed")
        return (result.written, ArtistPictureSession.summaryLine(written: result.written, plan: planned.plan))
    }

    // MARK: - The Artist Pictures sheet

    /// A footer line as an error, so `Result` can carry it.
    struct ArtistPictureLine: Error {
        let text: String
        init(_ text: String) { self.text = text }
    }

    /// What the sheet opens on: the profile's artists from the device's
    /// catalog (walked first when mounted and never scanned; the saved
    /// catalog otherwise), the device's picture tree when it is mounted, and
    /// which of its pictures CrateDigger wrote.
    struct ArtistPicturesContext {
        let profile: ExternalDeviceProfile
        let device: MountedDevice?
        let artists: [ArtistOnDevice]
        let tree: DeviceArtTree
        /// Row id -> device path, for the DEVICE rows whose picture the
        /// journal proves CrateDigger wrote for that person, unchanged since:
        /// the only ones the sheet offers to remove.
        let crateDiggerPictures: [String: String]
    }

    /// Opens the Artist Pictures sheet for a profile, from the root
    /// (`LibraryPresentations`), so it works in the compact player too.
    @MainActor
    func showArtistPictures(profileID: UUID) {
        artistPicturesRequest = profileID
    }

    @MainActor
    func artistPicturesContext(profileID: UUID) async -> ArtistPicturesContext? {
        guard let profile = prefs.savedExternalDeviceProfiles.first(where: { $0.id == profileID }) else { return nil }
        let device = mountedDevice(forProfileID: profileID)
        let catalog: [LoadedTrack]
        if let device {
            catalog = await currentDeviceCatalog(for: device) ?? []
        } else {
            catalog = await storedDeviceCatalog(forProfile: profile) ?? []
        }
        let music = musicSubpath(for: profile)
        let volume = device?.volumeURL
        let uuid = device?.volumeUUID
        let journal = await Self.sharedJournal(for: profileID)
        return await Task.detached(priority: .userInitiated) { () -> ArtistPicturesContext in
            // Offline, the catalog's own root is unknown; its tracks name the
            // volume they were read from, so take that volume's root.
            let root = volume ?? catalog.first.flatMap { Self.volumeRoot(of: $0.track.fileURL) }
                ?? URL(fileURLWithPath: "/Volumes", isDirectory: true)
            let artists = ArtistOnDevice.all(in: catalog, volumeRoot: root)
            let tree = volume.map { DeviceArtTree.scan(volumeRoot: $0, musicSubpath: music, catalog: catalog) }
                ?? DeviceArtTree(peopleFiles: [], coverFiles: [], folderImages: [:], foldersWithAudio: [],
                                 artistsByFolder: [:])
            var ours: [String: String] = [:]
            if let volume {
                let sha = ArtistPictureSession.deviceHash(volumeRoot: volume)
                for artist in artists {
                    guard case .found(let path) = PodBoxArtLookup.artistPicture(
                        for: artist.name, albumFolders: artist.albumFolders, tree: tree),
                          ArtistPicturePlanner.removal(of: path, forArtist: artist.name,
                                                       ownedKeys: { journal.ownedRecord(forKey: $0, volumeUUID: uuid) },
                                                       sha256OnDevice: sha) != nil
                    else { continue }
                    ours[artist.foldedKey.isEmpty ? artist.name : artist.foldedKey] = path
                }
            }
            return ArtistPicturesContext(profile: profile, device: device, artists: artists, tree: tree,
                                         crateDiggerPictures: ours)
        }.value
    }

    /// `/Volumes/<name>` for a path under it.
    nonisolated static func volumeRoot(of url: URL) -> URL? {
        let components = url.standardizedFileURL.pathComponents
        guard components.count > 2, components[1] == "Volumes" else { return nil }
        return URL(fileURLWithPath: "/Volumes/" + components[2], isDirectory: true)
    }

    /// Find Missing, pressed in the sheet: every source (the owner's
    /// library folders, Deezer, Wikimedia Commons), a scan job on DEVICES
    /// with progress, cancelled with the task that runs it. What is found is
    /// stored (never a failure). Returns the findings for the sheet; nil when
    /// the library is disconnected, checked before anything is looked up,
    /// since nothing found could be stored.
    @MainActor
    func findArtistPicturesForSheet(_ artists: [ArtistOnDevice],
                                    onProgress: @escaping @MainActor (Int, Int) -> Void) async -> [ArtistPictureFinding]? {
        guard !artists.isEmpty, !isFindingArtistPictures else { return [] }
        guard !refuseWhileLibraryDisconnected() else { return nil }
        isFindingArtistPictures = true
        let job = beginBusyJob(.scan, on: .devices, labels: BusyLabels(source: "WEB", target: "PICTURES"))
        let library = currentTrackStore().allTracks
        let fetcher = artistPictureFetcher
        let work = Task.detached(priority: .userInitiated) { () -> [ArtistPictureFinding] in
            let finder = ArtistPictureFinder(
                sources: [DeezerArtistSource(fetcher: fetcher), CommonsArtistSource(fetcher: fetcher)],
                fetcher: fetcher, perRun: .seconds(900))
            let folders = ArtistPictureSession.LibraryFolders(tracks: library)
            return await finder.find(ArtistPictureSession.requests(for: artists, library: folders)) { done, total in
                Task { @MainActor [weak self] in
                    self?.reportBusyProgress(job, completed: done, total: total)
                    onProgress(done, total)
                }
            }
        }
        // A detached task does not inherit cancellation: the sheet's Cancel
        // cancels the task awaiting here, which passes it on.
        let findings = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        let cancelled = Task.isCancelled
        // As kept: a pick held for the owner comes back as one to check.
        let kept = await storeArtistPictureFindings(findings)
        endBusyJob(job, cancelled ? .cancelled : .completed)
        isFindingArtistPictures = false
        return kept
    }

    /// What Apply does next, for the sheet.
    enum ArtistPictureApplyStep {
        /// Done: the footer line.
        case finished(String)
        /// Every ready picture is about to be written (M5 passed): ask first.
        case confirm(title: String, message: String)
    }

    /// Apply, pressed in the sheet: the owner's edits go to the artist
    /// profiles (`ArtistPictureRow.apply`: a pick is the artist's default
    /// photo, "Don't Send to iPod" is `notOnIPod`). Then,
    /// when the device is mounted and may take pictures: before check M5 is
    /// marked passed, one picture is written at once
    /// (`ArtistPictureSession.applySelection`); after it, the sheet is asked
    /// to confirm the count first and calls `writeArtistPicturesFromSheet`.
    @MainActor
    func applyArtistPictureEdits(_ edits: [String: ArtistPictureEdit], names: [String: String],
                                 profileID: UUID, changedNames: [String]) async -> ArtistPictureApplyStep {
        if !edits.isEmpty {
            guard !refuseWhileLibraryDisconnected() else {
                return .finished("The library is disconnected, so nothing was saved.")
            }
            let failure = await withArtistProfileStore { store -> String? in
                var refused: String?
                for (key, edit) in edits {
                    do {
                        try ArtistPictureRow.apply(edit, name: names[key] ?? key, to: store)
                    } catch {
                        refused = refused ?? error.localizedDescription
                    }
                }
                // What did apply is kept even when one picture was refused.
                do { try store.save() } catch { return error.localizedDescription }
                return refused
            }
            reloadArtistProfiles()
            if let failure { return .finished("Not every choice was saved: \(failure)") }
        }

        switch artistPictureWriteTarget(profileID: profileID) {
        case .failure(let line):
            return .finished(line.text)
        case .success(let (profile, device)):
            guard profile.podBoxPreferences.passedChecks.contains(ArtistPictureSession.m5Check) else {
                return .finished(await writeArtistPicturesFromSheet(profileID: profileID, changedNames: changedNames))
            }
            // M5 passed: count what would be written, then ask. Held busy
            // while the device is read.
            isWritingArtistPictures = true
            let planning = await planArtistPictures(device: device, profile: profile, findMissing: false,
                                                    automatic: false)
            isWritingArtistPictures = false
            guard let planned = planning.planned else { return .finished(saved(planning.reason)) }
            guard planned.plan.refusal == nil, !planned.plan.operations.isEmpty else {
                return .finished(ArtistPictureSession.summaryLine(written: 0, plan: planned.plan)
                                 ?? "Pictures are saved. Nothing new to write to \(device.name).")
            }
            let text = ArtistPictureSession.applyConfirmation(count: planned.plan.operations.count,
                                                               deviceName: device.name)
            return .confirm(title: text.title, message: text.message)
        }
    }

    /// The footer for saved pictures that were not written, with the reason.
    private func saved(_ reason: String?) -> String {
        ["Pictures are saved.", reason].compactMap { $0 }.joined(separator: " ")
    }

    /// The mounted device the sheet's profile may write pictures to now, or
    /// the footer line saying why not (the real reason, not a guess).
    @MainActor
    private func artistPictureWriteTarget(profileID: UUID)
        -> Result<(ExternalDeviceProfile, MountedDevice), ArtistPictureLine> {
        guard let profile = prefs.savedExternalDeviceProfiles.first(where: { $0.id == profileID }) else {
            return .failure(ArtistPictureLine("This device profile is gone."))
        }
        guard let device = mountedDevice(forProfileID: profileID) else {
            return .failure(ArtistPictureLine(saved("They are written when \(profile.name) is connected.")))
        }
        let permission = ArtistPictureSession.mayWrite(artistPictureInputs(device: device, profile: profile,
                                                                           automatic: false), trigger: .userAction)
        guard permission.allowed else { return .failure(ArtistPictureLine(saved(permission.reason))) }
        guard !isDeviceBusy else {
            showDeviceBusyAlert("Write artist pictures")
            return .failure(ArtistPictureLine(saved("\(device.name) is busy, so nothing was written to it yet.")))
        }
        return .success((profile, device))
    }

    /// Plans again from the device as it is now and writes: every ready
    /// picture once check M5 is marked passed, else at most one
    /// (`ArtistPictureSession.applySelection`). Returns the footer line.
    @MainActor
    func writeArtistPicturesFromSheet(profileID: UUID, changedNames: [String]) async -> String {
        let profile: ExternalDeviceProfile, device: MountedDevice
        switch artistPictureWriteTarget(profileID: profileID) {
        case .failure(let line): return line.text
        case .success(let target): (profile, device) = target
        }
        let passedM5 = profile.podBoxPreferences.passedChecks.contains(ArtistPictureSession.m5Check)
        isWritingArtistPictures = true
        let job = beginBusyJob(.transfer, on: .devices)
        let planning = await planArtistPictures(device: device, profile: profile, findMissing: false, automatic: false)
        guard let planned = planning.planned else {
            endBusyJob(job, .completed)
            isWritingArtistPictures = false
            return saved(planning.reason)
        }
        let selection = ArtistPictureSession.applySelection(planned.plan, artists: planned.artists,
                                                            changedNames: changedNames, passedM5: passedM5)
        let result = await writePlannedPictures(planned, operations: selection.operations)
        endBusyJob(job, result.written == 0 && result.failed > 0 ? .failed : .completed)
        isWritingArtistPictures = false
        AppLog.conversion.notice("Artist pictures from the sheet for \(profile.name, privacy: .private): wrote \(result.written) of \(selection.operations.count), \(result.failed) failed, \(selection.heldBack) held until M5")

        let firmware = firmware(for: device)
        let changes: DeviceWriteChanges = result.written > 0 ? .pictures : []
        noteArtCacheStep(profileID: profileID, device: device, firmware: firmware, changes: changes)
        refreshDeviceNotes(for: device)
        var lines = [ArtistPictureSession.summaryLine(written: result.written, plan: planned.plan)
            ?? "Nothing new to write to \(device.name)."]
        if result.failed > 0 {
            lines.append("\(result.failed) could not be written; the log says why.")
        }
        if !passedM5, !planned.plan.operations.isEmpty {
            lines.append(ArtistPictureSession.oneFirstFooter)
        }
        return (lines + PodBoxNextSteps.after(changes, firmware: firmware)).joined(separator: " ")
    }

    /// Remove from iPod, on a DEVICE row: the one picture CrateDigger wrote
    /// for this artist, proven again by the journal now, deleted through the
    /// door with a copy kept on the Mac. Returns the footer line.
    @MainActor
    func removeArtistPicture(profileID: UUID, name: String, path: String) async -> String {
        guard let profile = prefs.savedExternalDeviceProfiles.first(where: { $0.id == profileID }),
              let device = mountedDevice(forProfileID: profileID) else {
            return "Connect the iPod first."
        }
        guard DeviceSessionGate.allows(.writeExtras, trigger: .userAction, matchedByUUID: isMatchedByUUID(device, profile))
        else { return ArtistPictureSession.needsVolumeID }
        guard !isDeviceBusy else {
            showDeviceBusyAlert("Remove an artist picture")
            return "\(device.name) is busy, so nothing was removed."
        }
        isWritingArtistPictures = true
        let job = beginBusyJob(.transfer, on: .devices)
        let firmware = firmware(for: device)
        let policy = ArtistPictureSession.picturePolicy(from: devicePolicy(for: profile, firmware: firmware))
        let volume = device.volumeURL
        let uuid = device.volumeUUID
        let journal = await Self.sharedJournal(for: profileID)
        let session = UUID()
        let outcome = await Task.detached(priority: .userInitiated) { () -> DeviceFileOutcome? in
            guard let operation = ArtistPicturePlanner.removal(
                of: path, forArtist: name, ownedKeys: { journal.ownedRecord(forKey: $0, volumeUUID: uuid) },
                sha256OnDevice: ArtistPictureSession.deviceHash(volumeRoot: volume)) else { return nil }
            return DeviceFileExecutor(volumeRoot: volume, expectedVolumeUUID: uuid, policy: policy, journal: journal)
                .apply([operation], sessionID: session).first
        }.value
        endBusyJob(job, outcome == .deleted || outcome == .alreadyGone ? .completed : .failed)
        isWritingArtistPictures = false
        logSessionBackups(journal: journal, sessionID: session, what: "Remove from iPod")

        switch outcome {
        case .deleted?:
            noteArtCacheStep(profileID: profileID, device: device, firmware: firmware, changes: .pictures)
            refreshDeviceNotes(for: device)
            return (["Removed the picture of \(name) from \(device.name). A copy is kept on the Mac."]
                    + PodBoxNextSteps.after(.pictures, firmware: firmware)).joined(separator: " ")
        case .alreadyGone?:
            return "The picture of \(name) is no longer on \(device.name)."
        case nil:
            return "The picture of \(name) is not one CrateDigger wrote for this artist, or it was changed on the iPod, so it was left."
        case .failed(let reason)?:
            return "The picture of \(name) was not removed: \(reason)"
        case .refusedWrongVolume?:
            return "\(device.name) is not the iPod this started on, so nothing was removed."
        case .some:
            return "The picture of \(name) was left: CrateDigger could not prove it is still the one it wrote."
        }
    }

    // MARK: - Removal

    /// "Remove artist pictures CrateDigger added": the journal's own picture
    /// files on this volume that are unchanged since they were written,
    /// deleted through the door (a copy kept on the Mac first). The owner
    /// confirmed in Preferences before this runs.
    @MainActor
    func removeArtistPicturesCrateDiggerAdded(profileID: UUID) {
        guard let profile = prefs.savedExternalDeviceProfiles.first(where: { $0.id == profileID }),
              let device = mountedDevice(forProfileID: profileID) else {
            appAlert = .error(title: "Nothing was removed", message: "Connect the iPod first.")
            return
        }
        guard DeviceSessionGate.allows(.writeExtras, trigger: .userAction, matchedByUUID: isMatchedByUUID(device, profile))
        else {
            appAlert = .error(title: "Nothing was removed", message: ArtistPictureSession.needsVolumeID)
            return
        }
        guard !isDeviceBusy else { return showDeviceBusyAlert("Remove artist pictures") }
        isWritingArtistPictures = true
        let job = beginBusyJob(.transfer, on: .devices)
        let firmware = firmware(for: device)
        let policy = ArtistPictureSession.picturePolicy(from: devicePolicy(for: profile, firmware: firmware))
        let volume = device.volumeURL
        let uuid = device.volumeUUID
        let session = UUID()
        Task { @MainActor in
            let journal = await Self.sharedJournal(for: profileID)
            let outcomes = await Task.detached(priority: .userInitiated) { () -> [DeviceFileOutcome] in
                let operations = ArtistPicturePlanner.removalPlan(
                    journalRecords: journal.records, volumeUUID: uuid,
                    sha256OnDevice: ArtistPictureSession.deviceHash(volumeRoot: volume))
                return DeviceFileExecutor(volumeRoot: volume, expectedVolumeUUID: uuid, policy: policy, journal: journal)
                    .apply(operations, sessionID: session)
            }.value
            let removed = outcomes.filter { $0 == .deleted }.count
            let refused = outcomes.count - removed - outcomes.filter { $0 == .alreadyGone }.count
            endBusyJob(job, removed == 0 && refused > 0 ? .failed : .completed)
            isWritingArtistPictures = false
            AppLog.conversion.notice("Removed \(removed) artist picture(s) from \(device.name, privacy: .private), refused \(refused)")
            logSessionBackups(journal: journal, sessionID: session, what: "Remove artist pictures")

            let changes: DeviceWriteChanges = removed > 0 ? .pictures : []
            noteArtCacheStep(profileID: profileID, device: device, firmware: firmware, changes: changes)
            refreshDeviceNotes(for: device)
            var lines = [removed == 1 ? "Removed 1 artist picture CrateDigger added."
                         : "Removed \(removed) artist pictures CrateDigger added."]
            if refused > 0 { lines.append("\(refused) could not be removed and were left.") }
            lines += PodBoxNextSteps.after(changes, firmware: firmware)
            appAlert = AppAlert.actionable(title: "Artist pictures on \(device.name)", message: lines.joined(separator: " "),
                                           actionTitle: "Eject", cancelTitle: "OK") { [weak self] in
                self?.ejectDevice(device)
            }
            .withSecondary(Self.showCopiesTitle, action: showCopiesAction(journal: journal, sessionID: session))
        }
    }

    // MARK: - The art cache reminder

    /// After covers or pictures changed on PodBox: remember when, and what
    /// the player's stamp file looked like then (one `stat`, never opened),
    /// and show "NEXT ON IPOD · UPDATE ART CACHE" until the stamp changes.
    @MainActor
    func noteArtCacheStep(profileID: UUID, device: MountedDevice, firmware: DeviceFirmware?,
                          changes: DeviceWriteChanges) {
        guard ArtistPictureSession.remindsToUpdateArtCache(changes: changes, firmware: firmware) else { return }
        // Always the stamp as it is now: if the player has not rebuilt since
        // an earlier write it is the same stamp, and if it has, the art just
        // written is not in that rebuild.
        let stamp = ArtistPictureSession.artCacheStampModified(volumeRoot: device.volumeURL)
        prefs.setPodBoxArtCacheMark(PodBoxNextSteps.ArtCacheMark(wroteAt: Date(), stampAtWrite: stamp),
                                    profileID: profileID)
        pendingIPodStep[profileID] = ArtistPictureSession.artCacheReminder
    }

    /// On mount: whether each device's player has rebuilt its art cache since
    /// CrateDigger last wrote art there (`PodBoxNextSteps.isDone`: its stamp
    /// file changed). `stamps` were read off the main actor.
    @MainActor
    func refreshArtCacheReminders(stamps: [MountedDevice.ID: Date]) {
        var next: [UUID: String] = [:]
        for device in mountedDevices {
            guard let profile = deviceProfile(for: device),
                  let mark = prefs.podBoxArtCacheMark(profileID: profile.id) else { continue }
            if PodBoxNextSteps.isDone(mark, stampNow: stamps[device.id]) {
                prefs.setPodBoxArtCacheMark(nil, profileID: profile.id)
            } else {
                next[profile.id] = ArtistPictureSession.artCacheReminder
            }
        }
        if next != pendingIPodStep { pendingIPodStep = next }
    }

    // MARK: - Readiness notes

    /// The readiness notes for `device`, worked out off the main actor from
    /// the catalog already known (never a fresh walk) and the probe. Read-only.
    @MainActor
    func refreshDeviceNotes(for device: MountedDevice) {
        guard let firmware = firmware(for: device), let profile = deviceProfile(for: device) else {
            if deviceNotes[device.id] != nil { deviceNotes[device.id] = nil }
            return
        }
        let volume = device.volumeURL
        let music = musicSubpath(for: profile)
        Task { @MainActor in
            let catalog = await knownDeviceCatalog(for: device) ?? []
            let notes = await Task.detached(priority: .utility) {
                PodBoxAdvisor.deviceNotes(catalog: catalog, firmware: firmware, musicSubpath: music, volumeRoot: volume)
            }.value
            guard mountedDevices.contains(where: { $0.id == device.id }) else { return }
            if deviceNotes[device.id] != notes { deviceNotes[device.id] = notes }
        }
    }
}
