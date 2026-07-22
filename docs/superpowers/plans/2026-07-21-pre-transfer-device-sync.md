# Pre-Transfer to Device ("Sync") Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Queue tracks for a saved external-device profile while the device is unplugged (conversions pre-baked into a local staging tree), then land everything with one manual SYNC when it mounts. Plus: collapsible Sources section headers.

**Architecture:** New Core store (`DeviceSyncQueueStore`) persists per-profile queue JSON + a staging tree that mirrors the device's final layout. `transferToDevice` becomes offline-aware: unplugged → bake into staging via the existing planner + conversion pipeline (Cnvrt OLED). Sync = copy-if-absent loop (DEV OLED), deleting each staged file the moment its copy lands. Sidebar always lists all saved profiles; offline ones browse cached catalog + queue.

**Tech Stack:** Swift 5 / SwiftPM, XCTest via `scripts/test.sh`, AppKit+SwiftUI (Carbon design system), FFmpeg via `ConversionService`.

**Spec:** `docs/superpowers/specs/2026-07-21-pre-transfer-device-sync-design.md`

## Global Constraints

- Work on the current branch `beta/1.1.0-theming`.
- Run tests with `scripts/test.sh --filter <TestClass>` — never bare `swift test`.
- New testable logic goes in `CrateDiggerCore`; UI glue in `CrateDiggerApp`.
- No Material fills in Carbon surfaces (project invariant).
- "No trash": staged bytes exist only for actual conversions; every staged file is deleted the moment it's copied (or its entry removed); empty dirs pruned; orphaned staging swept at launch.
- Copy-mode profiles never stage bytes locally.
- Sync is manual only — never auto-start on mount.
- Alert enum note: `appAlert = .error(...)` is used even for info in old code, but `.info(title:message:)` exists — use `.info` for non-errors.

---

### Task 1: Core — `DeviceSyncQueueEntry` + `DeviceSyncQueueStore` (TDD)

**Files:**
- Create: `Sources/CrateDiggerCore/Models/DeviceSyncQueueEntry.swift`
- Create: `Sources/CrateDiggerCore/Services/DeviceSyncQueueStore.swift`
- Test: `Tests/CrateDiggerCoreTests/DeviceSyncQueueStoreTests.swift`

**Interfaces:**
- Consumes: `LoadedTrack` (Codable, from `LibraryScanService.swift`/`ConversionModels.swift`).
- Produces (later tasks call these exactly):
  - `DeviceSyncQueueEntry(id:track:destinationRelativePath:isStaged:sourceModifiedAt:queuedAt:)`
  - `DeviceSyncQueueStore.init(directory: URL? = nil, fileManager: FileManager = .default)`
  - `load(profileID: UUID) -> [DeviceSyncQueueEntry]`
  - `save(_ entries: [DeviceSyncQueueEntry], profileID: UUID)`
  - `remove(profileID: UUID)` — deletes queue JSON **and** the staging tree
  - `stagingDirectory(for profileID: UUID) -> URL`
  - `stagedFileURL(for entry: DeviceSyncQueueEntry, profileID: UUID) -> URL`
  - `removeStagedFile(for entry: DeviceSyncQueueEntry, profileID: UUID)` — prunes empty parent dirs up to the staging root
  - `sweepOrphans(validProfileIDs: Set<UUID>)`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CrateDiggerCoreTests/DeviceSyncQueueStoreTests.swift`:

```swift
import XCTest
@testable import CrateDiggerCore

final class DeviceSyncQueueStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: DeviceSyncQueueStore!
    private let profileID = UUID()

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cd-syncqueue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = DeviceSyncQueueStore(directory: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testRoundTrip() {
        let entry = makeEntry(relativePath: "Music/Artist/Album/01 Song.m4a")
        store.save([entry], profileID: profileID)
        let loaded = store.load(profileID: profileID)
        XCTAssertEqual(loaded, [entry])
    }

    func testLoadMissingProfileReturnsEmpty() {
        XCTAssertEqual(store.load(profileID: UUID()), [])
    }

    func testRemoveDeletesQueueAndStagingTree() throws {
        let entry = makeEntry(relativePath: "Music/A/01.m4a")
        store.save([entry], profileID: profileID)
        let staged = store.stagedFileURL(for: entry, profileID: profileID)
        try FileManager.default.createDirectory(
            at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: staged)

        store.remove(profileID: profileID)

        XCTAssertEqual(store.load(profileID: profileID), [])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.stagingDirectory(for: profileID).path))
    }

    func testRemoveStagedFilePrunesEmptyParents() throws {
        let entry = makeEntry(relativePath: "Music/Artist/Album/01 Song.m4a")
        let staged = store.stagedFileURL(for: entry, profileID: profileID)
        try FileManager.default.createDirectory(
            at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: staged)
        // A sibling file elsewhere in staging must survive the prune.
        let sibling = makeEntry(relativePath: "Music/Other/02.m4a")
        let siblingURL = store.stagedFileURL(for: sibling, profileID: profileID)
        try FileManager.default.createDirectory(
            at: siblingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("y".utf8).write(to: siblingURL)

        store.removeStagedFile(for: entry, profileID: profileID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        // Emptied Album + Artist dirs pruned…
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: staged.deletingLastPathComponent().path))
        // …but the sibling and its branch survive.
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingURL.path))
    }

    func testSweepOrphansDeletesOnlyUnknownProfiles() throws {
        let keepID = UUID(), orphanID = UUID()
        store.save([makeEntry(relativePath: "a.m4a")], profileID: keepID)
        store.save([makeEntry(relativePath: "b.m4a")], profileID: orphanID)
        try FileManager.default.createDirectory(
            at: store.stagingDirectory(for: orphanID), withIntermediateDirectories: true)

        store.sweepOrphans(validProfileIDs: [keepID])

        XCTAssertEqual(store.load(profileID: keepID).count, 1)
        XCTAssertEqual(store.load(profileID: orphanID), [])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.stagingDirectory(for: orphanID).path))
    }

    private func makeEntry(relativePath: String) -> DeviceSyncQueueEntry {
        let url = URL(fileURLWithPath: "/tmp/source/\(relativePath)")
        let track = AudioTrack(
            fileURL: url,
            title: url.deletingPathExtension().lastPathComponent,
            artist: "Artist",
            album: "Album"
        )
        let metadata = ConversionMetadata(
            artist: "Artist", albumArtist: "Artist", album: "Album", year: 2001)
        return DeviceSyncQueueEntry(
            id: UUID(),
            track: LoadedTrack(track: track, metadata: metadata),
            destinationRelativePath: relativePath,
            isStaged: true,
            sourceModifiedAt: Date(timeIntervalSince1970: 1_000_000),
            queuedAt: Date(timeIntervalSince1970: 2_000_000)
        )
    }
}
```

Note: if `AudioTrack`/`ConversionMetadata` initializers reject these arguments, copy the exact fixture shape from `Tests/CrateDiggerCoreTests/OutputPathPlannerTests.swift` (`makeLoadedTrack`, line ~177) — it is the canonical fixture.

- [ ] **Step 2: Run tests to verify they fail to compile**

Run: `scripts/test.sh --filter DeviceSyncQueueStoreTests`
Expected: build error — `DeviceSyncQueueEntry`/`DeviceSyncQueueStore` not found.

- [ ] **Step 3: Implement the model**

Create `Sources/CrateDiggerCore/Models/DeviceSyncQueueEntry.swift`:

```swift
import Foundation

