# Artwork Inspector & Gallery Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix three SAVE bugs and the gallery's invisible multi-selection, move the device-safe toggle onto SAVE, order the ART grid by role, add artwork removal, add Playing Now (⌘L), add gallery keyboard navigation, and add batch "Search & Add Album Covers".

**Architecture:** Two Core additions (`ArtworkRole.sortOrder`, `ArtworkStore.remove(hash:)`) carry the only unit-testable logic. Everything else is view-model wiring and SwiftUI in `CrateDiggerApp`, which the existing architecture does not unit-test — those tasks end in a build plus a GUI check, not a test. Most items are root-cause repairs to code that already half-exists rather than new subsystems.

**Tech Stack:** Swift 5.9+, SwiftUI + AppKit, Swift Package Manager, XCTest. macOS 13 deployment target.

**Spec:** `docs/superpowers/specs/2026-07-17-artwork-gallery-fixes-design.md`

## Global Constraints

- **Branch:** all work lands on `beta/1.1.0-theming`. Do **not** bump the version or build — the `press-the-record` release skill owns that.
- **Deployment target is macOS 13.** `onKeyPress` (macOS 14+) and the single-parameter `onChange(of:)` (macOS 14+) are unavailable. Use the two-parameter `.onChange(of: value) { newValue in }` form, matching `ColumnList.swift:51-63`.
- **Tests:** run `scripts/test.sh`, never bare `swift test`. Filter with `scripts/test.sh --filter ClassName`.
- **New testable logic goes in `CrateDiggerCore` with an XCTest.** UI glue goes in `CrateDiggerApp`.
- **Commit prefixes matter for the 1.0.3 cherry-pick.** Tasks 3, 6 and 7 are the stable-bound fixes; keep each in its own commit and do not fold unrelated changes into them.
- **Alerts:** `appAlert = .error(title:message:)` and `.info(title:message:)` both exist; `.error` is used for informational messages elsewhere in this codebase, but prefer `.info` for success and `.error` for genuine failures in new code.
- **Artwork is folder-canonical.** New art is written next to the music (`cover.jpg` + `.cratedigger-art.json`), never only into the app cache.

---

### Task 1: `ArtworkRole.sortOrder` and ART grid ordering

Fixes spec Item 2a. The grid currently sorts by raw ASCII filename, so `back.jpg` precedes `cover.jpg`.

