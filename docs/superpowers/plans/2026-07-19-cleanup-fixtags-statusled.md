# Cleanup Rework · FIX TAGS Multi-Album · Status LED — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reviewable, accurate duplicate cleanup; per-album FIX TAGS matching; a global header status LED.

**Architecture:** Detection/partition logic lands in `CrateDiggerCore` with XCTests; `LibraryViewModel` gains an activity hub, an off-main cleanup scan, and a match-batch queue; SwiftUI changes stay in `CrateDiggerApp` (cleanup sheet, match sheet, header overlay).

**Tech Stack:** Swift 5 / SwiftPM, XCTest via `scripts/test.sh`, SwiftUI + AppKit, CryptoKit.

**Spec:** `docs/superpowers/specs/2026-07-19-cleanup-fixtags-statusled-design.md`

## Global Constraints

- Run tests with `scripts/test.sh` (optionally `--filter ClassName`), never bare `swift test`.
- Testable logic goes in `CrateDiggerCore`; UI glue in `CrateDiggerApp`. Keep the target boundary clean.
- `LibraryViewModel` is `@MainActor`; long work runs in `Task.detached` and hops back via `await MainActor.run`.
- No SwiftUI `Material` fills in Carbon surfaces (idle-GPU invariant). Animations must not run while idle.
- Informational alerts use the existing `appAlert = .info(...)` / `.error(...)` pattern.
- Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Build check: `swift build` (debug). Full suite: `scripts/test.sh`.

---

### Task 1: Activity hub on LibraryViewModel

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift` (near the other `@Published` vars, ~line 298 by `oledNotice`)
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift:1924` (`downloadAndImportArtwork`, first adopter)

**Interfaces:**
- Produces: `@discardableResult func beginActivity(_ label: String) -> UUID`, `func endActivity(_ id: UUID)`, `var isWorking: Bool`, `var activityLabels: [String]` — all on `LibraryViewModel`, `@MainActor`. Tasks 2, 6, 10 consume these exact names.

No Core code → no new unit test (repo convention: `LibraryViewModel` is UI glue). Verification is the build plus Task 2's visual check.

- [ ] **Step 1: Add the hub state and API**

In `LibraryViewModel.swift`, below the `@Published var oledNotice: String?` declaration (~line 298), add:

```swift
    /// Global activity registry driving the header status LED. Anything
    /// long-running registers a label; the LED lights while any are active
    /// (or any legacy busy flag below is set).
    @Published private(set) var activities: [UUID: String] = [:]

    @discardableResult
    func beginActivity(_ label: String) -> UUID {
        let id = UUID()
        activities[id] = label
        return id
    }

    func endActivity(_ id: UUID) {
        activities.removeValue(forKey: id)
    }

    /// One switch for "is the app doing something" — new registrations OR the
    /// pre-existing per-feature busy flags, so already-instrumented features
    /// light the LED with no changes.
    var isWorking: Bool {
        !activities.isEmpty
            || scanProgress.isRunning
            || conversionProgress.isRunning
            || isRepairingMetadata
            || !albumsFetchingArtwork.isEmpty
    }

    var activityLabels: [String] {
        Array(activities.values).sorted()
    }
```

- [ ] **Step 2: Instrument downloadAndImportArtwork**

In `downloadAndImportArtwork` (line 1924), first line of the body add:

```swift
        let activity = beginActivity("Importing artwork…")
        defer { endActivity(activity) }
```

(The function is `async` on the main actor; `defer` fires after `applyImportedArtwork`.)

- [ ] **Step 3: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift
git commit -m "feat(activity): begin/end activity hub + isWorking on LibraryViewModel

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: StatusLED view + header overlay

**Files:**
- Create: `Sources/CrateDiggerApp/UI/Carbon/Header/StatusLED.swift`
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Header/HeaderShell.swift`

**Interfaces:**
- Consumes: `model.isWorking`, `model.activityLabels` (Task 1).
- Produces: `struct StatusLED: View` overlaid on the header; no other task depends on it.

- [ ] **Step 1: Create StatusLED.swift**

```swift
import SwiftUI

/// Tiny activity lamp in the header's top-right corner: recessed-dark when
/// idle, amber breathing pulse while the app is working. Hover lists what's
/// running. The repeatForever animation is attached only while working and
/// cancelled on idle — an idle LED must cost zero GPU (same rule as the
/// Material ban).
struct StatusLED: View {
    @Environment(\.carbon) private var theme
    @EnvironmentObject private var model: LibraryViewModel
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(model.isWorking
                  ? theme.orange.opacity(pulsing ? 1.0 : 0.35)
                  : Color.black.opacity(0.35))
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 1))
            .shadow(color: model.isWorking ? theme.orange.opacity(pulsing ? 0.7 : 0.15) : .clear,
                    radius: pulsing ? 4 : 1)
            .help(helpText)
            .onChange(of: model.isWorking) { working in
                if working {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        pulsing = true
                    }
                } else {
                    // Reassigning the property with a non-repeating animation
                    // cancels the repeatForever — nothing animates while idle.
                    withAnimation(.linear(duration: 0.1)) { pulsing = false }
                }
            }
    }

    private var helpText: String {
        guard model.isWorking else { return "Idle" }
        let labels = model.activityLabels
        return labels.isEmpty ? "Working…" : labels.joined(separator: " · ")
    }
}
```

- [ ] **Step 2: Overlay it on the header**

In `HeaderShell.swift`, the body is a single `HStack` (brand · OLED · switcher). Append an overlay to that `HStack`:

```swift
        HStack(spacing: geometry.mainGap) {
            BrandBlock()
                .frame(width: geometry.brandWidth, alignment: .leading)
            OLEDDisplay()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            ViewSwitcherColumn()
                .frame(width: geometry.viewSwitchWidth)
        }
        .overlay(alignment: .topTrailing) {
            StatusLED()
                .padding(.top, 4)
                .padding(.trailing, 4)
        }