/// One track waiting to be synced onto an external device: what to put where.
/// The staging tree mirrors the device layout, so a baked entry's local file is
/// always `<staging dir>/<destinationRelativePath>` — no second path field.
public struct DeviceSyncQueueEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// The queued track (source file + editable tags). Artwork rides along by
    /// hash, not bytes, so persisted queues stay small.
    public var track: LoadedTrack
    /// Path relative to the device *mount root* (includes the profile's music
    /// subpath, e.g. "Music/Artist/2001 Album/01 Song.m4a").
    public var destinationRelativePath: String
    /// true = a pre-baked conversion exists in the staging tree. false =
    /// copy-mode: sync copies the original source file directly, nothing is
    /// ever staged locally.
    public var isStaged: Bool
    /// Source file mtime captured at bake time — the staleness guard.
    public var sourceModifiedAt: Date
    public var queuedAt: Date

    public init(
        id: UUID = UUID(),
        track: LoadedTrack,
        destinationRelativePath: String,
        isStaged: Bool,
        sourceModifiedAt: Date,
        queuedAt: Date = Date()
    ) {
        self.id = id
        self.track = track
        self.destinationRelativePath = destinationRelativePath
        self.isStaged = isStaged
        self.sourceModifiedAt = sourceModifiedAt
        self.queuedAt = queuedAt
    }
}
```

- [ ] **Step 4: Implement the store**

Create `Sources/CrateDiggerCore/Services/DeviceSyncQueueStore.swift` (mirror the shape of `DeviceCatalogStore.swift`):

```swift
import Foundation

/// Persists per-device-profile sync queues (JSON) and manages their staging
/// trees (pre-baked conversions laid out exactly as they'll land on the
/// device). Queue: `<base>/DeviceSyncQueues/<profileID>.json`. Staging:
/// `<base>/DeviceStaging/<profileID>/…`. Deleting is aggressive by design —
/// staged bytes must never outlive their purpose.
public struct DeviceSyncQueueStore {
    private let queuesDirectory: URL
    private let stagingBaseDirectory: URL
    private let fileManager: FileManager