**Files:**
- Modify: `Sources/CrateDiggerCore/Models/ArtworkManifest.swift:3-15`
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Inspector/ArtworkInspectorView.swift:115` and `:146-153`
- Test: `Tests/CrateDiggerCoreTests/ArtworkManifestTests.swift`

**Interfaces:**
- Produces: `ArtworkRole.sortOrder: Int` — used by Task 3 (`embedCoverIntoTracksInBackground` deterministic pick does **not** use it; see spec 2.3) and by this task's grid ordering only.

- [ ] **Step 1: Write the failing test**

Append inside the existing `ArtworkManifestTests` class in `Tests/CrateDiggerCoreTests/ArtworkManifestTests.swift`:

```swift
    func testRolesSortCoverFirstThenBackDiscBooklet() {
        let shuffled: [ArtworkRole] = [.ignore, .bookletPage, .back, .auto, .cover, .disc, .inlay, .altCover]
        let sorted = shuffled.sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(sorted, [.cover, .altCover, .back, .disc, .inlay, .bookletPage, .auto, .ignore])
    }

    func testEveryRoleHasADistinctSortOrder() {
        let orders = ArtworkRole.allCases.map(\.sortOrder)
        XCTAssertEqual(Set(orders).count, ArtworkRole.allCases.count,
                       "Duplicate sortOrder makes grid ordering non-deterministic")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh --filter ArtworkManifestTests`
Expected: FAIL — `value of type 'ArtworkRole' has no member 'sortOrder'`

- [ ] **Step 3: Add `sortOrder` to `ArtworkRole`**

In `Sources/CrateDiggerCore/Models/ArtworkManifest.swift`, after the enum's closing `}` at line 15, add:

```swift
public extension ArtworkRole {
    /// Display order for the ART grid: the main cover first, then the physical
    /// parts of the package, then booklet pages. Unclassified (`.auto`) and
    /// hidden (`.ignore`) sink to the bottom, where they read as "needs
    /// attention".
    ///
    /// The artwork *viewer* deliberately uses a different order — see
    /// `AlbumArtCatalog.pages`, which sequences a booklet for reading rather
    /// than for editing.
    var sortOrder: Int {
        switch self {
        case .cover:       return 0
        case .altCover:    return 1
        case .back:        return 2
        case .disc:        return 3
        case .inlay:       return 4
        case .bookletPage: return 5
        case .auto:        return 6
        case .ignore:      return 7
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh --filter ArtworkManifestTests`
Expected: PASS

- [ ] **Step 5: Order the grid by role**

In `Sources/CrateDiggerApp/UI/Carbon/Inspector/ArtworkInspectorView.swift`, add this computed property immediately before `private var mediaFormatLabel: String {` (line 23):

```swift
    /// Grid order: role first (Main Cover → … → Ignore), then filename via
    /// `localizedStandardCompare` so `booklet_2` precedes `booklet_10`.
    ///
    /// Kept separate from `imageURLs` on purpose: `imageURLs` keys the
    /// thumbnail-loading `.task(id:)`, so reordering it on every role change
    /// would reload every thumbnail in the grid.
    private var orderedImageURLs: [URL] {
        imageURLs.sorted { lhs, rhs in
            let lRole = manifest.roles[lhs.lastPathComponent] ?? .auto
            let rRole = manifest.roles[rhs.lastPathComponent] ?? .auto
            if lRole.sortOrder != rRole.sortOrder { return lRole.sortOrder < rRole.sortOrder }
            return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
        }
    }
```

Then change line 115 from:

```swift
                    ForEach(imageURLs, id: \.self) { url in
```

to:

```swift
                    ForEach(orderedImageURLs, id: \.self) { url in
```

- [ ] **Step 6: Reorder the role picker menu to match**

In the same file, replace the `Picker`'s eight `Text(...).tag(...)` lines (`:146-153`) with:

```swift
                                Text("Main Cover").tag(ArtworkRole.cover)
                                Text("Alt Cover").tag(ArtworkRole.altCover)
                                Text("Back").tag(ArtworkRole.back)
                                Text("Disc/Vinyl").tag(ArtworkRole.disc)
                                Text("Inlay / Insert").tag(ArtworkRole.inlay)
                                Text("Booklet Page").tag(ArtworkRole.bookletPage)
                                Divider()
                                Text("Auto").tag(ArtworkRole.auto)
                                Text("Ignore").tag(ArtworkRole.ignore)
```

- [ ] **Step 7: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 8: Commit**

```bash
git add Sources/CrateDiggerCore/Models/ArtworkManifest.swift Sources/CrateDiggerApp/UI/Carbon/Inspector/ArtworkInspectorView.swift Tests/CrateDiggerCoreTests/ArtworkManifestTests.swift
git commit -m "feat(artwork): order the ART grid by role, cover first

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `ArtworkStore.remove(hash:)` and `ArtworkService.removeCached(hash:)`

Prerequisite for Task 5. The store has only `clear()` today, and `ArtworkService.store` is `private` (`ArtworkService.swift:44`) — so the view cannot reach the store directly and must go through the service that owns it.

**Files:**
- Modify: `Sources/CrateDiggerCore/Services/ArtworkStore.swift` (add after `data(for:)`, line 67)
- Modify: `Sources/CrateDiggerCore/Services/ArtworkService.swift` (add near `ingest`)
- Test: `Tests/CrateDiggerCoreTests/ArtworkStoreTests.swift`
- Test: `Tests/CrateDiggerCoreTests/ArtworkServiceTests.swift`

**Interfaces:**
- Produces: `ArtworkStore.remove(_ hash: String)`; `ArtworkService.removeCached(hash: String)` — the latter is what Task 5 calls. Do **not** widen `ArtworkService.store` to reach the store from the app layer; the service owns its store.

- [ ] **Step 1: Write the failing test**

Append inside the existing `ArtworkStoreTests` class in `Tests/CrateDiggerCoreTests/ArtworkStoreTests.swift`:

```swift
    func testRemoveDeletesTheCachedThumbnail() {
        let store = ArtworkStore(directory: directory)
        store.put(Data("not-an-image-but-stored-as-is".utf8), for: "deadbeef")
        XCTAssertTrue(store.contains("deadbeef"))

        store.remove("deadbeef")

        XCTAssertFalse(store.contains("deadbeef"))
        XCTAssertNil(store.data(for: "deadbeef"))
    }

    func testRemoveIsSilentForAnAbsentHash() {
        let store = ArtworkStore(directory: directory)
        store.remove("never-existed")   // must not throw or trap
        XCTAssertFalse(store.contains("never-existed"))
    }
```

If `ArtworkStoreTests` has no `directory` property in `setUpWithError`, mirror the setup from `Tests/CrateDiggerCoreTests/ArtworkHydrationTests.swift:8-17`.

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh --filter ArtworkStoreTests`
Expected: FAIL — `value of type 'ArtworkStore' has no member 'remove'`

- [ ] **Step 3: Implement `remove`**

In `Sources/CrateDiggerCore/Services/ArtworkStore.swift`, after `data(for:)` (line 67), add:

```swift
    /// Drop one cached thumbnail — used when its source art is deleted, so the
    /// cache doesn't keep a cover the user removed. Silent when absent: the
    /// thumbnail may simply never have been drawn.
    public func remove(_ hash: String) {
        try? fileManager.removeItem(at: url(for: hash))
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh --filter ArtworkStoreTests`
Expected: PASS

- [ ] **Step 5: Write the failing test for the service forwarder**

Append inside the existing `ArtworkServiceTests` class in `Tests/CrateDiggerCoreTests/ArtworkServiceTests.swift`:

```swift
    func testRemoveCachedDropsTheStoredThumbnail() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ArtworkStore(directory: directory)
        let service = ArtworkService(store: store)
        store.put(Data("stored-bytes".utf8), for: "cafebabe")
        XCTAssertTrue(store.contains("cafebabe"))

        service.removeCached(hash: "cafebabe")

        XCTAssertFalse(store.contains("cafebabe"))
    }
```

- [ ] **Step 6: Run test to verify it fails**

Run: `scripts/test.sh --filter ArtworkServiceTests`
Expected: FAIL — `value of type 'ArtworkService' has no member 'removeCached'`

- [ ] **Step 7: Implement the forwarder**

In `Sources/CrateDiggerCore/Services/ArtworkService.swift`, add next to `ingest`:

```swift
    /// Forget one cover's cached thumbnail — used when its source art is deleted.
    ///
    /// Only the on-disk store is pruned. The in-memory NSCaches are keyed
    /// `hash-WxH` / `hash-tN` and NSCache cannot enumerate its keys, so per-key
    /// eviction would mean tracking every key by hand — for entries that nothing
    /// references once the index rebuilds, in a cache that already evicts under
    /// pressure. Not worth the bookkeeping.
    public func removeCached(hash: String) {
        store?.remove(hash)
    }
```

- [ ] **Step 8: Run test to verify it passes**

Run: `scripts/test.sh --filter ArtworkServiceTests`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add Sources/CrateDiggerCore/Services/ArtworkStore.swift Sources/CrateDiggerCore/Services/ArtworkService.swift Tests/CrateDiggerCoreTests/ArtworkStoreTests.swift Tests/CrateDiggerCoreTests/ArtworkServiceTests.swift
git commit -m "feat(artwork): per-hash thumbnail eviction

ArtworkStore.remove(_:) plus an ArtworkService.removeCached(hash:) forwarder,
since the service owns its store privately.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Three SAVE bugs  ⟶ cherry-pick to 1.0.3

Fixes spec Items 2.1, 2.2, 2.3. Keep this commit self-contained.

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Inspector/ArtworkInspectorView.swift:306-331`
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift:2079-2081`

**Interfaces:**
- Consumes: nothing from earlier tasks. Deliberately independent of Task 1's `sortOrder` so it cherry-picks to `main` cleanly.

- [ ] **Step 1: Fix the non-deterministic cover pick (2.3)**

In `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift`, replace lines 2078-2081:

```swift
        // Prefer the manifest's .cover-roled file, else cover.jpg.
        let manifest = ArtworkManifest.load(from: folder)
        let coverName = manifest?.roles.first(where: { $0.value == .cover })?.key ?? "cover.jpg"
        let coverURL = folder.appendingPathComponent(coverName)
```

with:

```swift
        // Prefer the manifest's .cover-roled file, else cover.jpg. `roles` is a
        // dictionary, so `.first(where:)` picked a different file run to run when
        // an album had more than one .cover — sort for a stable choice.
        let manifest = ArtworkManifest.load(from: folder)
        let coverName = manifest?.roles
            .filter { $0.value == .cover }
            .map(\.key)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .first ?? "cover.jpg"
        let coverURL = folder.appendingPathComponent(coverName)
```

- [ ] **Step 2: Fix the stale disk cache and the silent write failure (2.1, 2.2)**

In `Sources/CrateDiggerApp/UI/Carbon/Inspector/ArtworkInspectorView.swift`, replace `saveChanges()` entirely (lines 306-331):

```swift
    private func saveChanges() {
        guard let album = album, let representative = album.tracks.first?.track.fileURL else { return }
        isSaving = true

        Task {
            let albumFolder = representative.deletingLastPathComponent()

            do {
                try manifest.save(to: albumFolder)
            } catch {
                // A read-only or full volume used to report "Artwork saved" and
                // silently drop the edit. Keep isDirty so the work isn't lost.
                await MainActor.run {
                    isSaving = false
                    model.appAlert = .error(
                        title: "Couldn't save artwork",
                        message: "Writing to “\(albumFolder.lastPathComponent)” failed: \(error.localizedDescription)"
                    )
                }
                return
            }

            await MainActor.run {
                isSaving = false
                isDirty = false
                // This folder's manifest just changed on disk. refreshLibrary()
                // rebuilds the indexes but reads per-folder booklet/mediaFormat
                // info from the disk cache, so without this the rebuild reuses
                // stale info for the folder we just edited (a FORMAT change
                // wouldn't take until a full rescan). applyImportedArtwork does
                // the same thing for the import path.
                model.indexDiskCache.invalidate(
                    albumFolderPath: albumFolder.path,
                    filePaths: album.tracks.map { $0.track.fileURL.path }
                )
                model.refreshLibrary()
                // Embed a compatible 600px baseline copy of the cover into each
                // track in the BACKGROUND (keeping the full-res cover.jpg) — so the
                // art travels inside the files without blocking on the per-file
                // rewrite. The folder cover already drives in-app display.
                model.embedCoverIntoTracksInBackground(for: album, deviceCompatible: deviceCompatibleArt)
                model.appAlert = .info(
                    title: "Artwork saved",
                    message: "Saved for “\(album.title)”. Embedding the cover into your tracks in the background."
                )
            }
        }
    }
```

- [ ] **Step 3: Make `indexDiskCache` reachable from the inspector view**

It is `private` today (`LibraryViewModel.swift:954`), so Step 2 will not compile until this changes. Replace line 954:

```swift
    private let indexDiskCache = LibraryIndexDiskCache()
```

with:

```swift
    /// Internal, not private: the ART inspector invalidates the folder it just
    /// wrote a manifest into, the same way applyImportedArtwork does.
    let indexDiskCache = LibraryIndexDiskCache()
```

Internal, not `public` — this is app-layer state and nothing outside the module should touch it.

- [ ] **Step 4: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon/Inspector/ArtworkInspectorView.swift Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift
git commit -m "fix(artwork): stale disk cache, silent save failure, unstable cover pick

SAVE rebuilt indexes without invalidating the edited folder's disk cache,
so a FORMAT change didn't take until a rescan. A failed manifest write was
swallowed by try? and still reported 'Artwork saved'. And the embedded
cover was chosen via first(where:) over a dictionary, so albums with two
.cover files embedded a different one run to run.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Device-safe toggle moves onto SAVE

Fixes spec Item 1.

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Inspector/ArtworkInspectorView.swift:81-109`

- [ ] **Step 1: Replace the SAVE button with a menu, and delete the checkbox row**

In `Sources/CrateDiggerApp/UI/Carbon/Inspector/ArtworkInspectorView.swift`, replace lines 81-109 (the `if isSaving { … } else { … }` SAVE block **and** the whole `HStack` holding the `Toggle`, up to and including its `.padding(.bottom, 6)`) with:

```swift
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                } else {
                    // The device-safe setting lives here rather than in a row of
                    // its own: it is a global preference whose only effect is on
                    // this button's background embed step, so it belongs with the
                    // action it modifies, not with the per-album art above.
                    Menu {
                        Toggle("Device-safe artwork (600px baseline JPEG)", isOn: $deviceCompatibleArt)
                    } primaryAction: {
                        saveChanges()
                    } label: {
                        Text("SAVE")
                            .font(CarbonFont.mono(9, weight: .bold))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.visible)
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
                    .background(ChromeChassis(theme: theme, cornerRadius: 6))
                    .disabled(!isDirty)
                    .help("Saves artwork roles and format, and embeds the cover into every track on the album. Device-safe artwork embeds a downscaled baseline JPEG so Rockbox and legacy players can read it.")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
```

Note the `KeyButton(style: isDirty ? .selected : .normal, …)` styling is lost here — `Menu` cannot wear `KeyButton`. Step 2 checks whether that is acceptable.

- [ ] **Step 2: Build and eyeball the control**

Run: `swift build && .build/arm64-apple-macosx/debug/CrateDiggerApp`

Select an album, open Inspector → ART. Confirm: the checkbox row is gone; SAVE shows a chevron; clicking SAVE saves; clicking the chevron reveals the toggle; the toggle's state persists across an app restart.

**If the `Menu` looks foreign against the Carbon chassis** (wrong height, system-blue highlight, chevron in the wrong place): stop and report back rather than shipping a control that fights the chassis. The documented fallback is a chevron hit-zone inside the existing `KeyButton` presenting an `NSMenu`. Do not invent a third option.

- [ ] **Step 3: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon/Inspector/ArtworkInspectorView.swift
git commit -m "feat(artwork): move the device-safe toggle onto the SAVE button

It is a global preference whose only effect is SAVE's background embed,
so it was reading as per-album state and costing a row in a cramped pane.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Remove artwork

Implements spec Item 2b. Depends on Task 2.

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Inspector/ArtworkInspectorView.swift`

**Interfaces:**
- Consumes: `ArtworkService.removeCached(hash: String)` (Task 2); `LibraryViewModel.indexDiskCache` made internal (Task 3).

- [ ] **Step 1: Add the confirmation state and the remove method**

In `Sources/CrateDiggerApp/UI/Carbon/Inspector/ArtworkInspectorView.swift`, add to the `@State` block (after `@State private var isDirty = false`, line 21):

```swift
    /// The image awaiting a remove confirmation, if any.
    @State private var pendingRemoval: URL? = nil
```

Add these two methods immediately before `private func loadManifest()` (line 277):

```swift
    /// Move one artwork file to the Trash and forget it everywhere: the manifest's
    /// three filename-keyed maps, and the thumbnail cache entry for its bytes.
    ///
    /// Trash rather than delete — this can be someone's only scan of a booklet page,
    /// and there is no undo otherwise.
    private func removeArtwork(_ url: URL) {
        guard let album = album, let representative = album.tracks.first?.track.fileURL else { return }
        let albumFolder = representative.deletingLastPathComponent()
        let fileName = url.lastPathComponent

        // Hash the bytes before trashing — afterwards they're unreadable, and the
        // thumbnail cache is keyed by content hash.
        let hash = (try? Data(contentsOf: url)).map { SHA256.hash(data: $0).compactMap { String(format: "%02x", $0) }.joined() }

        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            model.appAlert = .error(
                title: "Couldn't remove artwork",
                message: "“\(fileName)” could not be moved to the Trash: \(error.localizedDescription)"
            )
            return
        }

        // Drop the file from every map keyed by filename, else orphans accumulate.
        manifest.roles[fileName] = nil
        manifest.discSides?[fileName] = nil
        manifest.discNumbers?[fileName] = nil
        if manifest.discSides?.isEmpty == true { manifest.discSides = nil }
        if manifest.discNumbers?.isEmpty == true { manifest.discNumbers = nil }

        do {
            try manifest.save(to: albumFolder)
        } catch {
            model.appAlert = .error(
                title: "Artwork removed, but the manifest didn't save",
                message: "“\(fileName)” is in the Trash, but its role couldn't be cleared: \(error.localizedDescription)"
            )
        }

        if let hash { model.artworkService.removeCached(hash: hash) }

        model.indexDiskCache.invalidate(
            albumFolderPath: albumFolder.path,
            filePaths: album.tracks.map { $0.track.fileURL.path }
        )
        loadManifest()
        model.refreshLibrary()
    }
```

- [ ] **Step 2: Add the ✕ badge to each thumbnail**

In the same file, inside the grid cell, wrap the thumbnail `Image` in a `ZStack` carrying the badge. Replace the `if let nsImage = thumbnails[url] { … }` block (lines 117-127) with:

```swift
                            if let nsImage = thumbnails[url] {
                                ZStack(alignment: .topTrailing) {
                                    Image(nsImage: nsImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 100, height: 100)
                                        .clipped()
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 4)
                                                .stroke(theme.isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.1), lineWidth: 1)
                                        )
                                        .cornerRadius(4)

                                    Button(action: { pendingRemoval = url }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 15))
                                            .foregroundColor(.white)
                                            .background(Circle().fill(Color.black.opacity(0.65)))
                                    }
                                    .buttonStyle(.plain)
                                    .padding(4)
                                    .help("Remove this image (moves it to the Trash)")
                                }
                            } else {
```

- [ ] **Step 3: Add the confirmation alert**

In the same file, add this modifier to the root `VStack` — directly after the existing `.sheet(isPresented: $showingSearch, …) { … }` block's closing brace (line 227):

```swift
        .alert(
            "Remove “\(pendingRemoval?.lastPathComponent ?? "")”?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { url in
            Button("Move to Trash", role: .destructive) {
                removeArtwork(url)
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { _ in
            Text("The file moves to the Trash and is removed from this album's artwork.")
        }
```

- [ ] **Step 4: Add the CryptoKit import**

At the top of the file, add `import CryptoKit` after `import SwiftUI` (line 1) — `removeArtwork` hashes the file bytes.

`model.artworkService` is already internal (`LibraryViewModel.swift:561`) and `indexDiskCache` was made internal in Task 3, so no further visibility changes are needed.

- [ ] **Step 5: Build and verify**

Run: `swift build && .build/arm64-apple-macosx/debug/CrateDiggerApp`

Select an album with several images. Hover a thumbnail → ✕ appears. Click → alert names the file. Confirm → the file is in the Trash (check Finder), gone from the grid, and `.cratedigger-art.json` no longer mentions it (`cat "<album folder>/.cratedigger-art.json"`). Cancel → nothing happens.

- [ ] **Step 6: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon/Inspector/ArtworkInspectorView.swift Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift
git commit -m "feat(artwork): remove artwork from the ART grid

Confirm, then trash the file, clear its manifest entries, and drop its
cached thumbnail.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Gallery underline + visible multi-selection  ⟶ cherry-pick to 1.0.3

Fixes spec Item 3 and Item 5 causes 1-2. Keep this commit self-contained.

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Main/Browser/ArtworkGalleryView.swift:83-86` and `:156-218`

- [ ] **Step 1: Delete the shadowing `selectAlbum` and call the model's**

In `Sources/CrateDiggerApp/UI/Carbon/Main/Browser/ArtworkGalleryView.swift`, replace the local `selectAlbum` (lines 80-86):

```swift
    /// Single-click: select the album (highlights the cover here and the row in
    /// the list browser, and drives the inspector's track list) without leaving
    /// the grid.
    private func selectAlbum(_ album: Album) {
        model.selectedArtistID = album.artistID
        model.selectedAlbumID = album.id
    }
```

with:

```swift
    /// Single-click: select the album (highlights the cover here and the row in
    /// the list browser, and drives the inspector's track list) without leaving
    /// the grid.
    ///
    /// Routes through the model's modifier-aware selectAlbum rather than setting
    /// the anchor directly — the old local version shadowed it, which is why
    /// ⌘-click and ⇧-click did nothing in the gallery.
    private func selectAlbum(_ album: Album, command: Bool = false, shift: Bool = false) {
        model.selectAlbum(album, command: command, shift: shift, ordered: allAlbums, flat: true)
    }
```

- [ ] **Step 2: Replace the frame highlight with an underline, and read the selection set**

In the same file, replace `albumCoverCell(_:)` lines 156-175 — from `let selected = …` down to and including the two `.onTapGesture` lines — with:

```swift
    private func albumCoverCell(_ album: Album) -> some View {
        // isAlbumSelected, not selectedAlbumID: the anchor alone ignored
        // selectedAlbumIDs, so ⌘A and ⌘-click selected albums the gallery
        // never drew.
        let selected = model.isAlbumSelected(album.id)
        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                GalleryAlbumCoverView(album: album, size: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.black.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.15), radius: 4, y: 2)
                    .matchedGeometryEffect(id: album.id, in: artNamespace)
                    .contentShape(Rectangle())
                    // Single click selects (highlights + drives the inspector track
                    // list); double click opens the full album page.
                    .onTapGesture(count: 2) { openDetail(album) }
                    .onTapGesture(count: 1) { selectAlbum(album) }
```

Then, immediately after the closing `}` of the `ZStack(alignment: .bottomTrailing)` (i.e. after the "Fetch Art badge" block ends at line 205) and **before** `Text(album.title)`, insert the underline:

```swift
            // Selection reads as an underline rather than a frame: the empty
            // jewel case is 1.13:1 (the spine adds width outside the square lid)
            // and letterboxes inside the square tile, so a frame on the tile
            // bounds can never hug it. An underline doesn't have to.
            RoundedRectangle(cornerRadius: 1.5)
                .fill(selected ? theme.orange : Color.clear)
                .frame(height: 3)
                .shadow(color: selected ? theme.orange.opacity(0.5) : .clear, radius: 4)
```

- [ ] **Step 3: Build and verify**

Run: `swift build && .build/arm64-apple-macosx/debug/CrateDiggerApp`

Switch the browser to Gallery. Confirm: clicking a cover shows an orange underline, no frame. ⌘-click adds a second underline. ⇧-click underlines a range. Right-click → Select All underlines every tile.

- [ ] **Step 4: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon/Main/Browser/ArtworkGalleryView.swift
git commit -m "fix(gallery): underline selection, and draw multi-selection at all

The tile read selectedAlbumID only, so selectedAlbumIDs — set by the
gallery's own Select All, and by cmd/shift-click — was never drawn. A
local selectAlbum also shadowed the model's modifier-aware one, so those
clicks had nowhere to land. Selection now reads as an underline: the empty
jewel case is 1.13:1 and letterboxes in a square tile, so a frame on the
tile bounds could never hug it.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: ⌘A in the gallery  ⟶ cherry-pick to 1.0.3

Fixes spec Item 5 cause 3. Keep this commit self-contained.

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+MultiSelect.swift:97-102`

- [ ] **Step 1: Make `selectAllInSource` gallery-aware**

In `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+MultiSelect.swift`, replace `selectAllInSource()` (lines 97-102) with:

```swift
    func selectAllInSource() {
        // The gallery is a bool that overlays the browser, not a BrowserLayout
        // case — so without this, ⌘A in gallery mode selected whatever the
        // hidden list browser was showing (often tracks, which the gallery
        // cannot draw).
        if showArtworkGallery {
            selectAllAlbums()
            return
        }
        switch browserLayout {
        case .full, .albumTrack: selectAllAlbums()
        case .track:             selectAllTracks()
        }
    }
```

- [ ] **Step 2: Build and verify**

Run: `swift build && .build/arm64-apple-macosx/debug/CrateDiggerApp`

Switch to Gallery, click the grid, press ⌘A. Every tile shows the underline from Task 6. Verify it still selects tracks in the flat `.track` list layout with the gallery off.

- [ ] **Step 3: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+MultiSelect.swift
git commit -m "fix(gallery): make CMD+A select albums when the gallery is showing

selectAllInSource switched on browserLayout, which has no gallery case —
the gallery is an orthogonal bool — so CMD+A selected the hidden list
browser's items instead.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Gallery keyboard navigation

Fixes spec Item 5 cause 4. Also adds the scroll-follow that Task 9 needs.

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift` (add a `@Published`)
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+ArrowNav.swift:31-43`
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Main/Browser/ArtworkGalleryView.swift:21-23`, `:40-57`

**Interfaces:**
- Produces: `LibraryViewModel.galleryColumnsPerRow: Int` (set by the view, read by arrow nav); `moveGallerySelection(by: Int)`.

- [ ] **Step 1: Add the published column count**

In `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift`, next to `@Published var showArtworkGallery` (line 152), add:

```swift
    /// Columns the gallery grid is currently laying out. Published by the view
    /// (only it knows the pane width) and read by ↑/↓ arrow nav, which has to
    /// move by a whole row.
    @Published var galleryColumnsPerRow: Int = 1
```

- [ ] **Step 2: Add the gallery branch to arrow nav**

In `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+ArrowNav.swift`, replace `handleBrowserArrowNav` (lines 30-43) with:

```swift
    /// Handle a bare arrow key as browser navigation. Returns true when consumed.
    func handleBrowserArrowNav(_ event: NSEvent) -> Bool {
        // Bare arrows only — ⌘/⌥/⌃/⇧ fall through (⌘-arrows = transport/volume).
        // Arrows always carry .function/.numericPad, so those are not "modifiers".
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              isBrowserKeyContext() else { return false }

        // The gallery is a grid, not columns: ←/→ step one cover, ↑/↓ a whole row.
        if showArtworkGallery {
            switch event.keyCode {
            case 126: moveGallerySelection(by: -galleryColumnsPerRow); return true  // up
            case 125: moveGallerySelection(by:  galleryColumnsPerRow); return true  // down
            case 123: moveGallerySelection(by: -1); return true                     // left
            case 124: moveGallerySelection(by:  1); return true                     // right
            default:  return false
            }
        }

        switch event.keyCode {
        case 126: moveBrowserSelection(by: -1); return true   // up
        case 125: moveBrowserSelection(by:  1); return true   // down
        case 123: moveBrowserFocus(by: -1);     return true   // left
        case 124: moveBrowserFocus(by:  1);     return true   // right
        default:  return false
        }
    }

    /// Step the gallery selection through `allAlbumsSorted`, clamped at both ends.
    /// `delta` is ±1 for a cover or ±`galleryColumnsPerRow` for a row.
    func moveGallerySelection(by delta: Int) {
        let items = allAlbumsSorted
        guard !items.isEmpty else { return }
        let current = selectedAlbumID.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        let next = items[min(max(current + delta, 0), items.count - 1)]
        selectAlbum(next, command: false, shift: false, ordered: items, flat: true)
    }
```

- [ ] **Step 3: Own the column count in the grid, and scroll to follow selection**

In `Sources/CrateDiggerApp/UI/Carbon/Main/Browser/ArtworkGalleryView.swift`, delete the `columns` constant (lines 21-23):

```swift
    private let columns = [
        GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 18)
    ]
```

and add in its place:

```swift
    private static let tileSize: CGFloat = 120
    private static let gridSpacing: CGFloat = 18
    private static let gridPadding: CGFloat = 18

    /// `.adaptive` resolves its column count at layout time and never reports it,
    /// but ↑/↓ arrow nav has to move by a whole row — so the grid owns the count
    /// explicitly rather than re-deriving SwiftUI's arithmetic and hoping it matches.
    private func columnCount(for width: CGFloat) -> Int {
        let usable = max(width - Self.gridPadding * 2, Self.tileSize)
        return max(1, Int((usable + Self.gridSpacing) / (Self.tileSize + Self.gridSpacing)))
    }

    private func gridColumns(for width: CGFloat) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Self.gridSpacing),
              count: columnCount(for: width))
    }
```

Then replace the `ScrollViewReader` block (lines 40-57) with:

```swift
                    GeometryReader { geo in
                        ScrollViewReader { proxy in
                            ScrollView(.vertical, showsIndicators: true) {
                                LazyVGrid(columns: gridColumns(for: geo.size.width), spacing: Self.gridSpacing) {
                                    ForEach(allAlbums) { album in
                                        albumCoverCell(album)
                                            .id(album.id)
                                    }
                                }
                                .padding(Self.gridPadding)
                            }
                            // Bring the selected album (synced with the list browser)
                            // into view, falling back to the last opened one.
                            .onAppear {
                                model.galleryColumnsPerRow = columnCount(for: geo.size.width)
                                if let id = model.selectedAlbumID ?? lastOpenedID {
                                    proxy.scrollTo(id, anchor: .center)
                                }
                            }
                            .onChange(of: geo.size.width) { width in
                                model.galleryColumnsPerRow = columnCount(for: width)
                            }
                            // Follow the selection — arrow nav and Go to Current Song
                            // both move it off screen otherwise. Mirrors ColumnList.
                            .onChange(of: model.selectedAlbumID) { target in
                                guard let target else { return }
                                withAnimation(.easeOut(duration: 0.16)) {
                                    proxy.scrollTo(target, anchor: .center)
                                }
                            }
                        }
                    }
```

- [ ] **Step 4: Build and verify**

Run: `swift build && .build/arm64-apple-macosx/debug/CrateDiggerApp`

In Gallery: ←/→ move one cover; ↑/↓ move one row; the grid scrolls to keep the selection visible; the selection clamps at the first and last album rather than wrapping. Resize the window and confirm ↑/↓ still moves exactly one row.

Known accepted behaviour: with the in-pane album **detail page** open, arrows still move the grid's selection behind it. The detail page tracks its own `detailAlbumID`, so nothing visibly changes — noted in the spec, not fixed here.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+ArrowNav.swift Sources/CrateDiggerApp/UI/Carbon/Main/Browser/ArtworkGalleryView.swift
git commit -m "feat(gallery): arrow-key navigation

Left/right step one cover, up/down a whole row. The grid now owns its
column count (adaptive never reports one) and scrolls to follow the
selection, which it previously only did on appear.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: Playing Now

Implements spec Item 4. Depends on Task 8's scroll-follow.

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift` (add `revealNowPlaying`)
- Modify: `Sources/CrateDiggerApp/UI/MainWindowController.swift` (forwarder)
- Modify: `Sources/CrateDiggerApp/AppDelegate.swift` (menu item + validation)
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Footer/TransportCluster.swift`

**Interfaces:**
- Produces: `LibraryViewModel.revealNowPlaying()`; `MainWindowController.revealNowPlaying()`; `MainWindowController.hasNowPlayingTrack: Bool`.

- [ ] **Step 1: Add `revealNowPlaying` to the view model**

In `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift`, immediately after the `nowPlayingTrack` computed property (which ends at line 923), add:

```swift
    /// Select the playing track's album so the browser and inspector both jump to
    /// it. No-op when the playing track isn't in the current source's index — the
    /// queue can outlive a source switch, and silently swapping crates under the
    /// user is worse than doing nothing.
    func revealNowPlaying() {
        guard let playing = nowPlayingTrack,
              let album = album(containing: playing.track.id) else { return }
        clearMultiSelection()
        selectedArtistID = album.artistID
        selectedAlbumID = album.id
        selectedTrackID = playing.track.id
    }
```

- [ ] **Step 2: Add the window-controller forwarders**

In `Sources/CrateDiggerApp/UI/MainWindowController.swift`, after `var hasLoadedTracks` (ends line 98), add:

```swift
    var hasNowPlayingTrack: Bool {
        hostingController.model.nowPlayingTrack != nil
    }

    func revealNowPlaying() {
        hostingController.model.revealNowPlaying()
    }
```

- [ ] **Step 3: Add the menu item and its validation**

In `Sources/CrateDiggerApp/AppDelegate.swift`, add the action next to the other playback actions — after `togglePlayPause` (ends line 182):

```swift
    @objc private func goToCurrentSong(_ sender: Any?) {
        mainWindowController?.revealNowPlaying()
    }
```

In the View menu builder, after `viewMenuItem.submenu = viewMenu` is set up — insert before line 510 (`viewMenuItem.submenu = viewMenu`):

```swift
        viewMenu.addItem(.separator())
        // ⌘L is what Music.app binds "Go to Current Song" to — muscle memory for free.
        viewMenu.addItem(makeItem(title: "Go to Current Song", action: #selector(goToCurrentSong(_:)), key: "l"))
```

In `validateMenuItem` (line 340), add a case before `default:`:

```swift
        case #selector(goToCurrentSong(_:)):
            return mainWindowController?.hasNowPlayingTrack ?? false
```

- [ ] **Step 4: Add the footer button**

In `Sources/CrateDiggerApp/UI/Carbon/Footer/TransportCluster.swift`, add as the first item inside the `HStack` (before the `shuffle` toggle at line 10):

```swift
            transportButton(systemName: "scope", label: "Go to Current Song (⌘L)") {
                model.revealNowPlaying()
            }
            .disabled(model.nowPlayingTrack == nil)
```

- [ ] **Step 5: Build and verify**

Run: `swift build && .build/arm64-apple-macosx/debug/CrateDiggerApp`

Play a track, scroll the browser far away, then press ⌘L and separately click the footer button. Both jump the browser to the playing album and update the inspector. Verify in **both** list and gallery modes. With nothing playing, the button is dimmed and the menu item disabled.

- [ ] **Step 6: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift Sources/CrateDiggerApp/UI/MainWindowController.swift Sources/CrateDiggerApp/AppDelegate.swift Sources/CrateDiggerApp/UI/Carbon/Footer/TransportCluster.swift
git commit -m "feat(playback): Go to Current Song (footer button + CMD+L)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: Search and Add Album Covers

Implements spec Item 5b.

**Files:**
- Create: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+BatchArtwork.swift`
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift:1862-1894` (delete `fetchRemoteArtwork`)
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Main/Browser/ArtworkGalleryView.swift` (context menu + spinner)

**Interfaces:**
- Consumes: `RemoteArtworkService.fetchArtwork(artist:album:) async throws -> ArtworkAsset`; `ArtworkService.prepareCompatibleArtwork(asset:profile:maxDimension:) throws -> ArtworkAsset`; `LibraryViewModel.albumsFetchingArtwork: Set<String>`; `isFetchingArtwork(for:) -> Bool`.
- Produces: `LibraryViewModel.searchAndAddCovers(for albums: [Album])`.

- [ ] **Step 1: Delete the dead `fetchRemoteArtwork`**

In `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift`, delete `fetchRemoteArtwork(for:)` entirely (lines 1862-1894). It has no callers and this task supersedes it. Keep `isFetchingArtwork(for:)` (line 1858) and `applyFetchedArtwork` (line 1896) — both are used elsewhere.

Run `grep -rn "fetchRemoteArtwork" Sources/` afterwards; the only hit should be the explanatory comment at `ArtworkGalleryView.swift:577`. Update that comment to read:

```swift
            // Apply the image we just downloaded directly — no second iTunes
            // round-trip.
```

- [ ] **Step 2: Write the batch service**

Create `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+BatchArtwork.swift`:

```swift
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
    private func applyBatchCovers(_ found: [(target: CoverTarget, asset: ArtworkAsset)]) {
        guard !found.isEmpty else { return }

        var assetByTrackID: [UUID: ArtworkAsset] = [:]
        for (target, asset) in found {
            artworkService.ingest(asset)
            indexDiskCache.invalidate(albumFolderPath: target.folder.path, filePaths: target.filePaths)
            for id in target.trackIDs { assetByTrackID[id] = asset }
        }

        func applyArtwork(_ loaded: LoadedTrack) -> LoadedTrack {
            guard let asset = assetByTrackID[loaded.track.id] else { return loaded }
            var newTrack = loaded.track
            var newMetadata = loaded.metadata
            // Folder cover (cover.jpg), not embedded — matches what we wrote and
            // how a rescan would re-resolve it.
            newTrack.artworkSource = .folderImage
            newTrack.artworkHash = asset.hash
            newTrack.artworkDimensions = asset.dimensions
            newMetadata.artwork = asset
            return LoadedTrack(track: newTrack, metadata: newMetadata, recordMarkers: loaded.recordMarkers)
        }

        localIndex = buildIndex(localIndex.allTracks.map(applyArtwork))
        prepCrateTracks = prepCrateTracks.map(applyArtwork)
        index = buildIndex(index.allTracks.map(applyArtwork))

        NotificationCenter.default.post(name: NSNotification.Name("CrateDiggerArtworkImported"), object: nil)
    }
}
```

- [ ] **Step 3: Add the context-menu item**

In `Sources/CrateDiggerApp/UI/Carbon/Main/Browser/ArtworkGalleryView.swift`, replace `albumContextMenu(_:)` (lines 222-235) with:

```swift
    /// Right-click on a cover: the shared album actions plus the gallery's own
    /// artwork/booklet items.
    @ViewBuilder
    private func albumContextMenu(_ album: Album) -> some View {
        BrowserContextMenu.album(album, model: model)
        Divider()
        if album.artworkHash == nil {
            Button("Search Cover Art Online…") {
                searchAlbum = album
                searchArtworkOnline(for: album)
            }
        }
        // Mirrors BrowserContextMenu.album's usesSelection rule: act on the whole
        // selection when the right-clicked album is part of it, else just this one.
        let batchTargets = batchCoverTargets(for: album)
        Button(batchTargets.count > 1 ? "Search & Add Covers (\(batchTargets.count) Albums)" : "Search & Add Cover") {
            model.searchAndAddCovers(for: batchTargets)
        }
        if album.booklet != nil {
            Button("Open Booklet") { openBooklet(album) }
        }
    }

    /// The albums a batch cover action should run on.
    private func batchCoverTargets(for album: Album) -> [Album] {
        guard model.selectedAlbumIDs.count > 1, model.selectedAlbumIDs.contains(album.id) else {
            return [album]
        }
        let ids = model.selectedAlbumIDs
        return allAlbums.filter { ids.contains($0.id) }
    }
```

- [ ] **Step 4: Add the per-tile spinner**

In the same file, inside `albumCoverCell`'s `ZStack(alignment: .bottomTrailing)`, immediately after the "Fetch Art badge if artwork missing" block closes (before the `ZStack`'s closing brace), add:

```swift
                // First consumer of albumsFetchingArtwork — batch cover search
                // marks each album while its match is in flight.
                if model.isFetchingArtwork(for: album) {
                    ZStack {
                        Color.black.opacity(0.45)
                        ProgressView().controlSize(.small)
                    }
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .allowsHitTesting(false)
                }
```

- [ ] **Step 5: Build and clear any concurrency diagnostics**

Run: `swift build`
Expected: `Build complete!`

The batch service was written to avoid the usual traps: the outer `Task` is `@MainActor`, so `found` and `albumsFetchingArtwork` are plain main-actor state (no inout-across-await); `fetchAndWriteCover` is `nonisolated static`, so it runs off the main actor; `CoverTarget` is `Sendable` and `RemoteArtworkService` is an `actor`, so the `addTask` closures capture only sendable values. If a strict-concurrency diagnostic still fires, it names the offending capture — fix that capture; do not reach for `@unchecked Sendable`.

- [ ] **Step 6: Verify**

Run: `.build/arm64-apple-macosx/debug/CrateDiggerApp`

In Gallery, ⌘-click 3-4 albums that show the empty jewel case → right-click → "Search & Add Covers (4 Albums)". Confirm: spinners appear per tile, covers land, `cover.jpg` exists in each album folder at ≤600px on the long edge (`sips -g pixelWidth -g pixelHeight "<folder>/cover.jpg"`), and the final alert counts matches and misses.

Then select a mix of covered and uncovered albums and confirm the covered ones are **untouched** (their `cover.jpg` mtime doesn't change).

- [ ] **Step 7: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+BatchArtwork.swift Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift Sources/CrateDiggerApp/UI/Carbon/Main/Browser/ArtworkGalleryView.swift
git commit -m "feat(artwork): Search & Add Album Covers for a gallery selection

Best iTunes match per album by metadata, written as a 600px device-ready
cover.jpg next to the music. Skips albums that already have art, and
rebuilds the indexes once for the whole batch rather than per album.

Removes the dead fetchRemoteArtwork this supersedes.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 11: Full verification pass

**Files:** none — verification only.

- [ ] **Step 1: Run the whole test suite**

Run: `scripts/test.sh`
Expected: all tests pass. If anything unrelated fails, stop and report — do not "fix" it as part of this plan.

- [ ] **Step 2: Walk the spec's GUI checklist**

Run: `swift build && .build/arm64-apple-macosx/debug/CrateDiggerApp`

Work through every item in the spec's "GUI verification checklist" section:

1. ART tab: SAVE menu holds the toggle; the checkbox row is gone; setting persists.
2. Grid order: Main Cover first, then Back, Disc, booklets.
3. ✕ on a thumbnail → confirm → file in Trash, gone from grid, manifest clean.
4. Gallery: orange underline on selected; empty boxes and real covers agree.
5. ⌘A selects all albums and **every** tile shows it.
6. Arrows move by 1 horizontally, by a row vertically; the grid scrolls to follow.
7. ⌘L and the footer button jump to the playing album in both panes.
8. Select several coverless albums → Search & Add Covers → spinners, then covers; already-covered albums in the selection are untouched.

- [ ] **Step 3: Report the one deferred decision**

Spec Item 3 leaves the ~7pt letterbox in place: empty jewel cases sit slightly above their underline while real covers sit flush. Look at a gallery row mixing both and report to the user whether it needs the one-line fix (`EmptyMediaCase.swift:21`, change the aspect ratio to `1`). Do not make that change unilaterally — it was explicitly deferred pending this look.

- [ ] **Step 4: Report for release**

Do **not** bump the version, build, or changelog. Report to the user that the work is ready and that `press the record` runs the release. Remind them the 1.0.3 cherry-picks are the Task 3, 6 and 7 commits.

---

## Cherry-pick reference for 1.0.3

After this plan lands on `beta/1.1.0-theming`, the stable-bound commits are:

| Task | Commit subject | Why stable |
|---|---|---|
| 3 | `fix(artwork): stale disk cache, silent save failure, unstable cover pick` | Three real bugs, one losing user edits silently |
| 6 | `fix(gallery): underline selection, and draw multi-selection at all` | Selection state set but never drawn |
| 7 | `fix(gallery): make CMD+A select albums when the gallery is showing` | ⌘A acts on the wrong collection |

Task 6 touches `ArtworkGalleryView.swift`, which the theming branch also edits — expect a conflict in the tile's `theme.orange` usage and resolve toward `main`'s theme API.

Tasks 1, 2, 4, 5, 8, 9, 10 are features and stay on beta.