```

- [ ] **Step 3: Build and visually verify**

Run: `swift build` → `Build complete!`
Then launch `.build/arm64-apple-macosx/debug/CrateDiggerApp`, import a folder or fetch artwork, and confirm the lamp pulses top-right during the work and goes dark after. (`pkill -f CrateDiggerApp` when done.) If the user is around, ask them to confirm the look matches the Carbon aesthetic.

- [ ] **Step 4: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon/Header/StatusLED.swift Sources/CrateDiggerApp/UI/Carbon/Header/HeaderShell.swift
git commit -m "feat(header): status LED activity lamp, top-right overlay

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Core — duplicate match-key normalization (TDD)

**Files:**
- Modify: `Sources/CrateDiggerCore/Services/LibraryCleanupService.swift`
- Test: `Tests/CrateDiggerCoreTests/LibraryCleanupServiceTests.swift`

**Interfaces:**
- Produces: `public enum DuplicateScanMode: String, Sendable { case strict, broad }`; `static func duplicateMatchKey(artist: String, title: String) -> String?` and `static func normalizeForMatch(_ raw: String) -> String` on `LibraryCleanupService`. Task 4 consumes all three.

- [ ] **Step 1: Write the failing tests**

Append to `LibraryCleanupServiceTests.swift` (inside the class):

```swift
    func testNormalizeForMatchStripsDecorationAndPunctuation() {
        XCTAssertEqual(
            LibraryCleanupService.normalizeForMatch("One More Time (Remastered 2011)"),
            "one more time"
        )
        XCTAssertEqual(
            LibraryCleanupService.normalizeForMatch("Harder, Better, Faster, Stronger [Explicit]"),
            "harder better faster stronger"
        )
        // Different-recording markers are NOT stripped.
        XCTAssertEqual(
            LibraryCleanupService.normalizeForMatch("Around the World (Live)"),
            "around the world live"
        )
    }

    func testNormalizeForMatchUnifiesFeaturing() {
        let a = LibraryCleanupService.normalizeForMatch("Stardust feat. Ben Diamond")
        let b = LibraryCleanupService.normalizeForMatch("Stardust ft. Ben Diamond")
        let c = LibraryCleanupService.normalizeForMatch("Stardust featuring Ben Diamond")
        XCTAssertEqual(a, b)
        XCTAssertEqual(b, c)
    }

    func testDuplicateMatchKeyNilForEmptyTitle() {
        XCTAssertNil(LibraryCleanupService.duplicateMatchKey(artist: "Daft Punk", title: "  "))
        XCTAssertNotNil(LibraryCleanupService.duplicateMatchKey(artist: "", title: "Aerodynamic"))
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test.sh --filter LibraryCleanupServiceTests`
Expected: compile FAILURE — `normalizeForMatch` / `duplicateMatchKey` not defined.

- [ ] **Step 3: Implement**

In `LibraryCleanupService.swift`, add above the class:

```swift
public enum DuplicateScanMode: String, Sendable {
    /// Same recording AND same (normalized) album tag — re-rips/re-encodes of
    /// one release. A missing album tag on one copy drops the pair out of
    /// strict; documented ceiling.
    case strict
    /// Same recording anywhere in the library (album + compilation copies).
    case broad
}
```

Inside the class, add:

```swift
    // MARK: - Duplicate match normalization

    /// Decoration tails that don't change the recording: "(Remastered 2011)",
    /// "[Explicit]", "(Deluxe Edition)"… "(Live)" / "(Radio Edit)" are NOT
    /// listed — those are different recordings; the duration guard backstops
    /// either way.
    private static let decorationPattern = try! NSRegularExpression(
        pattern: "[\\(\\[][^\\)\\]]*(remaster|reissue|explicit|deluxe|anniversary|edition|bonus|mono|stereo)[^\\)\\]]*[\\)\\]]",
        options: [.caseInsensitive]
    )

    static func normalizeForMatch(_ raw: String) -> String {
        var s = raw.lowercased()
        s = Self.decorationPattern.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " "
        )
        // Longest first so "featuring" never leaves a stray "uring".
        s = s.replacingOccurrences(of: "featuring", with: "feat")
        s = s.replacingOccurrences(of: "feat.", with: "feat")
        s = s.replacingOccurrences(of: "ft.", with: "feat")
        s = String(s.map { $0.isLetter || $0.isNumber || $0 == " " ? $0 : " " })
        return s.split(separator: " ").joined(separator: " ")
    }

    /// nil when the title normalizes to nothing — untitled tracks never group.
    static func duplicateMatchKey(artist: String, title: String) -> String? {
        let cleanTitle = normalizeForMatch(title)
        guard !cleanTitle.isEmpty else { return nil }
        return normalizeForMatch(artist) + " :: " + cleanTitle
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `scripts/test.sh --filter LibraryCleanupServiceTests`
Expected: all PASS (new tests + existing ones untouched).

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerCore/Services/LibraryCleanupService.swift Tests/CrateDiggerCoreTests/LibraryCleanupServiceTests.swift
git commit -m "feat(cleanup): normalized duplicate match keys + scan mode enum

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Core — findDuplicates rework: duration guard, modes, ignore list, single stat pass (TDD)

**Files:**
- Modify: `Sources/CrateDiggerCore/Services/LibraryCleanupService.swift` (`findDuplicates`, `isBetterTrack`)
- Test: `Tests/CrateDiggerCoreTests/LibraryCleanupServiceTests.swift`

**Interfaces:**
- Consumes: Task 3's `DuplicateScanMode`, `duplicateMatchKey`, `normalizeForMatch`.
- Produces: `public func findDuplicates(in index: LibraryIndex, mode: DuplicateScanMode = .strict, ignoring ignoredSignatures: Set<String> = []) -> [DuplicateGroup]` and `public static func signature(for group: DuplicateGroup) -> String`. Task 6 consumes both.

- [ ] **Step 1: Write the failing tests**

Append to `LibraryCleanupServiceTests.swift`:

```swift
    private func makeLoaded(
        _ dir: URL, file: String, title: String, artist: String = "Daft Punk",
        album: String = "Discovery", duration: Double, format: String = "mp3",
        bitrate: Int = 320
    ) throws -> LoadedTrack {
        let url = dir.appendingPathComponent(file)
        try "stub \(file)".write(to: url, atomically: true, encoding: .utf8)
        let track = AudioTrack(
            fileURL: url, title: title, artist: artist, album: album,
            durationSeconds: duration, formatName: format, bitrateKbps: bitrate,
            sampleRateHz: 44100
        )
        return LoadedTrack(track: track, metadata: ConversionMetadata())
    }

    func testDurationGuardSplitsDifferentEdits() throws {
        try withTemporaryDirectory(prefix: "CleanupDuration") { dir in
            let radio = try makeLoaded(dir, file: "radio.mp3", title: "One More Time", duration: 212)
            let extended = try makeLoaded(dir, file: "ext.mp3", title: "One More Time", duration: 421)
            let close = try makeLoaded(dir, file: "close.mp3", title: "One More Time", duration: 213.5)

            let index = LibraryIndex.build(from: [radio, extended, close])
            let groups = LibraryCleanupService().findDuplicates(in: index, mode: .broad)

            // 212 & 213.5 cluster; 421 stands alone → exactly one group of two.
            XCTAssertEqual(groups.count, 1)
            XCTAssertEqual(groups[0].worstTracks.count, 1)
            let ids = Set([groups[0].bestTrack.track.id] + groups[0].worstTracks.map { $0.track.id })
            XCTAssertEqual(ids, Set([radio.track.id, close.track.id]))
        }
    }

    func testUnknownDurationNeverClusters() throws {
        try withTemporaryDirectory(prefix: "CleanupNoDuration") { dir in
            let a = try makeLoaded(dir, file: "a.mp3", title: "Voyager", duration: 0)
            let b = try makeLoaded(dir, file: "b.mp3", title: "Voyager", duration: 0)
            let index = LibraryIndex.build(from: [a, b])
            XCTAssertTrue(LibraryCleanupService().findDuplicates(in: index, mode: .broad).isEmpty)
        }
    }

    func testStrictRequiresSameAlbumBroadDoesNot() throws {
        try withTemporaryDirectory(prefix: "CleanupModes") { dir in
            let onAlbum = try makeLoaded(dir, file: "album.flac", title: "Da Funk",
                                         album: "Homework", duration: 328, format: "flac", bitrate: 900)
            let onComp = try makeLoaded(dir, file: "comp.mp3", title: "Da Funk",
                                        album: "House Classics Vol. 2", duration: 328)
            let index = LibraryIndex.build(from: [onAlbum, onComp])
            let service = LibraryCleanupService()

            XCTAssertTrue(service.findDuplicates(in: index, mode: .strict).isEmpty)
            XCTAssertEqual(service.findDuplicates(in: index, mode: .broad).count, 1)
        }
    }

    func testIgnoredSignatureSuppressesGroup() throws {
        try withTemporaryDirectory(prefix: "CleanupIgnore") { dir in
            let a = try makeLoaded(dir, file: "a.flac", title: "Aerodynamic", duration: 208, format: "flac")
            let b = try makeLoaded(dir, file: "b.mp3", title: "Aerodynamic", duration: 208)
            let index = LibraryIndex.build(from: [a, b])
            let service = LibraryCleanupService()

            let groups = service.findDuplicates(in: index, mode: .strict)
            XCTAssertEqual(groups.count, 1)
            let sig = LibraryCleanupService.signature(for: groups[0])
            XCTAssertFalse(sig.isEmpty)

            XCTAssertTrue(service.findDuplicates(in: index, mode: .strict, ignoring: [sig]).isEmpty)
        }
    }
```

Also update the two existing duplicate tests, which create tracks without durations (unknown duration must never cluster now): in `testFindDuplicatesPriority` (and any other duplicate-finding test in this file), add `durationSeconds: 200,` to every `AudioTrack(...)` init that participates in a duplicate group, and change its `findDuplicates(in:)` call to `findDuplicates(in: index, mode: .strict)` (albums already match there).

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test.sh --filter LibraryCleanupServiceTests`
Expected: compile FAILURE — `findDuplicates(in:mode:ignoring:)` / `signature(for:)` not defined.

- [ ] **Step 3: Implement**

In `LibraryCleanupService.swift`: add `import CryptoKit` at the top. Replace the whole `findDuplicates(in:)` body and `isBetterTrack` with:

```swift
    public func findDuplicates(
        in index: LibraryIndex,
        mode: DuplicateScanMode = .strict,
        ignoring ignoredSignatures: Set<String> = []
    ) -> [DuplicateGroup] {
        // Tracks inside a grouped release must only ever match duplicates within the
        // SAME member pressing — never across versions of the same release.
        var versionAlbumOfTrack: [UUID: String] = [:]
        for album in index.allAlbums where album.isVersionGroup {
            for version in album.versions ?? [] {
                for loaded in version.tracks {
                    versionAlbumOfTrack[loaded.track.id] = version.id
                }
            }
        }

        var grouped: [String: [LoadedTrack]] = [:]
        for loadedTrack in index.allTracks {
            guard var key = Self.duplicateMatchKey(
                artist: loadedTrack.track.artist, title: loadedTrack.track.title
            ) else { continue }
            if mode == .strict {
                key += " @@ " + Self.normalizeForMatch(loadedTrack.track.album)
            }
            if let version = versionAlbumOfTrack[loadedTrack.track.id] {
                key += " :: \(version)"
            }
            grouped[key, default: []].append(loadedTrack)
        }

        // One stat pass up front — the old code stat'd inside the sort
        // comparator (O(n log n) syscalls on a 14k library).
        var sizeByPath: [String: Int64] = [:]
        for tracks in grouped.values where tracks.count > 1 {
            for t in tracks {
                let path = t.track.fileURL.path
                if sizeByPath[path] == nil {
                    sizeByPath[path] =
                        (try? fileManager.attributesOfItem(atPath: path)[.size] as? Int64).flatMap { $0 } ?? 0
                }
            }
        }

        var duplicateGroups: [DuplicateGroup] = []
        for (_, tracks) in grouped where tracks.count > 1 {
            for cluster in Self.durationClusters(tracks) where cluster.count > 1 {
                let sorted = cluster.sorted { isBetterTrack(lhs: $0, rhs: $1, sizeByPath: sizeByPath) }
                guard let best = sorted.first else { continue }
                let group = DuplicateGroup(bestTrack: best, worstTracks: Array(sorted.dropFirst()))
                guard !ignoredSignatures.contains(Self.signature(for: group)) else { continue }
                duplicateGroups.append(group)
            }
        }
        return duplicateGroups.sorted {
            $0.bestTrack.track.title.localizedCaseInsensitiveCompare($1.bestTrack.track.title) == .orderedAscending
        }
    }

    /// Sort by duration, split where the gap to the previous track exceeds 2s.
    /// Unknown durations (≤0) never cluster — flagging a "duplicate" we can't
    /// time-verify is how legit files get trashed.
    static func durationClusters(_ tracks: [LoadedTrack]) -> [[LoadedTrack]] {
        let known = tracks
            .filter { $0.track.durationSeconds > 0 }
            .sorted { $0.track.durationSeconds < $1.track.durationSeconds }
        var clusters: [[LoadedTrack]] = []
        for track in known {
            if let prev = clusters.last?.last,
               track.track.durationSeconds - prev.track.durationSeconds <= 2.0 {
                clusters[clusters.count - 1].append(track)
            } else {
                clusters.append([track])
            }
        }
        return clusters
    }

    /// Stable identity for "this exact set of files is not a duplicate":
    /// SHA-256 over the sorted member paths. Membership changes → new
    /// signature → the group resurfaces for review. Intended.
    public static func signature(for group: DuplicateGroup) -> String {
        let joined = ([group.bestTrack] + group.worstTracks)
            .map { $0.track.fileURL.standardizedFileURL.path }
            .sorted()
            .joined(separator: "\n")
        return SHA256.hash(data: Data(joined.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func isBetterTrack(lhs: LoadedTrack, rhs: LoadedTrack, sizeByPath: [String: Int64]) -> Bool {
        // 1. Format Priority: Lossless > Lossy
        let lhsIsLossless = isLossless(format: lhs.track.formatName ?? "")
        let rhsIsLossless = isLossless(format: rhs.track.formatName ?? "")
        if lhsIsLossless != rhsIsLossless {
            return lhsIsLossless
        }

        // 2. Bitrate comparison
        let lhsBitrate = lhs.track.bitrateKbps ?? 0
        let rhsBitrate = rhs.track.bitrateKbps ?? 0
        if lhsBitrate != rhsBitrate {
            return lhsBitrate > rhsBitrate
        }

        // 3. Sample Rate comparison
        let lhsSampleRate = lhs.track.sampleRateHz ?? 0
        let rhsSampleRate = rhs.track.sampleRateHz ?? 0
        if lhsSampleRate != rhsSampleRate {
            return lhsSampleRate > rhsSampleRate
        }

        // 4. File Size fallback (larger is better)
        return (sizeByPath[lhs.track.fileURL.path] ?? 0) > (sizeByPath[rhs.track.fileURL.path] ?? 0)
    }
```

Add near the top of the file (detection-site upgrade note), just above `findDuplicates`:

```swift
    // ponytail: metadata + duration matching only. If re-encodes with rewritten
    // tags still slip through, the upgrade path is chromaprint fingerprints via
    // the bundled ffmpeg (-f chromaprint), cached by path+mtime.
```

- [ ] **Step 4: Run to verify pass**

Run: `scripts/test.sh --filter LibraryCleanupServiceTests`
Expected: all PASS.

- [ ] **Step 5: Run the full suite (findDuplicates signature changed)**

Run: `scripts/test.sh`
Expected: all PASS. If another call site of `findDuplicates(in:)` fails to compile, it gets the defaulted parameters automatically — only label changes would break; fix by adding `mode:` labels as the compiler directs.

- [ ] **Step 6: Commit**

```bash
git add Sources/CrateDiggerCore/Services/LibraryCleanupService.swift Tests/CrateDiggerCoreTests/LibraryCleanupServiceTests.swift
git commit -m "feat(cleanup): duration-guarded duplicate detection with strict/broad modes and ignore list

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: PreferencesStore keys

**Files:**
- Modify: `Sources/CrateDiggerCore/Services/PreferencesStore.swift`

**Interfaces:**
- Produces: `PreferencesStore.duplicateScanMode: String?` and `PreferencesStore.duplicateIgnoreSignatures: [String]`. Task 6 consumes both.

- [ ] **Step 1: Add the keys**

In the `private enum Key` block (line 17), add following the existing pattern:

```swift
        static let duplicateScanMode = "duplicateScanMode"
        static let duplicateIgnoreSignatures = "duplicateIgnoreSignatures"
```

Next to the other computed vars (e.g. after `deleteOriginalsAfterCopy`), add:

```swift
    /// Last-used duplicate scan mode ("strict" / "broad"); nil → strict.
    public var duplicateScanMode: String? {
        get { defaults.string(forKey: Key.duplicateScanMode) }
        set { defaults.set(newValue, forKey: Key.duplicateScanMode) }
    }

    /// Signatures of duplicate groups the user marked "not a duplicate".
    public var duplicateIgnoreSignatures: [String] {
        get { defaults.stringArray(forKey: Key.duplicateIgnoreSignatures) ?? [] }
        set { defaults.set(newValue, forKey: Key.duplicateIgnoreSignatures) }
    }
```

- [ ] **Step 2: Build and commit**

Run: `swift build` → `Build complete!`

```bash
git add Sources/CrateDiggerCore/Services/PreferencesStore.swift
git commit -m "feat(cleanup): persist duplicate scan mode + ignore signatures

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: View model — off-main cleanup scan, mode, ignore

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift:1623-1661` (`scanForCleanup`, `resolveDuplicates`)

**Interfaces:**
- Consumes: Tasks 1, 4, 5 (`beginActivity`/`endActivity`, `findDuplicates(in:mode:ignoring:)`, `signature(for:)`, store keys).
- Produces: `@Published var isCleanupScanning: Bool`, `@Published var duplicateScanMode: DuplicateScanMode`, `func ignoreDuplicateGroup(_ group: DuplicateGroup)`. Task 7 consumes these; Task 8 replaces `resolveDuplicates`.

- [ ] **Step 1: Add published state**

Near the other cleanup state (where `deadTracks` / `duplicateGroups` are declared — grep `@Published var deadTracks`), add:

```swift
    @Published var isCleanupScanning = false
    @Published var duplicateScanMode: DuplicateScanMode =
        DuplicateScanMode(rawValue: PreferencesStore.shared.duplicateScanMode ?? "") ?? .strict {
        didSet {
            guard oldValue != duplicateScanMode else { return }
            PreferencesStore.shared.duplicateScanMode = duplicateScanMode.rawValue
            scanForCleanup()
        }
    }
```

- [ ] **Step 2: Replace scanForCleanup with the detached version**

Replace the existing `scanForCleanup()` (line 1623) with:

```swift
    func scanForCleanup() {
        guard !isCleanupScanning else { return }
        isCleanupScanning = true
        let activity = beginActivity("Scanning library for cleanup…")
        let snapshot = localIndex
        let mode = duplicateScanMode
        let ignored = Set(PreferencesStore.shared.duplicateIgnoreSignatures)

        Task.detached(priority: .userInitiated) {
            let cleanup = LibraryCleanupService()
            let dead = cleanup.findDeadTracks(in: snapshot)
            let dups = cleanup.findDuplicates(in: snapshot, mode: mode, ignoring: ignored)
            await MainActor.run {
                // Don't flag tracks on a disconnected drive as "dead" — the files
                // aren't gone, the volume is just unplugged, and purging their
                // references would wreck an external library that's merely offline.
                self.deadTracks = dead.filter { self.offlineVolumeName(for: $0.track.fileURL) == nil }
                self.duplicateGroups = dups
                self.recomputeMissingFiles()
                self.isCleanupScanning = false
                self.endActivity(activity)
            }
        }
    }

    func ignoreDuplicateGroup(_ group: DuplicateGroup) {
        let sig = LibraryCleanupService.signature(for: group)
        var sigs = PreferencesStore.shared.duplicateIgnoreSignatures
        if !sigs.contains(sig) { sigs.append(sig) }
        PreferencesStore.shared.duplicateIgnoreSignatures = sigs
        duplicateGroups.removeAll { $0.id == group.id }
    }
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: `Build complete!` — callers of `scanForCleanup()` (lines ~2431, 2456, `+MissingFiles.swift`) are signature-compatible.

- [ ] **Step 4: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift
git commit -m "feat(cleanup): off-main cleanup scan with mode + persistent ignore list

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Cleanup sheet UI — mode toggle, checkboxes, per-group ignore, trash selected

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Main/Browser/LibraryCleanupView.swift` (the `duplicatesTab` section, lines ~150-236)

**Interfaces:**
- Consumes: Task 6's `isCleanupScanning`, `duplicateScanMode`, `ignoreDuplicateGroup(_:)`; Task 8's `resolveDuplicates(selected:)` — **implement Task 8 before building this task**, or build both then. (If executing strictly in order, this task's build fails until Task 8 lands; acceptable — commit both together only if needed. Preferred: do Task 8 first if working solo.)
- Produces: UI only.

- [ ] **Step 1: Add selection state**

At the top of `LibraryCleanupView` with the other `@State`:

```swift
    /// Checked = will be trashed. Keyed by standardized file path; reseeded
    /// (worst versions pre-checked) whenever scan results change.
    @State private var checkedPaths: Set<String> = []
```

- [ ] **Step 2: Replace duplicatesTab**

Replace the whole `duplicatesTab` computed property with:

```swift
    private var duplicatesTab: some View {
        VStack(spacing: 0) {
            modeBar

            if model.isCleanupScanning {
                VStack {
                    Spacer()
                    ProgressView().controlSize(.large)
                    Text("Scanning…")
                        .font(CarbonFont.sans(12))
                        .foregroundColor(.secondary)
                        .padding(.top, 8)
                    Spacer()
                }
            } else if model.duplicateGroups.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 40))
                        .foregroundColor(.green)
                        .padding(.bottom, 8)
                    Text("No duplicate tracks found!")
                        .font(CarbonFont.sans(12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List {
                    ForEach(model.duplicateGroups) { group in
                        duplicateGroupRow(group)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(maxHeight: .infinity)

                HStack(spacing: 12) {
                    Button("Export Best versions") { chooseAndExport(best: true) }
                    Button("Export Dup versions") { chooseAndExport(best: false) }
                    Spacer()
                    KeyButton(style: checkedPaths.isEmpty ? .disabled : .selected, action: trashSelected) {
                        Text("TRASH SELECTED (\(checkedPaths.count))")
                            .font(CarbonFont.mono(9, weight: .bold))
                            .tracking(1.2)
                    }
                    .frame(width: 200, height: geometry.keyHeight)
                    .disabled(checkedPaths.isEmpty)
                }
                .padding(14)
                .background(theme.chassisHi)
            }
        }
        .onChange(of: model.duplicateGroups) { groups in
            checkedPaths = Set(groups.flatMap { g in
                g.worstTracks.map { $0.track.fileURL.standardizedFileURL.path }
            })
        }
        .onAppear {
            checkedPaths = Set(model.duplicateGroups.flatMap { g in
                g.worstTracks.map { $0.track.fileURL.standardizedFileURL.path }
            })
        }
    }

    /// STRICT / BROAD selector — strict = re-encodes of the same release only,
    /// broad = the same recording anywhere.
    private var modeBar: some View {
        HStack(spacing: 8) {
            Text("MATCH")
                .font(CarbonFont.mono(8, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(theme.ink3)
            ForEach([DuplicateScanMode.strict, .broad], id: \.self) { mode in
                Button(action: { model.duplicateScanMode = mode }) {
                    Text(mode == .strict ? "STRICT · SAME ALBUM" : "BROAD · ANY RELEASE")
                        .font(CarbonFont.mono(8.5, weight: .bold))
                        .foregroundColor(model.duplicateScanMode == mode ? theme.orange : theme.ink3)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 10)
                        .background(model.duplicateScanMode == mode ? theme.chassis : theme.chassisHi)
                        .cornerRadius(3)
                }
                .buttonStyle(.carbonHover)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(theme.chassisHi)
        .overlay(Rectangle().fill(Color.black.opacity(0.12)).frame(height: 1), alignment: .bottom)
    }

    private func duplicateGroupRow(_ group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(group.bestTrack.track.artist) - \(group.bestTrack.track.title)")
                    .font(CarbonFont.sans(12.5, weight: .bold))
                    .foregroundColor(theme.ink)
                Spacer()
                Button("NOT A DUPLICATE") { model.ignoreDuplicateGroup(group) }
                    .font(CarbonFont.mono(8, weight: .bold))
                    .foregroundColor(.secondary)
                    .help("Never flag this exact set of files again")
            }

            memberRow(group.bestTrack, isBest: true)
            ForEach(group.worstTracks) { worst in
                memberRow(worst, isBest: false)
            }
        }
        .padding(.vertical, 8)
    }

    private func memberRow(_ loaded: LoadedTrack, isBest: Bool) -> some View {
        let path = loaded.track.fileURL.standardizedFileURL.path
        let checked = checkedPaths.contains(path)
        return HStack {
            Button(action: {
                if checked { checkedPaths.remove(path) } else { checkedPaths.insert(path) }
            }) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundColor(checked ? .red : theme.ink3)
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help(checked ? "Will be moved to Trash" : "Will be kept")

            if isBest {
                Image(systemName: "star.fill")
                    .foregroundColor(.yellow)
                    .font(.system(size: 9))
                Text("[BEST]")
                    .font(CarbonFont.mono(8, weight: .bold))
                    .foregroundColor(.green)
            } else {
                Text("[DUP]")
                    .font(CarbonFont.mono(8, weight: .bold))
                    .foregroundColor(.red)
            }
            Text(specString(for: loaded))
                .font(CarbonFont.mono(9))
            Text(loaded.track.fileURL.lastPathComponent)
                .font(CarbonFont.mono(9))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.leading, 8)
    }

    private func trashSelected() {
        let selected = model.duplicateGroups.flatMap { group in
            ([group.bestTrack] + group.worstTracks).filter {
                checkedPaths.contains($0.track.fileURL.standardizedFileURL.path)
            }
        }
        model.resolveDuplicates(selected: selected)
    }
```

Note: `DuplicateGroup` is `Hashable` (its declaration in `LibraryCleanupService.swift`), so `.onChange(of: model.duplicateGroups)` compiles. `import CrateDiggerCore` is already present; `DuplicateScanMode` is public in Core.

- [ ] **Step 3: Build (after Task 8) and visually verify**

Run: `swift build` → `Build complete!`
Launch the debug binary → Inspector → CLEANUP → Duplicates tab: toggle STRICT/BROAD (rescans), flip checkboxes, ignore a group (it disappears and stays gone after Re-Scan), TRASH SELECTED shows a live count. Ask the user to GUI-verify.

- [ ] **Step 4: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon/Main/Browser/LibraryCleanupView.swift
git commit -m "feat(cleanup): reviewable duplicates UI — mode toggle, checkboxes, per-group ignore

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: Trash selected + crate repointing

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift:1646-1661` (replace `resolveDuplicates()`)

**Interfaces:**
- Consumes: `purgeTracksFromLibraryState(paths:)` (line 2991), `loadCrateTracks`/`saveCrateTracks`, `availableCrates`, `prepCrateTracks`.
- Produces: `func resolveDuplicates(selected: [LoadedTrack])` — consumed by Task 7's `trashSelected()`. The old no-arg `resolveDuplicates()` is deleted.

Design note (refines the spec): the spec suggested reusing `rewriteTrackPaths`, but that helper maps entries in `localIndex` too — repointing there would duplicate the keeper. A dedicated crate-only repoint helper is smaller and correct; `localIndex` cleanup stays with `purgeTracksFromLibraryState`.

- [ ] **Step 1: Replace resolveDuplicates**

Replace the existing `resolveDuplicates()` (line 1646) with:

```swift
    /// Trash exactly the reviewed selection. Crates that referenced a trashed
    /// file whose group keeps a better copy are repointed to the kept copy —
    /// cleanup must not silently shrink a DJ's crates.
    func resolveDuplicates(selected: [LoadedTrack]) {
        guard !selected.isEmpty else { return }
        let selectedPaths = Set(selected.map { $0.track.fileURL.standardizedFileURL.path })

        // Keeper per group = best-ranked survivor (members are best-first).
        var repoint: [String: LoadedTrack] = [:]
        for group in duplicateGroups {
            let members = [group.bestTrack] + group.worstTracks
            let survivors = members.filter {
                !selectedPaths.contains($0.track.fileURL.standardizedFileURL.path)
            }
            guard let keeper = survivors.first else { continue }
            for member in members
            where selectedPaths.contains(member.track.fileURL.standardizedFileURL.path) {
                repoint[member.track.fileURL.standardizedFileURL.path] = keeper
            }
        }

        do {
            try LibraryCleanupService().deleteTracks(selected, useTrash: true)
            repointCrateReferences(repoint)
            purgeTracksFromLibraryState(paths: selectedPaths)
            scanForCleanup()
            let repointNote = repoint.isEmpty ? "" : " Crate entries now point at the kept copies."
            appAlert = .info(title: "Duplicates Cleared",
                             message: "\(selected.count) file\(selected.count == 1 ? "" : "s") moved to Trash.\(repointNote)")
        } catch {
            appAlert = .error(title: "Clear Failed", message: error.localizedDescription)
            scanForCleanup()
        }
    }

    /// Swap trashed paths for their keepers inside every crate + the prep
    /// crate, deduping by path (a crate holding both copies must end with one
    /// keeper entry, not two). Runs BEFORE purge, which then only strips
    /// references that had no surviving groupmate.
    private func repointCrateReferences(_ repoint: [String: LoadedTrack]) {
        guard !repoint.isEmpty else { return }

        func rewrite(_ tracks: [LoadedTrack]) -> [LoadedTrack]? {
            var seen = Set<String>()
            var changed = false
            var result: [LoadedTrack] = []
            for entry in tracks {
                let path = entry.track.fileURL.standardizedFileURL.path
                let mapped = repoint[path] ?? entry
                if repoint[path] != nil { changed = true }
                let mappedPath = mapped.track.fileURL.standardizedFileURL.path
                guard seen.insert(mappedPath).inserted else { changed = true; continue }
                result.append(mapped)
            }
            return changed ? result : nil
        }

        for crateName in availableCrates {
            if let rewritten = rewrite(loadCrateTracks(name: crateName)) {
                saveCrateTracks(rewritten, name: crateName, persistStore: false)
            }
        }
        if let rewritten = rewrite(prepCrateTracks) {
            prepCrateTracks = rewritten
        }
    }
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!` (Task 7's `trashSelected()` now resolves; nothing else called the old no-arg `resolveDuplicates` besides the old UI button, replaced in Task 7.)

- [ ] **Step 3: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift
git commit -m "feat(cleanup): selective duplicate trashing with crate repointing

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: Core — partitionByAlbum (TDD)

**Files:**
- Modify: `Sources/CrateDiggerCore/Services/MetadataMatchService.swift`
- Test: `Tests/CrateDiggerCoreTests/MetadataMatchServiceTests.swift`

**Interfaces:**
- Consumes: `OutputPathPlanner().albumFolderKey(for:)` (`OutputPathPlanner.swift:157`, returns `AlbumFolderKey: Hashable`).
- Produces: `public static func partitionByAlbum(_ tracks: [LoadedTrack]) -> [[LoadedTrack]]` on `MetadataMatchService`. Task 10 consumes it.

- [ ] **Step 1: Write the failing test**

Append to `MetadataMatchServiceTests.swift` (match the file's existing helpers for building `LoadedTrack`s if present; otherwise this self-contained version):

```swift
    func testPartitionByAlbumSplitsAndPreservesFirstAppearanceOrder() {
        func loaded(_ file: String, album: String, artist: String = "Daft Punk") -> LoadedTrack {
            let track = AudioTrack(
                fileURL: URL(fileURLWithPath: "/tmp/\(file)"),
                title: file, artist: artist, album: album, durationSeconds: 200
            )
            var metadata = ConversionMetadata()
            metadata.artist = artist
            metadata.album = album
            return LoadedTrack(track: track, metadata: metadata)
        }

        let discovery1 = loaded("a.mp3", album: "Discovery")
        let homework1 = loaded("b.mp3", album: "Homework")
        let discovery2 = loaded("c.mp3", album: "Discovery")
        let homework2 = loaded("d.mp3", album: "Homework")

        let groups = MetadataMatchService.partitionByAlbum(
            [discovery1, homework1, discovery2, homework2]
        )

        XCTAssertEqual(groups.count, 2)
        // First-appearance order: Discovery group first.
        XCTAssertEqual(groups[0].map { $0.track.id }, [discovery1.track.id, discovery2.track.id])
        XCTAssertEqual(groups[1].map { $0.track.id }, [homework1.track.id, homework2.track.id])
    }

    func testPartitionByAlbumSingleAlbumPassthrough() {
        func loaded(_ file: String) -> LoadedTrack {
            let track = AudioTrack(
                fileURL: URL(fileURLWithPath: "/tmp/\(file)"),
                title: file, artist: "Daft Punk", album: "Discovery", durationSeconds: 200
            )
            var metadata = ConversionMetadata()
            metadata.artist = "Daft Punk"
            metadata.album = "Discovery"
            return LoadedTrack(track: track, metadata: metadata)
        }
        let tracks = [loaded("a.mp3"), loaded("b.mp3")]
        let groups = MetadataMatchService.partitionByAlbum(tracks)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].count, 2)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `scripts/test.sh --filter MetadataMatchServiceTests`
Expected: compile FAILURE — `partitionByAlbum` not defined.

- [ ] **Step 3: Implement**

In `MetadataMatchService.swift`, add below `query(for:)`:

```swift
    /// Split a selection into per-album groups using the same
    /// `albumFolderKey` invariant the browser index and conversion planner
    /// share — FIX TAGS must agree with the rest of the app on "what an album
    /// is". Groups come back in first-appearance order.
    public static func partitionByAlbum(_ tracks: [LoadedTrack]) -> [[LoadedTrack]] {
        let planner = OutputPathPlanner()
        var order: [AlbumFolderKey] = []
        var byKey: [AlbumFolderKey: [LoadedTrack]] = [:]
        for track in tracks {
            let key = planner.albumFolderKey(for: track)
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(track)
        }
        return order.compactMap { byKey[$0] }
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `scripts/test.sh --filter MetadataMatchServiceTests`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerCore/Services/MetadataMatchService.swift Tests/CrateDiggerCoreTests/MetadataMatchServiceTests.swift
git commit -m "feat(fixtags): partition selections by albumFolderKey before matching

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 10: View model — match queue + per-album matching

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift:464` (queue state next to `metadataMatches`)
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+MetadataRepair.swift` (`matchSelectionOnline` lines 181-206, `applyReleaseMatch` line 212)

**Interfaces:**
- Consumes: Task 9's `MetadataMatchService.partitionByAlbum(_:)`; Task 1's `beginActivity`/`endActivity`.
- Produces (Task 11 consumes all): on `LibraryViewModel` —
  - `struct MatchQueueProgress: Equatable { var current: Int; var total: Int }` (file-scope in `LibraryViewModel+MetadataRepair.swift`)
  - `@Published var pendingMatchBatches: [AlbumMatchBatch]`
  - `@Published var matchQueueProgress: MatchQueueProgress?`
  - `@Published var currentMatchAlbumLabel: String?`
  - `func advanceMatchQueue()` / `func cancelMatchQueue()`

- [ ] **Step 1: Add queue types and state**

In `LibraryViewModel+MetadataRepair.swift`, below `MetadataRepairConflictGroup`, add:

```swift
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
```

In `LibraryViewModel.swift`, next to `@Published var metadataMatches: [ReleaseMatch] = []` (line 464), add:

```swift
    /// FIX TAGS multi-album queue: `metadataMatches` is the batch under
    /// review; these are the ones behind it.
    @Published var pendingMatchBatches: [AlbumMatchBatch] = []
    @Published var matchQueueProgress: MatchQueueProgress?
    @Published var currentMatchAlbumLabel: String?
    /// Albums that came back with no online match — reported once at the end.
    var matchQueueNoMatchLabels: [String] = []
```

- [ ] **Step 2: Rework matchSelectionOnline**

In `LibraryViewModel+MetadataRepair.swift`, replace the whole `matchSelectionOnline` (lines 181-206) with:

```swift
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
```

- [ ] **Step 3: Make applyReleaseMatch advance the queue**

In `applyReleaseMatch` (line 212), change the first line from:

```swift
        metadataMatches = []
```

to:

```swift
        defer { advanceMatchQueue() }
```

(Every exit path — including the `guard` returns — must move to the next album or close out.)

- [ ] **Step 4: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel+MetadataRepair.swift
git commit -m "feat(fixtags): per-album match queue with OLED progress and end summary

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 11: Match sheet — queue header, SKIP, cancel semantics

**Files:**
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Inspector/MetadataMatchSheetView.swift` (header ~lines 49-65, footer ~lines 262-294, onChange ~line 44)
- Modify: `Sources/CrateDiggerApp/UI/Carbon/Inspector/InspectorPane.swift:59-61` (sheet binding)

**Interfaces:**
- Consumes: Task 10's `matchQueueProgress`, `currentMatchAlbumLabel`, `advanceMatchQueue()`, `cancelMatchQueue()`.

- [ ] **Step 1: Header shows the album position**

In `MetadataMatchSheetView.header`, replace the existing `if matches.count > 1 { ... }` block with:

```swift
            if let progress = model.matchQueueProgress {
                Text("ALBUM \(progress.current) OF \(progress.total)\(model.currentMatchAlbumLabel.map { " · \($0.uppercased())" } ?? "")")
                    .font(CarbonFont.mono(8, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(theme.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if matches.count > 1 {
                Text("\(candidateIndex + 1) OF \(matches.count) MATCHES")
                    .font(CarbonFont.mono(8, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(theme.ink4)
            }
```

- [ ] **Step 2: Reset the candidate pager when the batch changes**

On the root `VStack` (next to the existing `.onChange(of: candidateIndex)`), add:

```swift
        .onChange(of: model.currentMatchAlbumLabel) { _ in
            candidateIndex = 0
            seedChecks()
        }
```

- [ ] **Step 3: Footer — SKIP + queue-aware CANCEL**

In `footer(_:)`, replace the CANCEL button's action `{ model.metadataMatches = [] }` with `{ model.cancelMatchQueue() }`, and insert a SKIP button between CANCEL and APPLY:

```swift
            if model.matchQueueProgress != nil {
                KeyButton(style: .normal, action: { model.advanceMatchQueue() }) {
                    Text("SKIP")
                        .font(CarbonFont.mono(9, weight: .bold))
                }
                .frame(width: 80, height: CarbonLayout.keyHeight)
                .help("Leave this album unchanged and review the next one")
            }
```

- [ ] **Step 4: Sheet dismissal cancels the queue**

In `InspectorPane.swift` lines 59-61, change the binding's set closure from
`set: { if !$0 { model.metadataMatches = [] } }` to:

```swift
            set: { if !$0 { model.cancelMatchQueue() } }
```

- [ ] **Step 5: Build and visually verify**

Run: `swift build` → `Build complete!`
Launch the debug binary, select tracks from two different albums, press FIX TAGS: OLED shows "MATCHING TAGS… 1/2", the sheet shows "ALBUM 1 OF 2 · <name>", SKIP/APPLY advances, closing mid-queue abandons the rest, and a summary alert lists unmatched albums. Ask the user to GUI-verify.

- [ ] **Step 6: Commit**

```bash
git add Sources/CrateDiggerApp/UI/Carbon/Inspector/MetadataMatchSheetView.swift Sources/CrateDiggerApp/UI/Carbon/Inspector/InspectorPane.swift
git commit -m "feat(fixtags): album queue review — header position, SKIP, cancel-abandons-queue

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 12: Full verification

**Files:** none new.

- [ ] **Step 1: Full test suite**

Run: `scripts/test.sh`
Expected: all PASS.

- [ ] **Step 2: Release-shape build**

Run: `swift build`
Expected: `Build complete!` with no warnings introduced by this work.

- [ ] **Step 3: End-to-end app pass**

Launch `.build/arm64-apple-macosx/debug/CrateDiggerApp` and walk all three features once (cleanup scan + ignore + trash-selected on a scratch folder, FIX TAGS on a 2-album selection, LED pulsing during both and dark when idle). The user GUI-verifies before this sprint is called done; do not claim completion without it.