    public init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base: URL
        if let directory {
            base = directory
        } else {
            base = (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory()))
                .appendingPathComponent("CrateDigger", isDirectory: true)
        }
        self.queuesDirectory = base.appendingPathComponent("DeviceSyncQueues", isDirectory: true)
        self.stagingBaseDirectory = base.appendingPathComponent("DeviceStaging", isDirectory: true)
    }

    public func load(profileID: UUID) -> [DeviceSyncQueueEntry] {
        guard let data = try? Data(contentsOf: queueURL(for: profileID)) else { return [] }
        return (try? JSONDecoder().decode([DeviceSyncQueueEntry].self, from: data)) ?? []
    }

    public func save(_ entries: [DeviceSyncQueueEntry], profileID: UUID) {
        try? fileManager.createDirectory(at: queuesDirectory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: queueURL(for: profileID), options: .atomic)
    }

    /// Drop the whole queue: JSON + entire staging tree.
    public func remove(profileID: UUID) {
        try? fileManager.removeItem(at: queueURL(for: profileID))
        try? fileManager.removeItem(at: stagingDirectory(for: profileID))
    }

    public func stagingDirectory(for profileID: UUID) -> URL {
        stagingBaseDirectory.appendingPathComponent(profileID.uuidString, isDirectory: true)
    }

    public func stagedFileURL(for entry: DeviceSyncQueueEntry, profileID: UUID) -> URL {
        stagingDirectory(for: profileID).appendingPathComponent(entry.destinationRelativePath)
    }

    /// Delete one staged file and prune now-empty parent directories up to
    /// (but not including) the profile's staging root.
    public func removeStagedFile(for entry: DeviceSyncQueueEntry, profileID: UUID) {
        let root = stagingDirectory(for: profileID).standardizedFileURL
        let file = stagedFileURL(for: entry, profileID: profileID)
        try? fileManager.removeItem(at: file)
        var dir = file.deletingLastPathComponent().standardizedFileURL
        while dir.path.hasPrefix(root.path), dir.path != root.path {
            let contents = (try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? []
            guard contents.isEmpty else { break }
            try? fileManager.removeItem(at: dir)
            dir = dir.deletingLastPathComponent().standardizedFileURL
        }
    }

    /// Launch-time trash guard: delete queues + staging for profiles that no
    /// longer exist.
    public func sweepOrphans(validProfileIDs: Set<UUID>) {
        let valid = Set(validProfileIDs.map { $0.uuidString.lowercased() })
        for url in (try? fileManager.contentsOfDirectory(
            at: queuesDirectory, includingPropertiesForKeys: nil)) ?? [] {
            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            if !valid.contains(stem) { try? fileManager.removeItem(at: url) }
        }
        for url in (try? fileManager.contentsOfDirectory(
            at: stagingBaseDirectory, includingPropertiesForKeys: nil)) ?? [] {
            if !valid.contains(url.lastPathComponent.lowercased()) {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func queueURL(for profileID: UUID) -> URL {
        queuesDirectory.appendingPathComponent(profileID.uuidString)
            .appendingPathExtension("json")
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `scripts/test.sh --filter DeviceSyncQueueStoreTests`
Expected: all 5 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/CrateDiggerCore/Models/DeviceSyncQueueEntry.swift \
        Sources/CrateDiggerCore/Services/DeviceSyncQueueStore.swift \
        Tests/CrateDiggerCoreTests/DeviceSyncQueueStoreTests.swift
git commit -m "feat(core): DeviceSyncQueueEntry + DeviceSyncQueueStore for pre-transfer sync queues"
```

---

### Task 2: Offline devices in Sources (enum case, selection, sidebar rows)

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift` (enum ~line 62, published state ~line 110, devices section ~line 1339)
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Main/SourcesSidebar.swift` (devices section, lines 192–203)

**Interfaces:**
- Consumes: Task 1's `DeviceSyncQueueStore`.
- Produces (later tasks call these exactly):
  - `LibrarySource.offlineDevice(profileID: UUID)`
  - `LibraryViewModel.syncQueueStore: DeviceSyncQueueStore` (internal `let`)
  - `LibraryViewModel.syncQueueCounts: [UUID: Int]` (`@Published private(set)`)
  - `LibraryViewModel.refreshSyncQueueCounts()`
  - `LibraryViewModel.offlineDeviceProfiles: [ExternalDeviceProfile]`
  - `LibraryViewModel.pendingSyncTrackIDs: Set<UUID>` (`@Published private(set)`)
  - `LibraryViewModel.invalidateDeviceCatalog(for device: MountedDevice)`
  - `LibraryViewModel.catalogKey(for profile: ExternalDeviceProfile) -> String`

- [ ] **Step 1: Add the enum case**

In `LibraryViewModel.swift`, `LibrarySource` (line ~62), after `case device(volumePath: String)`:

```swift
    /// A saved device profile whose volume is NOT currently mounted — browses
    /// the cached catalog from its last mount plus any queued-for-sync tracks.
    case offlineDevice(profileID: UUID)
```

- [ ] **Step 2: Add state + helpers to `LibraryViewModel`**

In the class body near the device properties (search `deviceIndexCache`):

```swift
    let syncQueueStore = DeviceSyncQueueStore()
    /// Per-profile queued-track counts for sidebar badges. Refreshed on queue
    /// mutations — never read the store from view bodies.
    @Published private(set) var syncQueueCounts: [UUID: Int] = [:]
    /// Track IDs pending sync for the offline device being browsed (PENDING badges).
    @Published private(set) var pendingSyncTrackIDs: Set<UUID> = []

    func refreshSyncQueueCounts() {
        var counts: [UUID: Int] = [:]
        for profile in prefs.savedExternalDeviceProfiles {
            let n = syncQueueStore.load(profileID: profile.id).count
            if n > 0 { counts[profile.id] = n }
        }
        syncQueueCounts = counts
    }

    /// Saved profiles with no mounted volume right now — shown dimmed in Sources.
    var offlineDeviceProfiles: [ExternalDeviceProfile] {
        let mountedIDs = Set(mountedDevices.compactMap { deviceProfile(for: $0)?.id })
        return prefs.savedExternalDeviceProfiles.filter { !mountedIDs.contains($0.id) }
    }

    /// Same key a mounted scan saves the catalog under (see MountedDevice.catalogKey).
    func catalogKey(for profile: ExternalDeviceProfile) -> String {
        profile.volumeUUID ?? profile.name
    }

    /// Post-sync: force the next browse of this device to re-walk the volume.
    func invalidateDeviceCatalog(for device: MountedDevice) {
        deviceIndexCache[device.volumeURL.path] = nil
        deviceCatalogStore.remove(key: device.catalogKey)
    }
```

- [ ] **Step 3: Selection + mount/unmount handoff**

Find the `switch` in `selectSource(_:)` (the `case .device(let path): selectDevice(volumePath: path)` arm, ~line 1084) and add the sibling arm:

```swift
        case .offlineDevice(let profileID):
            selectOfflineDevice(profileID: profileID)
```

Next to `selectDevice` (~line 1394) add:

```swift
    /// Browse an unplugged device: last-known catalog + queued tracks, so you
    /// can see (and stage) what the device WILL contain.
    private func selectOfflineDevice(profileID: UUID) {
        guard let profile = prefs.savedExternalDeviceProfiles.first(where: { $0.id == profileID }) else {
            index = .empty
            return
        }
        let cached = deviceCatalogStore.load(key: catalogKey(for: profile)) ?? []
        let entries = syncQueueStore.load(profileID: profileID)
        let cachedPaths = Set(cached.map { $0.track.fileURL.path })
        let queued = entries.map(\.track).filter { !cachedPaths.contains($0.track.fileURL.path) }
        pendingSyncTrackIDs = Set(queued.map { $0.track.id })
        adoptDeviceIndex(buildIndex(cached + queued))
        oledView = .devices
    }
```

(If `buildIndex`/`adoptDeviceIndex` are `private`, this compiles because `selectOfflineDevice` lives in the same file.)

In `refreshDevices()` (line ~1343), after the existing `.device` unplug fallback, add the mount handoff:

```swift
        // If the offline profile we're browsing just mounted, jump to the live view.
        if case .offlineDevice(let pid) = currentSource,
           let dev = detected.first(where: { deviceProfile(for: $0)?.id == pid }) {
            selectSource(.device(volumePath: dev.volumeURL.path))
        }
```

And in the same method change the unplug fallback so browsing a yanked device lands on its offline view when we can identify the profile (keep `.localAll` when we can't):

```swift
        if case .device(let path) = currentSource,
           !detected.contains(where: { $0.volumeURL.path == path }) {
            if let profile = prefs.savedExternalDeviceProfiles.first(where: { $0.rootDisplayPath == path }) {
                selectSource(.offlineDevice(profileID: profile.id))
            } else {
                selectSource(.localAll)
            }
        }
```

- [ ] **Step 4: Call `refreshSyncQueueCounts()` at startup**

In `LibraryViewModel`'s `init`, alongside other setup (search `refreshDevices()` or the init body), add:

```swift
        refreshSyncQueueCounts()
```

- [ ] **Step 5: Sidebar — always show all profiles**

In `SourcesSidebar.swift` replace the devices section (lines 192–203) with:

```swift
                    if !model.mountedDevices.isEmpty || !model.offlineDeviceProfiles.isEmpty {
                        sectionHeader("Devices", trailing: "")
                        ForEach(model.mountedDevices) { device in
                            sidebarItem(
                                icon: deviceIcon(for: device),
                                title: device.name,
                                count: isSelectedDevice(device.volumeURL.path) ? "\(model.index.allTracks.count)" : "—",
                                selected: isSelectedDevice(device.volumeURL.path),
                                action: { model.selectSource(.device(volumePath: device.volumeURL.path)) }
                            )
                        }
                        ForEach(model.offlineDeviceProfiles) { profile in
                            sidebarItem(
                                icon: offlineDeviceIcon(for: profile),
                                title: profile.name,
                                count: model.syncQueueCounts[profile.id].map { "\($0) queued" } ?? "—",
                                selected: isSelectedOfflineDevice(profile.id),
                                action: { model.selectSource(.offlineDevice(profileID: profile.id)) }
                            )
                            .opacity(0.55)
                        }
                    }
```

Add the two helpers next to `isSelectedDevice` / `deviceIcon`:

```swift
    private func isSelectedOfflineDevice(_ id: UUID) -> Bool {
        if case .offlineDevice(let current) = model.currentSource {
            return current == id
        }
        return false
    }

    private func offlineDeviceIcon(for profile: ExternalDeviceProfile) -> Image {
        if let nsImage = DeviceSystemIcons.image(for: profile.iconID) {
            return DeviceSystemIcons.sidebarImage(nsImage, points: 16)
        }
        return Image(systemName: "externaldrive")
    }
```

- [ ] **Step 6: Fix exhaustive switches**

Run: `swift build`
Expected: errors listing every `switch` over `LibrarySource` missing the new case (e.g. source labels, playback wiring). For each, mirror what `.device` does; for display strings use the profile name (`prefs.savedExternalDeviceProfiles.first { $0.id == profileID }?.name ?? "Device"`). Re-run `swift build` until clean.

- [ ] **Step 7: Commit**

```bash
git add -A Sources/CrateDiggerApp
git commit -m "feat(devices): offline device profiles in Sources — cached catalog + queue browsing"
```

---

### Task 3: Offline-aware transfer → bake into staging

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/ExternalDevices/LibraryViewModel+ExternalDeviceTransfer.swift` (offline branch in `transferToDevice`, line ~50)
- Modify: `Sources/CrateDiggerApp/UI/Conversion/LibraryViewModel+Conversion.swift` (`runConversionQueue` return type, line ~558; its one caller, line ~136)
- Create: `Sources/CrateDiggerApp/UI/ExternalDevices/LibraryViewModel+DeviceSync.swift`

**Interfaces:**
- Consumes: `DeviceSyncQueueStore` (Task 1), `syncQueueStore`/`refreshSyncQueueCounts`/`pendingSyncTrackIDs` (Task 2), existing `ExternalDeviceTransferPlanner.planTransfers(tracks:profile:mountedAt:reviewedAlbumFolders:reservedDestinationPaths:)`, `runConversionQueue`, `tracksWithHydratedArtwork`, `probeFreeDiskSpace`, `customFFmpegExecutableURL`, `presentSummary`, `ConversionPreset.genericAAC`.
- Produces:
  - `ConversionQueueOutcome { report: ConversionReport; succeededDestinationPaths: Set<String> }`
  - `LibraryViewModel.stageForSync(profile:tracks:presentingFrom:)`
  - `LibraryViewModel.modificationDate(of: URL) -> Date` (static, on the extension)

- [ ] **Step 1: Make `runConversionQueue` report which jobs succeeded**

In `LibraryViewModel+Conversion.swift`, add above `runConversionQueue`:

```swift
struct ConversionQueueOutcome {
    let report: ConversionReport
    /// Destination paths of jobs that completed — lets staging record exactly
    /// which bakes are real.
    let succeededDestinationPaths: Set<String>
}
```

Change the signature `async -> ConversionReport` → `async -> ConversionQueueOutcome`. Inside the detached task, the continuation currently resumes with `outcomes`; widen it to also carry succeeded destinations, computed from the `queued` array already in scope:

```swift
                let succeededIDs = Set(outcomes.filter { $0.status == .completed }.map(\.queuedID))
                let succeededPaths = Set(queued.filter { succeededIDs.contains($0.id) }
                    .map { $0.job.destinationURL.path })
                continuation.resume(returning: (outcomes, succeededPaths))
```

(Adjust the `withCheckedContinuation` element type to the tuple, and use `.0` for the existing `results` logic.) At the end, wrap the existing report:

```swift
        return ConversionQueueOutcome(report: report, succeededDestinationPaths: succeededPaths)
```

Update the single caller (line ~136):

```swift
            let outcome = await runConversionQueue(service: service, jobs: finalJobs, preset: preset)
            let report = outcome.report
```

Run `swift build`; fix any other caller the compiler finds the same way.

- [ ] **Step 2: Route offline transfers to staging**

In `LibraryViewModel+ExternalDeviceTransfer.swift`, in `transferToDevice`, right after the `guard !tracks.isEmpty` (line ~48) and before the `switch profile.transferSettings.mode`:

```swift
        // Device not mounted → stage for later instead of prompting for a folder.
        let isMounted = mountedDevices.contains { deviceProfile(for: $0)?.id == profile.id }
        guard isMounted else {
            stageForSync(profile: profile, tracks: tracks, presentingFrom: host)
            return
        }
```

- [ ] **Step 3: Implement `stageForSync`**

Create `Sources/CrateDiggerApp/UI/ExternalDevices/LibraryViewModel+DeviceSync.swift`:

```swift
import AppKit
import CrateDiggerCore
import Foundation

/// Pre-Transfer to Device: bake conversions into a local staging tree while the
/// device is unplugged, then SYNC copies the tree over at mount time.
extension LibraryViewModel {

    /// nonisolated: the sync loop calls this from a detached task — without it,
    /// the @MainActor class would pin this static to the main actor.
    nonisolated static func modificationDate(of url: URL) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)
            ?? .distantPast
    }

    /// Queue tracks for an unplugged device. Convert-mode profiles bake now
    /// (staging tree mirrors the device layout, Cnvrt OLED narrates); copy-mode
    /// profiles just record entries — zero local bytes.
    @MainActor
    func stageForSync(
        profile: ExternalDeviceProfile,
        tracks rawTracks: [LoadedTrack],
        presentingFrom host: NSViewController
    ) {
        let existing = syncQueueStore.load(profileID: profile.id)
        let queuedPaths = Set(existing.map { $0.track.track.fileURL.path })
        let tracks = rawTracks.filter { !queuedPaths.contains($0.track.fileURL.path) }
        guard !tracks.isEmpty else {
            appAlert = .info(
                title: "Already queued",
                message: "Every selected track is already waiting to sync to \(profile.name)."
            )
            return
        }

        Task { @MainActor in
            let stagingRoot = syncQueueStore.stagingDirectory(for: profile.id)
            let hydrated = await tracksWithHydratedArtwork(tracks)
            let reserved = Set(existing.map {
                stagingRoot.appendingPathComponent($0.destinationRelativePath)
                    .standardizedFileURL.resolvingSymlinksInPath().path
            })
            let plans = ExternalDeviceTransferPlanner().planTransfers(
                tracks: hydrated,
                profile: profile,
                mountedAt: stagingRoot,
                reservedDestinationPaths: reserved
            )
            guard !plans.isEmpty else {
                appAlert = .info(
                    title: "Nothing to queue",
                    message: "CrateDigger could not plan any transfers for \(profile.name)."
                )
                return
            }

            let trackByPath = Dictionary(
                hydrated.map { ($0.track.fileURL.path, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let rootPrefix = stagingRoot.standardizedFileURL.path + "/"
            func relative(_ url: URL) -> String {
                let p = url.standardizedFileURL.path
                return p.hasPrefix(rootPrefix) ? String(p.dropFirst(rootPrefix.count)) : url.lastPathComponent
            }
            func entry(for plan: PlannedExternalDeviceTransfer, staged: Bool) -> DeviceSyncQueueEntry? {
                guard let track = trackByPath[plan.sourceURL.path] else { return nil }
                return DeviceSyncQueueEntry(
                    track: track,
                    destinationRelativePath: relative(plan.destinationURL),
                    isStaged: staged,
                    sourceModifiedAt: Self.modificationDate(of: plan.sourceURL)
                )
            }

            let newEntries: [DeviceSyncQueueEntry]
            if plans.first?.action == .convert {
                try? FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
                if let problem = probeFreeDiskSpace(
                    stagingRoot,
                    sourceTracks: hydrated,
                    insufficientSpaceMessageFormat: "Staging these conversions needs ~%.1f GB but this Mac only has %.1f GB free."
                ) {
                    appAlert = problem
                    return
                }
                let service: ConversionService
                do {
                    service = try ConversionService(ffmpegExecutableURL: customFFmpegExecutableURL())
                } catch {
                    appAlert = .error(
                        title: "Couldn't stage conversions",
                        message: "ffmpeg wasn't found. Install it with Homebrew (brew install ffmpeg) or set a custom path in Preferences."
                    )
                    return
                }
                let preset = profile.transferSettings.conversionPreset ?? .genericAAC
                let jobs = plans.compactMap(\.conversionJob)
                let outcome = await runConversionQueue(service: service, jobs: jobs, preset: preset)
                newEntries = plans
                    .filter { outcome.succeededDestinationPaths.contains($0.destinationURL.path) }
                    .compactMap { entry(for: $0, staged: true) }
                let failed = plans.count - newEntries.count
                presentSummary(
                    report: ConversionReport(
                        title: failed == 0 ? "Staged for \(profile.name)" : "Staged with errors",
                        statusLine: "\(newEntries.count) track\(newEntries.count == 1 ? "" : "s") ready to sync"
                            + (failed > 0 ? " · \(failed) failed" : ""),
                        details: outcome.report.details,
                        tone: failed == 0 ? .success : .warning,
                        showsDetailsButton: outcome.report.showsDetailsButton
                    ),
                    presentingFrom: host
                )
            } else {
                // Copy-mode: entries only — sync copies straight from source.
                newEntries = plans.compactMap { entry(for: $0, staged: false) }
                appAlert = .info(
                    title: "Queued for \(profile.name)",
                    message: "\(newEntries.count) track\(newEntries.count == 1 ? "" : "s") will copy over next time you press SYNC."
                )
            }

            guard !newEntries.isEmpty else { return }
            syncQueueStore.save(existing + newEntries, profileID: profile.id)
            refreshSyncQueueCounts()
        }
    }
}
```

- [ ] **Step 4: Build and verify signatures**

Run: `swift build`
Expected: clean. Compiler errors here mean a signature drifted (`ConversionReport` init labels, `.genericAAC`, `AppAlert.info`) — fix against the real definitions, don't invent new ones.

- [ ] **Step 5: Commit**

```bash
git add -A Sources/CrateDiggerApp
git commit -m "feat(devices): offline transfer stages into per-profile sync queue (pre-baked conversions)"
```

---

### Task 4: SYNC — copy loop, progress snapshot, OLED readout, sidebar button

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/ExternalDevices/LibraryViewModel+ExternalDeviceTransfer.swift` (`private func resolveMountedRoot` → internal, line ~138)
- Modify: `Sources/CrateDiggerApp/UI/ExternalDevices/LibraryViewModel+DeviceSync.swift` (add sync)
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift` (published snapshot)
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Header/OLEDDisplay.swift` (`DevicesPane`, line ~1328)
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Main/SourcesSidebar.swift` (SYNC pill under mounted rows)

**Interfaces:**
- Consumes: everything from Tasks 1–3; `resolveMountedRoot(for:presentingFrom:)`; `probeDestinationWritability`; `invalidateDeviceCatalog(for:)`; OLED privates `OLEDPaneScaffold`/`DSPTicker`/`ScanBar`/`NPTitles`/`NPClock`/`DevGlyph` (same file).
- Produces:
  - `DeviceSyncProgressSnapshot` (fields: `profileName`, `currentRelativePath`, `completed`, `total`, `failed`, `isRunning`)
  - `LibraryViewModel.deviceSyncProgress: DeviceSyncProgressSnapshot?` (`@Published`)
  - `LibraryViewModel.syncQueuedTransfers(profileID: UUID)`

- [ ] **Step 1: Snapshot type + published state**

In `LibraryViewModel.swift` next to `ConversionProgressSnapshot` (line ~53):

```swift
/// A live SYNC-to-device run for the DEV OLED pane. Non-nil after a sync starts;
/// stays non-nil (isRunning=false) as the terminal readout until the next
/// source change or sync/stage action clears it.
struct DeviceSyncProgressSnapshot: Equatable, Sendable {
    var profileName: String
    var currentRelativePath: String?
    var completed: Int
    var total: Int
    var failed: Int
    var isRunning: Bool
}
```

In the class body near `conversionProgress`:

```swift
    @Published var deviceSyncProgress: DeviceSyncProgressSnapshot?
```

In `selectSource(_:)`, at the top, add `deviceSyncProgress = nil` guarded so it doesn't wipe a live run:

```swift
        if deviceSyncProgress?.isRunning != true { deviceSyncProgress = nil }
```

- [ ] **Step 2: Expose `resolveMountedRoot`**

In `LibraryViewModel+ExternalDeviceTransfer.swift` line ~138 change `private func resolveMountedRoot` → `func resolveMountedRoot` (the sync code lives in a different file).

- [ ] **Step 3: Implement `syncQueuedTransfers`**

Append to `LibraryViewModel+DeviceSync.swift`:

```swift
extension LibraryViewModel {

    /// Manual SYNC: copy every queued entry onto the mounted device, skipping
    /// files already there, deleting each staged file the moment its copy
    /// lands. Restartable by construction — failures stay queued.
    @MainActor
    func syncQueuedTransfers(profileID: UUID) {
        guard let host = presentationHostViewController else { return }
        guard !isConversionRunning, deviceSyncProgress?.isRunning != true else { return }
        guard var profile = prefs.savedExternalDeviceProfiles.first(where: { $0.id == profileID }) else { return }
        let entries = syncQueueStore.load(profileID: profileID)
        guard !entries.isEmpty else { return }
        guard let device = mountedDevices.first(where: { deviceProfile(for: $0)?.id == profileID }) else {
            appAlert = .info(
                title: "Device not connected",
                message: "\(profile.name) isn't mounted. Connect it, then press SYNC."
            )
            return
        }

        Task { @MainActor in
            guard let mountedRoot = await resolveMountedRoot(for: &profile, presentingFrom: host) else { return }
            if let problem = probeDestinationWritability(
                mountedRoot,
                createFailureTitle: "Can't write to device",
                createFailureMessage: "CrateDigger could not write to \(mountedRoot.path). Confirm the device is mounted and writable.",
                notWritableTitle: "Device isn't writable",
                notWritableMessage: "CrateDigger cannot write into \(mountedRoot.path). Check the device lock switch or macOS Files & Folders access.",
                probeFilenamePrefix: ".cratedigger-sync-probe-"
            ) {
                appAlert = problem
                return
            }

            // Free-space preflight on actual bytes to copy (staged file or source).
            let fm = FileManager.default
            let bytesNeeded: Int64 = entries.reduce(0) { sum, entry in
                let url = entry.isStaged
                    ? syncQueueStore.stagedFileURL(for: entry, profileID: profileID)
                    : entry.track.track.fileURL
                let size = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
                return sum + size
            }
            let free = ((try? mountedRoot.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
                .volumeAvailableCapacity).map(Int64.init) ?? .max
            guard bytesNeeded < free else {
                appAlert = .error(
                    title: "Not enough space on \(profile.name)",
                    message: String(
                        format: "This sync needs ~%.1f GB but the device has %.1f GB available.",
                        Double(bytesNeeded) / 1e9, Double(free) / 1e9
                    )
                )
                return
            }

            oledView = .devices
            deviceSyncProgress = DeviceSyncProgressSnapshot(
                profileName: profile.name,
                currentRelativePath: entries.first?.destinationRelativePath,
                completed: 0, total: entries.count, failed: 0, isRunning: true
            )

            let profileName = profile.name
            let preset = profile.transferSettings.conversionPreset
            let ffmpegURL = customFFmpegExecutableURL()
            let total = entries.count

            let outcome: (synced: Int, skipped: Int, failed: Int, lines: [String]) =
                await withCheckedContinuation { continuation in
                    Task.detached(priority: .userInitiated) { [weak self] in
                        let store = DeviceSyncQueueStore()
                        let fm = FileManager.default
                        var synced = 0, skipped = 0, failed = 0
                        var lines: [String] = []
                        var remaining = entries
                        var service: ConversionService?

                        for (i, entry) in entries.enumerated() {
                            let destination = mountedRoot.appendingPathComponent(entry.destinationRelativePath)
                            let stagedURL = store.stagedFileURL(for: entry, profileID: profileID)
                            let sourceURL = entry.track.track.fileURL
                            do {
                                if fm.fileExists(atPath: destination.path) {
                                    skipped += 1
                                    lines.append("[skip] \(entry.destinationRelativePath) — already on device")
                                } else {
                                    let copyFrom: URL
                                    if entry.isStaged {
                                        // Staleness guard: source edited since baking → re-bake
                                        // in place (ffmpeg -y overwrites the stale file). A
                                        // missing source is fine — the bake stands on its own.
                                        if fm.fileExists(atPath: sourceURL.path),
                                           Self.modificationDate(of: sourceURL) != entry.sourceModifiedAt,
                                           let preset {
                                            if service == nil {
                                                service = try? ConversionService(ffmpegExecutableURL: ffmpegURL)
                                            }
                                            if let service {
                                                _ = service.enqueue(
                                                    [ConversionJob(sourceURL: sourceURL, destinationURL: stagedURL,
                                                                   metadata: entry.track.metadata)],
                                                    preset: preset
                                                )
                                                let results = service.runQueuedJobs(maxConcurrentWorkers: 1) { _, _, _ in }
                                                guard results.first?.status == .completed else {
                                                    throw NSError(
                                                        domain: "CrateDigger.DeviceSync", code: 1,
                                                        userInfo: [NSLocalizedDescriptionKey: "Re-bake failed (source changed since staging)"])
                                                }
                                            }
                                        }
                                        guard fm.fileExists(atPath: stagedURL.path) else {
                                            throw NSError(
                                                domain: "CrateDigger.DeviceSync", code: 2,
                                                userInfo: [NSLocalizedDescriptionKey: "Staged file missing — remove from queue and re-add"])
                                        }
                                        copyFrom = stagedURL
                                    } else {
                                        guard fm.fileExists(atPath: sourceURL.path) else {
                                            throw NSError(
                                                domain: "CrateDigger.DeviceSync", code: 3,
                                                userInfo: [NSLocalizedDescriptionKey: "Source file missing"])
                                        }
                                        copyFrom = sourceURL
                                    }
                                    let dir = destination.deletingLastPathComponent()
                                    if !fm.fileExists(atPath: dir.path) {
                                        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                                    }
                                    try fm.copyItem(at: copyFrom, to: destination)
                                    synced += 1
                                    lines.append("[ok] \(entry.destinationRelativePath)")
                                }
                                // Done (copied or already there): staged bytes are trash now.
                                store.removeStagedFile(for: entry, profileID: profileID)
                                remaining.removeAll { $0.id == entry.id }
                                store.save(remaining, profileID: profileID)
                            } catch {
                                failed += 1
                                lines.append("[FAILED] \(entry.destinationRelativePath)\n    \(error.localizedDescription)")
                            }

                            let done = i + 1
                            let failedSoFar = failed
                            Task { @MainActor [weak self] in
                                self?.deviceSyncProgress = DeviceSyncProgressSnapshot(
                                    profileName: profileName,
                                    currentRelativePath: done < total ? entries[done].destinationRelativePath : nil,
                                    completed: done, total: total, failed: failedSoFar,
                                    isRunning: done < total
                                )
                            }
                        }

                        if remaining.isEmpty { store.remove(profileID: profileID) }
                        continuation.resume(returning: (synced, skipped, failed, lines))
                    }
                }

            deviceSyncProgress = DeviceSyncProgressSnapshot(
                profileName: profileName, currentRelativePath: nil,
                completed: outcome.synced + outcome.skipped, total: total,
                failed: outcome.failed, isRunning: false
            )
            refreshSyncQueueCounts()
            invalidateDeviceCatalog(for: device)
            if case .device(let path) = currentSource, path == device.volumeURL.path {
                refreshLibrary()   // re-walk + refresh the saved catalog now
            }

            let tone: StatusTone = outcome.failed == 0 ? .success : (outcome.synced == 0 ? .error : .warning)
            presentSummary(
                report: ConversionReport(
                    title: outcome.failed == 0 ? "Synced to \(profileName)" : "Sync finished with errors",
                    statusLine: "\(outcome.synced) synced"
                        + (outcome.skipped > 0 ? ", \(outcome.skipped) already on device" : "")
                        + (outcome.failed > 0 ? ", \(outcome.failed) failed" : ""),
                    details: outcome.lines.joined(separator: "\n"),
                    tone: tone,
                    showsDetailsButton: !outcome.lines.isEmpty
                ),
                presentingFrom: host
            )
        }
    }
}
```

Concurrency note: the detached closure captures `entries`, `mountedRoot`, `profileID`, `preset`, `ffmpegURL` (all Sendable) and builds its own `DeviceSyncQueueStore` — same pattern as `DeviceCatalogStore().save` in `selectDevice`. If the compiler complains about `ConversionService` sendability, keep it constructed and used entirely inside the detached closure (it already is).

- [ ] **Step 4: DEV OLED sync readout**

In `OLEDDisplay.swift`, `DevicesPane` (line ~1328), change `body`:

```swift
    var body: some View {
        if let sync = model.deviceSyncProgress {
            syncBody(sync)
        } else if let c = connected {
            deviceBody(profile: c.profile, device: c.device)
        } else {
            emptyBody
        }
    }
```

Add below `deviceBody`, reusing the pane's own private pieces (`OLEDPaneScaffold`, `NPTitles`, `NPClock`, `DSPTicker`, `ScanBar`, `DevGlyph`) — match `emptyBody`'s slot shapes exactly:

```swift
    // MARK: Sync readout (SYNC → DEVICE / SYNC COMPLETE)

    private func syncBody(_ sync: DeviceSyncProgressSnapshot) -> some View {
        OLEDPaneScaffold {
            HStack(alignment: .bottom, spacing: 18) {
                DevGlyph()
                NPTitles(
                    title: sync.isRunning
                        ? "SYNC → \(sync.profileName.uppercased())"
                        : "SYNC COMPLETE",
                    sub: sync.isRunning
                        ? "Copying \(min(sync.completed + 1, sync.total)) of \(sync.total)"
                        : "\(sync.completed) track\(sync.completed == 1 ? "" : "s")"
                            + (sync.failed > 0 ? " · \(sync.failed) failed" : "")
                            + " · \(sync.profileName)",
                    titleSize: 40
                )
            }
        } readout: {
            NPClock(now: "\(sync.completed)", tot: "OF \(sync.total)").fixedSize()
        } ticker: {
            DSPTicker(
                prefix: "SYNC",
                path: AttributedString(sync.currentRelativePath ?? "—"),
                leadingInset: 62
            )
        } cells: {
            ScanBar(style: .orange(sync.total > 0 ? Double(sync.completed) / Double(sync.total) : 0))
                .frame(height: 4)
                .padding(.top, 6)
        }
    }
```

If the `cells:` slot demands `OLEDCells`, put the `ScanBar` in the `ticker:` slot beneath the `DSPTicker` in a `VStack` and give `cells:` a minimal `OLEDCells([...])` echoing counts (`Synced / Failed / Remaining`) — follow whichever shape compiles against `OLEDPaneScaffold`'s generics.

- [ ] **Step 5: SYNC pill in the sidebar**

In `SourcesSidebar.swift`, wrap the mounted-device row (from Task 2's Step 5) in a `VStack` with a SYNC button, exactly mirroring the CD "RIP CD" pattern (lines ~168–188):

```swift
                        ForEach(model.mountedDevices) { device in
                            VStack(alignment: .leading, spacing: 4) {
                                sidebarItem(
                                    icon: deviceIcon(for: device),
                                    title: device.name,
                                    count: isSelectedDevice(device.volumeURL.path) ? "\(model.index.allTracks.count)" : "—",
                                    selected: isSelectedDevice(device.volumeURL.path),
                                    action: { model.selectSource(.device(volumePath: device.volumeURL.path)) }
                                )
                                if let profile = model.deviceProfile(for: device),
                                   let queued = model.syncQueueCounts[profile.id], queued > 0 {
                                    Button(action: { model.syncQueuedTransfers(profileID: profile.id) }) {
                                        Text("SYNC \(queued)")
                                            .font(CarbonFont.mono(8, weight: .bold))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(theme.orange)
                                            .cornerRadius(4)
                                    }
                                    .buttonStyle(.carbonHover)
                                    .padding(.leading, 36)
                                    .padding(.bottom, 6)
                                    .carbonTip("Copy \(queued) queued track\(queued == 1 ? "" : "s") onto \(device.name)")
                                }
                            }
                        }
```

- [ ] **Step 6: Build**

Run: `swift build`
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add -A Sources/CrateDiggerApp
git commit -m "feat(devices): SYNC — restartable copy loop with DEV OLED readout and sidebar pill"
```

---

### Task 5: Pending badges, queue removal, cleanup hooks

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Main/Browser/Rows/TrackRow.swift` (PENDING tag)
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Main/Browser/BrowserContextMenu.swift` (Remove from Sync Queue)
- Modify: `Sources/CrateDiggerApp/UI/ExternalDevices/LibraryViewModel+DeviceSync.swift` (removal API)
- Modify: `Sources/CrateDiggerApp/UI/ExternalDevices/DevicesPreferencesView.swift:226` (profile-deletion cleanup)
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift` (launch sweep in `init`)

**Interfaces:**
- Consumes: `pendingSyncTrackIDs` (Task 2), `DeviceSyncQueueStore.sweepOrphans` (Task 1).
- Produces:
  - `LibraryViewModel.isPendingSync(_ trackID: UUID) -> Bool`
  - `LibraryViewModel.removeFromSyncQueue(trackIDs: Set<UUID>)`

- [ ] **Step 1: Model API**

Append to `LibraryViewModel+DeviceSync.swift`:

```swift
extension LibraryViewModel {

    /// PENDING badge test — only meaningful while browsing an offline device.
    func isPendingSync(_ trackID: UUID) -> Bool {
        guard case .offlineDevice = currentSource else { return false }
        return pendingSyncTrackIDs.contains(trackID)
    }

    /// Drop queued tracks (and their staged bytes) from the offline device
    /// being browsed, then rebuild its view.
    @MainActor
    func removeFromSyncQueue(trackIDs: Set<UUID>) {
        guard case .offlineDevice(let profileID) = currentSource else { return }
        var entries = syncQueueStore.load(profileID: profileID)
        let doomed = entries.filter { trackIDs.contains($0.track.track.id) }
        guard !doomed.isEmpty else { return }
        for entry in doomed {
            syncQueueStore.removeStagedFile(for: entry, profileID: profileID)
        }
        entries.removeAll { trackIDs.contains($0.track.track.id) }
        if entries.isEmpty {
            syncQueueStore.remove(profileID: profileID)   // wipes staging dir + JSON
        } else {
            syncQueueStore.save(entries, profileID: profileID)
        }
        refreshSyncQueueCounts()
        selectSource(.offlineDevice(profileID: profileID))   // rebuild index + badges
    }
}
```

(`pendingSyncTrackIDs` is `private(set)` in `LibraryViewModel.swift`; the rebuild via `selectSource` refreshes it — no direct mutation needed here.)

- [ ] **Step 2: PENDING tag on track rows**

Open `Sources/CrateDiggerApp/UI/Carbon/Main/Browser/Rows/TrackRow.swift`. Ensure it can see the model (`@EnvironmentObject private var model: LibraryViewModel` — add if absent; the environment object is injected at the root). Immediately after the track-title `Text`, add:

```swift
            if model.isPendingSync(track.track.id) {
                Text("PENDING")
                    .font(CarbonFont.mono(7, weight: .bold))
                    .tracking(1.2)
                    .foregroundColor(theme.orange)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(theme.orange.opacity(0.6), lineWidth: 0.5))
            }
```

Adapt the property name (`track` vs `loaded` etc.) and theme access to what the row already uses — read the file first; only the badge is new.

- [ ] **Step 3: Context-menu removal**

In `BrowserContextMenu.swift`, in the track context menu (near where `transferToDeviceMenu` is offered, line ~48–66), add:

```swift
        if case .offlineDevice = model.currentSource {
            let pending = tracks.filter { model.isPendingSync($0.track.id) }
            if !pending.isEmpty {
                Button("Remove from Sync Queue (\(pending.count))", role: .destructive) {
                    model.removeFromSyncQueue(trackIDs: Set(pending.map { $0.track.id }))
                }
                Divider()
            }
        }
```

Place it in the same builder(s) that already receive `tracks: [LoadedTrack]` and `model` — album- and artist-level menus get the behavior for free since they pass their flattened tracks.

- [ ] **Step 4: Cleanup hooks**

`DevicesPreferencesView.swift:226` — after `PreferencesStore.shared.removeExternalDeviceProfile(id: selectedID)` add:

```swift
        DeviceSyncQueueStore().remove(profileID: selectedID)
```

`LibraryViewModel.swift` `init` — after the `refreshSyncQueueCounts()` call from Task 2:

```swift
        // Trash guard: staging/queues for profiles that no longer exist.
        let validIDs = Set(prefs.savedExternalDeviceProfiles.map(\.id))
        Task.detached(priority: .utility) {
            DeviceSyncQueueStore().sweepOrphans(validProfileIDs: validIDs)
        }
```

- [ ] **Step 5: Build + full test suite**

Run: `swift build && scripts/test.sh`
Expected: build clean, all tests pass.

- [ ] **Step 6: Commit**

```bash
git add -A Sources/CrateDiggerApp
git commit -m "feat(devices): PENDING badges, sync-queue removal, orphan sweep + profile-delete cleanup"
```

---

### Task 6: Collapsible Sources section headers

**Files:**
- Modify: `Sources/CrateDiggerCore/Services/PreferencesStore.swift` (new key + property)
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Main/SourcesSidebar.swift`

**Interfaces:**
- Produces: `PreferencesStore.collapsedSourceSections: [String]`

- [ ] **Step 1: Persisted property**

In `PreferencesStore.swift` add to the `Key` enum (line ~21 area):

```swift
        static let collapsedSourceSections = "cratedigger.sidebar.collapsedSections"
```

and near `savedOLEDView` (line ~280):

```swift
    /// Sources-sidebar section titles the user has collapsed (chevron toggles).
    public var collapsedSourceSections: [String] {
        get { defaults.stringArray(forKey: Key.collapsedSourceSections) ?? [] }
        set { defaults.set(newValue, forKey: Key.collapsedSourceSections) }
    }
```

- [ ] **Step 2: Chevron header + collapse state**

In `SourcesSidebar.swift` add state:

```swift
    @State private var collapsedSections: Set<String> = Set(PreferencesStore.shared.collapsedSourceSections)
```

Replace `sectionHeader` (line ~351) with:

```swift
    private func isCollapsed(_ title: String) -> Bool { collapsedSections.contains(title) }

    private func toggleSection(_ title: String) {
        if !collapsedSections.insert(title).inserted { collapsedSections.remove(title) }
        PreferencesStore.shared.collapsedSourceSections = Array(collapsedSections).sorted()
    }

    private func sectionHeader(_ title: String, trailing: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .rotationEffect(.degrees(isCollapsed(title) ? -90 : 0))
            Text(title.uppercased())
            Spacer()
            Text(trailing)
        }
        .font(CarbonFont.mono(8.5, weight: .semibold))
        .tracking(2.2)
        .foregroundStyle(theme.ink4)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) { toggleSection(title) }
        }
    }
```

- [ ] **Step 3: Gate every section's rows**

Wrap each section's content (everything between its header and the next header) in `if !isCollapsed("<Title>")`, using exactly these keys: `"Prep Crate"`, `"Local Library"`, `"Remote Library"`, `"Radio / Streams"`, `"CD Drives"`, `"Devices"`, `"Playlists"`. Example for Prep Crate:

```swift
                    sectionHeader("Prep Crate", trailing: "")
                    if !isCollapsed("Prep Crate") {
                        sidebarItem(
                            icon: Image(systemName: "tray.and.arrow.down"),
                            ...
                        )
                        .contextMenu { ... }
                    }
```

For headers wrapped in an `HStack` with a `+` button ("Local Library", "Radio / Streams", "Playlists"), the `HStack` stays visible; only the rows below it are gated.

- [ ] **Step 4: Build**

Run: `swift build`
Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add -A Sources
git commit -m "feat(sidebar): collapsible Sources sections with persisted chevron state"
```

---

### Task 7: Full verification

- [ ] **Step 1: Full test suite**

Run: `scripts/test.sh`
Expected: everything passes (existing + `DeviceSyncQueueStoreTests`).

- [ ] **Step 2: Build both configurations**

Run: `swift build && swift build -c release`
Expected: clean.

- [ ] **Step 3: Manual GUI verification (user, via Xcode ⌘R)**

Hand the user this checklist — GUI behavior is verified by them per project convention:

1. Unplug the iPod → its profile shows dimmed under Devices with "— " count; select it → cached contents browse; OLED shows DEV pane.
2. Right-click an album → Transfer to Device → the profile: Cnvrt OLED bakes (convert-mode) or instant "Queued" alert (copy-mode); sidebar count shows "N queued"; browsing the offline device shows PENDING badges.
3. `~/Library/Application Support/CrateDigger/DeviceStaging/<profileID>/` mirrors the device layout (convert-mode only; copy-mode must create NO staging files).
4. Right-click a pending track → Remove from Sync Queue → badge gone, staged file gone, empty dirs pruned.
5. Mount the device → sidebar row lights up with SYNC pill → press SYNC → DEV OLED shows `SYNC → NAME`, ticker, n/m, then SYNC COMPLETE; files land under the music dir in the right folders; staging dir is **gone** afterwards; queue JSON gone.
6. Press SYNC again with nothing queued → nothing happens. Re-queue one already-synced track → sync reports "already on device".
7. Collapse/expand each sidebar section; relaunch → collapsed state persists.

- [ ] **Step 4: Update memory/docs if behavior surprised** (only if something in the checklist fails and gets fixed — otherwise nothing to do).
