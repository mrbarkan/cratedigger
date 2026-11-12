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
    // MARK: - The store

    /// The picture records for the current crates folder, rebuilt when the
    /// folder changes (a library move, a disconnect onto the copy).
    func currentArtistPictureStore() -> ArtistPictureStore {
        let folder = cratesDirectoryURL
        if let store = artistPictureStore, artistPictureStoreFolder?.path == folder.path { return store }
        let store = ArtistPictureStore(indexDirectory: folder)
        artistPictureStore = store
        artistPictureStoreFolder = folder
        return store
    }

    /// Stores what the finder concluded: only storable findings (a failure
    /// is asked again next time, never trusted as "not found"), each with its
    /// source and credit. Writes the library index, so it is refused while
    /// the library is disconnected. Returns how many records changed.
    @MainActor
    @discardableResult
    func storeArtistPictureFindings(_ findings: [ArtistPictureFinding]) async -> Int {
        let storable = findings.filter(\.outcome.isStorable)
        guard !storable.isEmpty else { return 0 }
        guard !refuseWhileLibraryDisconnected() else { return 0 }
        let store = currentArtistPictureStore()
        let saved = await Task.detached(priority: .utility) { () -> (Int, String?) in
            var count = 0
            for finding in storable {
                guard let (record, prepared) = ArtistPictureSession.record(from: finding, now: Date()) else { continue }
                do {
                    try store.set(record, prepared: prepared)
                    count += 1
                } catch {
                    AppLog.library.error("Artist picture for \(finding.name, privacy: .public) not stored: \(error.localizedDescription, privacy: .public)")
                }
            }
            do {
                try store.save()
                return (count, nil)
            } catch {
                return (count, error.localizedDescription)
            }
        }.value
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

    /// Writes the pictures the planner allows for `device`, and, with
    /// `findMissing`, first looks up the names the store has no answer for
    /// (the owner's library folders, then Deezer; Commons is not used inside
    /// a transfer). The caller holds the device busy. A disconnected library
    /// finds nothing and writes what the store already holds. Never throws
    /// and never fails the session it is part of: a problem is the line.
    @MainActor
    func writeArtistPictures(device: MountedDevice, profile: ExternalDeviceProfile, findMissing: Bool,
                             automatic: Bool = true) async -> (written: Int, line: String?) {
        let permission = ArtistPictureSession.mayWrite(
            artistPictureInputs(device: device, profile: profile, automatic: automatic), trigger: .userAction)
        guard permission.allowed else { return (0, permission.reason) }
        guard let catalog = await currentDeviceCatalog(for: device) else {
            return (0, "Artist pictures were not written: \(device.name) could not be read.")
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

        let store = currentArtistPictureStore()
        if findMissing, !isLibraryDisconnected {
            let lookup = inputs
            let names = await Task.detached(priority: .utility) {
                ArtistPictureSession.namesToFind(lookup, store: store, now: Date())
            }.value
            if !names.isEmpty {
                let library = currentTrackStore().allTracks
                let findings = await Task.detached(priority: .utility) { () -> [ArtistPictureFinding] in
                    let fetcher = URLSessionPictureFetcher()
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
        let result = await Task.detached(priority: .userInitiated) { () -> (written: Int, plan: ArtistPicturePlan) in
            let plan = ArtistPicturePlanner.plan(
                artists: planned.artists, tree: planned.tree,
                prepared: ArtistPictureSession.prepared(for: planned.artists, store: store),
                destination: destination,
                ownedKeys: { journal.ownedRecord(forKey: $0, volumeUUID: uuid) },
                sha256OnDevice: ArtistPictureSession.deviceHash(volumeRoot: volume))
            // A refused plan writes nothing; its refusal is the line.
            guard plan.refusal == nil, !plan.operations.isEmpty else { return (0, plan) }
            let outcomes = DeviceFileExecutor(volumeRoot: volume, expectedVolumeUUID: uuid, policy: policy,
                                              journal: journal)
                .apply(plan.operations, sessionID: UUID())
            return (outcomes.filter { $0 == .written }.count, plan)
        }.value
        AppLog.conversion.notice("Artist pictures for \(profile.name, privacy: .public): wrote \(result.written) of \(result.plan.operations.count)")
        return (result.written, ArtistPictureSession.summaryLine(written: result.written, plan: result.plan))
    }

    // MARK: - The Artist Pictures sheet

    /// What the sheet opens on: the profile's artists from the device's
    /// catalog (walked first when mounted and never scanned; the saved
    /// catalog otherwise), and the device's picture tree when it is mounted.
    struct ArtistPicturesContext {
        let profile: ExternalDeviceProfile
        let device: MountedDevice?
        let artists: [ArtistOnDevice]
        let tree: DeviceArtTree
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
        return await Task.detached(priority: .userInitiated) { () -> ArtistPicturesContext in
            // Offline, the catalog's own root is unknown; its tracks name the
            // volume they were read from, so take that volume's root.
            let root = volume ?? catalog.first.flatMap { Self.volumeRoot(of: $0.track.fileURL) }
                ?? URL(fileURLWithPath: "/Volumes", isDirectory: true)
            let artists = ArtistOnDevice.all(in: catalog, volumeRoot: root)
            let tree = volume.map { DeviceArtTree.scan(volumeRoot: $0, musicSubpath: music, catalog: catalog) }
                ?? DeviceArtTree(peopleFiles: [], coverFiles: [], folderImages: [:], foldersWithAudio: [],
                                 artistsByFolder: [:])
            return ArtistPicturesContext(profile: profile, device: device, artists: artists, tree: tree)
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
    /// stored (never a failure). Returns the findings for the sheet.
    @MainActor
    func findArtistPicturesForSheet(_ artists: [ArtistOnDevice],
                                    onProgress: @escaping @MainActor (Int, Int) -> Void) async -> [ArtistPictureFinding] {
        guard !artists.isEmpty, !isFindingArtistPictures else { return [] }
        isFindingArtistPictures = true
        let job = beginBusyJob(.scan, on: .devices, labels: BusyLabels(source: "WEB", target: "PICTURES"))
        let library = currentTrackStore().allTracks
        let work = Task.detached(priority: .userInitiated) { () -> [ArtistPictureFinding] in
            let fetcher = URLSessionPictureFetcher()
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
        await storeArtistPictureFindings(findings)
        endBusyJob(job, cancelled ? .cancelled : .completed)
        isFindingArtistPictures = false
        return findings
    }

    /// Apply, pressed in the sheet: the owner's edits go to the store, and
    /// then, when the device is mounted, matched by its volume UUID and has
    /// artist pictures on, the ready pictures go to the device through the
    /// door. Returns the sheet's footer line.
    @MainActor
    func applyArtistPictureEdits(_ edits: [String: ArtistPictureEdit], names: [String: String],
                                 profileID: UUID) async -> String {
        if !edits.isEmpty {
            guard !refuseWhileLibraryDisconnected() else {
                return "The library is disconnected, so nothing was saved."
            }
            let store = currentArtistPictureStore()
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                for (key, edit) in edits {
                    let name = names[key] ?? key
                    if let (record, prepared) = ArtistPictureRow.record(for: edit, name: name, now: Date()) {
                        do { try store.set(record, prepared: prepared) } catch { return error.localizedDescription }
                    } else {
                        store.remove(forName: name)
                    }
                }
                do { try store.save() } catch { return error.localizedDescription }
                return nil
            }.value
            if let failure { return "Nothing was saved: \(failure)" }
        }

        let saved = "Pictures are saved and will be written when artist pictures are on for this device."
        guard let profile = prefs.savedExternalDeviceProfiles.first(where: { $0.id == profileID }),
              let device = mountedDevice(forProfileID: profileID),
              ArtistPictureSession.mayWrite(artistPictureInputs(device: device, profile: profile, automatic: false),
                                            trigger: .userAction).allowed
        else { return saved }
        guard !isDeviceBusy else {
            showDeviceBusyAlert("Write artist pictures")
            return "Pictures are saved. \(device.name) is busy, so nothing was written to it yet."
        }
        isWritingArtistPictures = true
        let job = beginBusyJob(.transfer, on: .devices)
        let result = await writeArtistPictures(device: device, profile: profile, findMissing: false, automatic: false)
        endBusyJob(job, .completed)
        isWritingArtistPictures = false
        let firmware = firmware(for: device)
        let changes: DeviceWriteChanges = result.written > 0 ? .pictures : []
        noteArtCacheStep(profileID: profileID, firmware: firmware, changes: changes)
        refreshDeviceNotes(for: device)
        let line = result.line ?? "Nothing new to write to \(device.name)."
        return ([line] + PodBoxNextSteps.after(changes, firmware: firmware)).joined(separator: " ")
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
        Task { @MainActor in
            let journal = await Self.sharedJournal(for: profileID)
            let outcomes = await Task.detached(priority: .userInitiated) { () -> [DeviceFileOutcome] in
                let operations = ArtistPicturePlanner.removalPlan(
                    journalRecords: journal.records, volumeUUID: uuid,
                    sha256OnDevice: ArtistPictureSession.deviceHash(volumeRoot: volume))
                return DeviceFileExecutor(volumeRoot: volume, expectedVolumeUUID: uuid, policy: policy, journal: journal)
                    .apply(operations, sessionID: UUID())
            }.value
            let removed = outcomes.filter { $0 == .deleted }.count
            let refused = outcomes.count - removed - outcomes.filter { $0 == .alreadyGone }.count
            endBusyJob(job, removed == 0 && refused > 0 ? .failed : .completed)
            isWritingArtistPictures = false
            AppLog.conversion.notice("Removed \(removed) artist picture(s) from \(device.name, privacy: .public), refused \(refused)")

            let changes: DeviceWriteChanges = removed > 0 ? .pictures : []
            noteArtCacheStep(profileID: profileID, firmware: firmware, changes: changes)
            refreshDeviceNotes(for: device)
            var lines = [removed == 1 ? "Removed 1 artist picture CrateDigger added."
                         : "Removed \(removed) artist pictures CrateDigger added."]
            if refused > 0 { lines.append("\(refused) could not be removed and were left.") }
            lines += PodBoxNextSteps.after(changes, firmware: firmware)
            appAlert = .actionable(title: "Artist pictures on \(device.name)", message: lines.joined(separator: " "),
                                   actionTitle: "Eject", cancelTitle: "OK") { [weak self] in
                self?.ejectDevice(device)
            }
        }
    }

    // MARK: - The art cache reminder

    /// After covers or pictures changed on PodBox: remember when, and show
    /// "NEXT ON IPOD · UPDATE ART CACHE" until the player has rebuilt its cache.
    @MainActor
    func noteArtCacheStep(profileID: UUID, firmware: DeviceFirmware?, changes: DeviceWriteChanges) {
        guard ArtistPictureSession.remindsToUpdateArtCache(changes: changes, firmware: firmware) else { return }
        prefs.setPodBoxLastArtWrite(Date(), profileID: profileID)
        pendingIPodStep[profileID] = ArtistPictureSession.artCacheReminder
    }

    /// On mount: whether each device's player has rebuilt its art cache since
    /// CrateDigger last wrote art there (`PodBoxNextSteps.isDone` on a `stat`
    /// of its stamp file). `stamps` were read off the main actor.
    @MainActor
    func refreshArtCacheReminders(stamps: [MountedDevice.ID: Date]) {
        var next: [UUID: String] = [:]
        for device in mountedDevices {
            guard let profile = deviceProfile(for: device),
                  let lastWrite = prefs.podBoxLastArtWrite(profileID: profile.id) else { continue }
            if PodBoxNextSteps.isDone(lastWrite: lastWrite, playerFileModified: stamps[device.id]) {
                prefs.setPodBoxLastArtWrite(nil, profileID: profile.id)
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
