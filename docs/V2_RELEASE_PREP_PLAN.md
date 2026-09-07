# 2.0.0 Final — Release Prep Plan

Status: **workstream 1 (gapless) is implemented; 2 and 3 are still plan
only.** Written against `v2` at `c4a3351` (2.0.0 RC 1, build 82). Work it on
the desktop in the order below; each phase ends with `scripts/test.sh` green
and a commit.

Done so far:

- **3.1, the 1.5.11 merge-back** (`e15b1d8`). Changelog section, stable
  appcast item, README and site footer. `website/roadmap.html` still diverges
  between the branches and is a copy decision, not a merge.
- **1, gapless playback** (`b348549`, `f2fc854`). Shipped roughly as designed
  below, with three departures worth knowing: the engine reports the handover
  the player *made* rather than the one we queued, and resolves it one runloop
  turn after the end notification because `currentItem` has not caught up by
  then; seek does **not** flush the look-ahead, because seeking does not change
  what plays next; and `indexAfterCurrentEnds()` is shared by the look-ahead
  and the end handler so the two can never disagree. 26 new tests, three of
  them against a real `AVQueuePlayer`. **Still needs the listening test below.**

Branch note: `claude/v2-release-prep-plan-8d2ndu` was originally cut from
`main` (1.5.11). It now sits on `origin/v2`. All line numbers below are v2.

Three workstreams, in the order they should land:

1. Gapless playback (code, Core + a little App wiring)
2. Performance audit in Xcode Instruments (measure first, then the fixes below)
3. Code check + cleanup (docs, dead code, dev harness, tests)

---

## 1. Gapless playback

### Where we are

There is no gapless path today. `PlaybackService` advances by calling
`load(queue:startIndex:autoPlay:)` from `onItemEnded`
(`Sources/CrateDiggerCore/Services/PlaybackService.swift:745-765`), which goes
`state = .loading` → `AVPlayerEngine.replaceCurrentItem(url:)` (`:166-201`) →
a brand-new `AVPlayerItem` → wait for `.readyToPlay` → `play()`. Every track
boundary therefore pays: item creation, asset load, the async
`loadTracks(withMediaType:)` for the level tap (`:269-279`), and a
`.loading → .playing` state round-trip through the main actor. On a
continuous album (live records, DJ mixes, classical) that is an audible gap
plus a meter/OLED blink.

The same core files are byte-identical between `main` and `v2`, so this change
is safe to build on v2 without a merge worry.

### Design (recommended)

Keep `AVPlayer`, do **not** switch to `AVQueuePlayer` wholesale. The service
already manages a queue with insert/move/remove semantics that
`AVQueuePlayer` would fight; and the DoP engine and DSD-decode paths must stay
untouched. Instead add a **one-item look-ahead** inside `AVPlayerEngine`:

- New engine protocol hook (default no-op so `FakeEngine` and
  `DoPPlaybackEngine` keep compiling):

  ```swift
  /// Pre-buffer the item that will follow the current one; nil clears it.
  func prepareNextItem(url: URL?)
  /// True when the prepared item is the one that just started, i.e. the
  /// transition happened without a reload.
  var didAdvanceGaplessly: Bool { get }
  ```

- Inside `AVPlayerEngine`, back the current `AVPlayer` with an
  `AVQueuePlayer` holding at most **two** items (current + next). On
  `prepareNextItem`, build the next `AVPlayerItem` via `makeItem(url:)`,
  attach a *second* `AudioLevelTap`/audio-mix (or reuse the tap with a
  per-item mix; the tap store is shared, so the meters simply continue), set
  `preferredForwardBufferDuration` a few seconds, and `insert(after: current)`.
  On `AVPlayerItemDidPlayToEndTime` for the current item the queue player
  advances itself; the engine reports `onItemEnded` as today, but with
  `didAdvanceGaplessly == true`.

- In `PlaybackService.onItemEnded`: if the engine advanced gaplessly and the
  next queue index is the same URL we prepared, **skip `load()`** and only
  update `currentIndex`, `durationSeconds`, `currentTimeSeconds = 0`, keep
  `state == .playing`, bump `loadGeneration`, and immediately call
  `prepareNext()` for the following track. Otherwise fall through to today's
  `load()`.

- `prepareNext()` is called after every `.readyToPlay`, after every queue edit
  (`insertNext`, `appendLast`, `removeFromQueue`, `moveInQueue`) and after
  `repeatMode` changes, and passes `nil` when:
  - the next track is a DSF/DSD (native DoP or ffmpeg decode path),
  - the next URL is a `ChunkedStreamLoader`-wrapped or remote stream
    (radio must keep the current behaviour),
  - `repeatMode == .one` (prepare the *same* URL instead so repeat-one is
    also gapless), or at the end of the queue with `repeatMode == .off`.

- Seek, `next()`, `previous()` and manual `load()` must **flush** the prepared
  item (`removeAllItems` except current) so a stale look-ahead never plays.
  The existing `loadGeneration` guard covers the decode race; add the same
  generation stamp to the prepared item.

### App-side wiring (`LibraryViewModel`)

- `onCurrentIndexChange` already resets scrobble state
  (`LibraryViewModel.swift:2961-2975`); it will still fire on a gapless
  advance because `currentIndex` changes. Verify `playbackStartTimestamp`
  and `updateNowPlaying` still happen once per track.
- `handlePlaybackStateChange` (`:2864-2894`) does Last.fm "now playing" on
  the `.playing` transition. A gapless advance never leaves `.playing`, so
  move the now-playing call to the index-change handler (or trigger it from
  both, de-duplicated by track ID).
- The "DECODING DSD…" OLED notice keys on `.loading`; unaffected because DSD
  is excluded from look-ahead.
- `LibraryViewModel+Resume` restores a paused queue via `load(... autoPlay:
  false)`; look-ahead should only be armed once the item is actually playing.
- Optional user control: an Advanced ▸ "Gapless playback" toggle in
  `PreferencesStore` defaulting **on**. Cheap, and gives testers an
  off-switch if a device misbehaves.

### Tests (Core, `Tests/CrateDiggerCoreTests`)

Extend `PlaybackServiceTests` with the fake engine gaining `prepareNextItem`
recording and a `simulateGaplessAdvance()`:

- prepares the next track after ready; re-prepares after Play Next / Play
  Last / remove / move; clears on last track with repeat off; prepares the
  same track with repeat one; wraps to index 0 with repeat all.
- a gapless advance changes `currentIndex` without passing through
  `.loading`, and fires `onCurrentIndexChange` exactly once.
- next track is DSF → no prepare; a wrapped stream URL → no prepare.
- manual `next()` / `seek` / `load` flushes the prepared item.
- decode-failure and native-DoP-fallback paths are unchanged (existing
  `PlaybackServiceDSDTests` / `PlaybackServiceDoPTests` stay green).

### Manual verification on the desktop

- A ripped live album (AAC and FLAC/ALAC), listen at the boundary with
  headphones; compare against Music.app.
- Same album with the mini player open, with EQ on, with an external output
  device selected (`setOutputDeviceUID` must apply to the queue player, not
  per item).
- Radio stream → local track → radio stream transitions.
- DSF album: still decodes/DoP as before, with the normal gap.
- Sleep timer "after this track" (`LibraryViewModel+Sleep`) still resolves on
  the boundary.

---

## 2. Performance audit (Xcode Instruments)

Goal: the app idles at ~0% CPU when nothing is playing, well under 5% while
playing with the window in the background, and launches without a beat on a
15k-track library. Measure on the packaged `.app` from `scripts/package-app.sh`
in **release** configuration (Sparkle and the bundled tools change the
launch profile).

### Instruments sessions to run (in this order, save each `.trace`)

| # | Template | Scenario | What to confirm |
|---|----------|----------|-----------------|
| 1 | Time Profiler | Play an album, hide the window behind another app, 60 s | audio-thread FFT and the 60 fps disc animator dominate |
| 2 | Time Profiler | Play, window visible, idle transport | `MeterDriver` polling, `SpinningRecordView` timers |
| 3 | SwiftUI ("Cause of View Update") | Scroll a 10k-track flat table while playing; then start a radio stream and watch 1 Hz | whole-`LibraryViewModel` observers re-rendering the browser |
| 4 | App Launch | Cold launch, 15k tracks, crates folder populated | `LibraryViewModel.init` synchronous work |
| 5 | Allocations + Leaks | Save a crate, switch source, open/close mini player 10× | unbounded caches, block observers never removed |
| 6 | Energy Log / `powermetrics` | Import a 2k-file folder | ffprobe spawn concurrency |
| 7 | Core Animation / Metal | OLED + LED meters visible, 30 s | overdraw of the skeuomorphic chassis layers |

### Measured, 2026-09-06 — read this before implementing any of section A

Everything below in A–F was written by reading code and estimating cost.
Measurement contradicts the ranking, so **the order in this list is wrong** and
several items are not worth doing at all. Numbers are from a **release** build
on the dev machine (Apple silicon, 8 P-cores + 4 E-cores), against a synthetic
15,000-track library.

> **Taken on a busy machine.** A DaVinci Resolve render was running throughout,
> with load average ~2.9 of 12 cores. Roughly nine cores were free, so
> contention was modest, but a single-threaded benchmark under load can be put
> on an efficiency core, which is worth 2–3× on its own.
>
> Every timing here is therefore an **upper bound**. That direction matters:
> "the FFT is negligible" and "idle is already 0 %" only get more true on a
> quiet machine, so those conclusions stand as they are. The absolute figures
> are the part to distrust — do **not** compare a post-fix number measured on
> an idle machine against these, or the fix will look like it did more than it
> did. The disk-vs-CPU split inside `LibraryIndex.build` is the single figure
> most worth taking again, because a video render competes for disk in
> particular, so the disk share is likely overstated relative to the CPU share.
>
> Unaffected by the load, and not worth re-running: the theme-logo decode count
> and the idle CPU figure (both counts, not durations), resident memory, and
> every functional check.

| Claim | Estimated | Measured (release) | Verdict |
|---|---|---|---|
| A1 FFT on every audio buffer | "biggest idle-CPU win" | **0.03 % of one core** (2.9 µs/call at 512-frame buffers) | **Not worth doing.** It reads as expensive only in a debug build, where it is 61 µs — 21× slower. |
| Idle CPU, window visible, nothing playing | target "~0 %" | **0.00 % of one core** over 20 s | **Already met.** The meter and disc timers self-halt at rest, as their comments claim. |
| D8 `TrackStore.save()` at 15k | ~365 ms | **139 ms**, 7 MB | Real, 2.6× smaller than the comment in the source says. That comment should be corrected. |
| D9 `LibraryIndex.build` at 15k | listed 9th | **889 ms cold, 362 ms warm** | **The largest main-actor stall found.** Ranked far too low here. |
| D11 `NSImage(contentsOf:)` in `ThemeLogo`'s body | "in a view body", implied hot | **2 decodes in 18 s of running** | **Not a problem.** The view has no stored properties, so SwiftUI does not re-invoke its body unless the theme actually changes. The `ponytail:` comment already in that file is correct and should stay. |
| D11 disc-image folder probing | "7 folders x 13 filenames on every now-playing change" | ~91 `stat`s per *track change* | Not worth touching. Sub-millisecond, and it happens once a song. |

Where `LibraryIndex.build`'s 362 ms warm actually goes, measured by
substitution:

| Part | Cost at 15k |
|---|---|
| Grouping with no disk branch at all | 188 ms |
| `albumFolderKey` per track | 71 ms |
| `versionSourceFolder` per track (regex + URL standardisation, recomputed ~12× per album) | 41 ms |
| `computeTotalSizeBytes` — one `stat` per track, for the OLED's GB readout | 55–65 ms, and far more on a real volume where the calls succeed |
| Per-album booklet/manifest scan | the rest of the cold 889 ms |

Two things temper D9 before anyone rushes at it. `selectSource` does **not**
rebuild — it switches between cached indexes — so clicking between crates was
never paying this. Every rebuild site follows an operation that is already slow
and visible (launch, scan, import, tag edit, delete). A 362 ms stall there is
worth removing but is not the emergency the raw number suggests, and
micro-optimising the parts above only reaches ~300 ms. **The only change that
alters what a user feels is moving the build off the main actor, which is an
architectural change across ~17 call sites and wants its own decision.**

### Still unmeasured — these need Instruments and a person

Nothing here could be measured without driving the UI and playing audio:

- **Session 1 / 2, CPU while playing.** Needs real playback.
- **Session 3, SwiftUI re-render pressure (finding C7).** Needs a 10k-row
  scroll. This is now the most likely remaining real problem, because it is
  the one plausible cost that has not been ruled out.
- **Session 4, cold launch on a real 15k library.** The synthetic numbers above
  bound the index build's share of it, nothing else.
- **Session 5, allocations and leaks under real use.** Note idle RSS measured
  **321 MB**, which is worth a look on its own.

### What landed from this section

- **Occlusion gate** (`47ce1dd`). The 60 fps disc animator and the 30 fps LED
  meters now halt while every window is occluded — findings B5's real content.
  This targets the plan's own goal of "well under 5 % while playing with the
  window in the background", which is exactly the case no measurement here
  could reach. Building it turned up two things only running it revealed:
  `occlusionState` reports "not visible" before the first window exists, which
  latched the flag off for the session, and the app-level notification fires
  just ahead of the window state settling.
- **Observer tokens** (`b2a182d`). Finding E13, fixed via one helper.

### Findings already visible from the code (fix after measuring)

Ordered by *estimated* payoff — see the measured table above, which supersedes
this ordering. File:line refs are v2.

**A. Audio hot path (biggest idle-CPU win)**
1. FFT runs on the real-time audio thread on every buffer, unconditionally —
   `Sources/CrateDiggerCore/Services/AudioLevelTap.swift:220-227` and
   `ProcessOutputLevelTap.swift:174-181` (2048-pt FFT, `SpectrumProcessor.swift:14-15`).
   Consumers only sample at 30 Hz (`UI/Carbon/Footer/MeterDriver.swift:66`).
   Fix: an atomic "spectrum wanted" flag set from `FooterLeftCluster`
   (`simpleHorizontalVU`, `:13, :49-52`) and cleared when the window is
   occluded; skip `compute` when clear.
2. Allocations and `NSLock` inside the render callback —
   `AudioLevelTap.swift:191` (`var levels: [Float] = []` grows per callback),
   `:93, :97, :106` (3-4 lock acquisitions), `SpectrumProcessor.swift:116`
   (returns internal buffer → CoW next call). Fix: preallocated fixed buffers,
   `os_unfair_lock` or a lock-free double buffer.
3. `MeterDriver` polls both level and spectrum providers every tick even in
   L/R-only mode (`MeterDriver.swift:80-88`), each pull allocating three
   arrays (`AudioLevelTap.swift:25-27`, `PlaybackService.swift:244-249`).
4. DoP render callback is a scalar per-frame Swift loop under a lock with a
   `DispatchQueue.main.async` from the render thread —
   `DoPPlaybackEngine.swift:172-224`. Only hot on DSD; vectorise if session 1
   shows it.

**B. Timers that never stop**
5. 60 fps disc animator, up to two instances (inspector + mini player), no
   occlusion gate — `UI/Carbon/Controls/SpinningRecordView.swift:529`,
   `@Published rotationAngle` at `:489`, holds `@ObservedObject model:
   LibraryViewModel` at `:23`. Fix: drive rotation with `TimelineView(.animation)`
   or a `CADisplayLink`, pause on `NSWindow.occlusionState`, and stop
   observing the whole view model.
6. 1 Hz `@Published` writes on the god object during radio and sleep timer —
   `LibraryViewModel+Radio.swift:162-168` (`radioUptimeSeconds`),
   `LibraryViewModel+Sleep.swift:45` (`sleepRemainingLabel`). Move both onto
   `PlaybackClock` (`LibraryViewModel.swift:47-50`), which already isolates
   `currentTime` for exactly this reason.

**C. SwiftUI re-render pressure**
7. Every browser pane observes all of `LibraryViewModel` (~110 `@Published`)
   — `UI/Carbon/Main/Browser/BrowserPane.swift:7, 79, 122, 151, 206, 321, 485, 547`,
   and each body does `ForEach(Array(x.enumerated()), ...)` (`:174, :230, :369`).
   Fix: slice per-pane state into small `ObservableObject`s (or `@Observable`
   on macOS 14+) and drop `enumerated()` in favour of indexed row IDs.
   Measure with session 3 before and after.

**D. Main-actor heavy work**
8. `TrackStore.save()` re-encodes the entire library on the main actor
   (`Services/TrackStore.swift:30, :79-92`; ~365 ms at 15k, per its own
   comment). Callers still taking the default `persistStore: true` in loops:
   `LibraryViewModel.swift:4118, 4132, 4154, 4159, 4173, 4516`. Fix: encode
   off-main (`BlockingWork`) and coalesce writes with a short debounce.
9. `LibraryIndex.build` on the main actor with disk reads per album
   (`Services/LibraryIndex.swift:84-198`, `:186-188`); main-thread call sites
   `LibraryViewModel.swift:1850-1857, 2309, 2337, 2815, 3088`. Build in a
   detached task, publish the result.
10. Launch: `LibraryViewModel.init` (`:1303-1451`) synchronously runs legacy
    migration (`:3966-3980`), `TrackStore.load()`, playlist listing, CD and
    device detection, `buildIndex`, then `fetchMissingMetadata()` which
    spawns yt-dlp per stream lacking a thumbnail
    (`LibraryViewModel+Radio.swift:69-92`). Defer everything after "first
    paint of the last-used source"; yt-dlp thumbnail fetches go behind a
    one-per-launch, off-main, rate-limited task.
11. `NSImage(contentsOf:)` inside a view body — `UI/Carbon/Header/ThemeLogo.swift:16`;
    `SpinningRecordView.swift:437-468` probes 7 folders × 13 filenames on
    every now-playing change. Cache by URL.

**E. Memory**
12. Unbounded dictionaries: `deviceIndexCache` (`LibraryViewModel.swift:1196`),
    `crateTracksCache` (`:3862`), `LibraryIndexDiskCache` (`LibraryIndex.swift:571-573`).
    `ArtworkService` limits (`:66-69`, ~208 MB total) are fine but worth a
    look on 8 GB machines.
13. Block-based `NotificationCenter` observers whose tokens are discarded;
    `deinit` calls `removeObserver(self)` which does not remove them —
    `LibraryViewModel.swift:1453-1508`, `AppDelegate.swift:44-50`. Keep the
    tokens and remove them.
14. DSD decode temp files (`Services/DSDDecoder.swift:51-52`) are only
    cleaned on the happy path in `PlaybackService`; add a launch-time sweep
    of `cratedigger-dsd-*.caf` (same pattern as `ArtworkStaging.sweep()`).

**F. Import energy**
15. Scan spawns `ffprobe` `activeProcessorCount`-wide
    (`Services/LibraryScanService.swift:136-142`). Consider P-core count and
    backing off on battery (`ProcessInfo.isLowPowerModeEnabled`).

Definition of done for this phase: before/after numbers for sessions 1, 3
and 4 recorded in `CHANGELOG.md` under 2.0.0 ("Changed"), and the fixes
that landed listed there.

---

## 3. Code check and cleanup

Survey result: no `TODO`/`FIXME`/`print` debris in `Sources/` or `Tests/`,
git tree clean, no generated artifacts tracked. The loose ends are mostly
release-hygiene and docs.

### Must fix before GA

1. **1.5.11 was never merged back into `v2`.** `CHANGELOG.md` jumps from
   2.0.0 (82) to 1.5.10 (72) and `website/appcast.xml`'s newest item is
   1.5.10. Bring the 1.5.11 (77) changelog section and its appcast item over
   (`git checkout main -- CHANGELOG.md` is wrong; cherry-pick the hunks) so
   an upgrader from 1.5.11 sees a coherent history.
2. **Rewrite the 2.0.0 changelog as a final release note.** `CHANGELOG.md:7-51`
   is a beta-by-beta running log that opens with "Unfinished by definition".
   Collapse to one 2.0.0 (build N) section, then Added / Changed / Fixed.
3. **Path traversal gap in the album-folder review sheet.**
   `UI/AlbumFolderReviewSheetView.swift:97` hand-rolls sanitising and omits
   the `.`/`..` guard and whitespace collapsing that `PathComponentSanitizer`
   (`Services/OutputPathPlanner.swift:415`) has. Call the canonical one; also
   fold `ExternalDeviceProfile.normalizedSubpath` (`Models/ExternalDeviceProfile.swift:275-283`)
   onto it. Add a test for `../..` input.
4. **Dev harness compiled into release.** `AppDelegate.swift:407-697`
   (~290 lines, 14 `CRATEDIGGER_*` env switches, three `NSLog`s) plus the
   `CRATEDIGGER_SYNC_QUEUE` fixture at `LibraryViewModel.swift:2251`. Wrap in
   `#if DEBUG` or move to a `DevHarness.swift` behind a compile flag.
5. **README still describes the single-feed model.** `README.md:167-206`
   never mentions `website/appcast-beta.xml`; rewrite to match `CLAUDE.md:35-57`
   and `UpdateFeed.override`.
6. **Release-time version flips**: `AppVersion.swift:18` `channel = ""`,
   `channelOrdinal` unused, `betaExpiry` stays nil; `website/index.html:490`
   and `website/roadmap.html:195` say "v1.5.10"; `website/llms.txt:11` says
   "Introducing CrateDigger 0.9". Decide the final feed for 2.0.0 GA: it ships
   on `appcast.xml` (stable), which is frozen until then per CLAUDE.md.
7. **Tags.** The repo has zero git tags although `AppVersion.swift:58`
   documents a tag convention. Tag 2.0.0 at GA and backfill or drop the
   comment.

### Should fix

8. Dead code: `LedDot` (`UI/Carbon/Conversion/PatchBayControls.swift:98`),
   `PageSide` (`UI/Carbon/Main/Browser/AlbumBookletView.swift:15`);
   orphaned `scripts/split-interleaved-album.py` (delete or document).
9. `@unchecked Sendable` without a rationale comment:
   `ProcessOutputLevelTap.swift:21`, `MetadataProbeService.swift:100`,
   `MetadataEditorService.swift:7`, `StreamEngineDoctor.swift:9`,
   `AlbumBookletView.swift:52`.
10. `try?` on write paths that can silently lose data: audit
    `DeviceSyncQueueStore.swift` (14), `ArtworkStore.swift` (12),
    `LibraryOrganizerService.swift` (11); log through `AppLog` at minimum.
11. Bare `fatalError()` at `GroupAlbumsSheetController.swift:48` (the other
    nine `init(coder:)` stubs carry a message).
12. Completion-handler `URLSession` call in `ChunkedStreamLoader.swift:263`
    inside an otherwise async codebase.
13. Test gaps for user-facing services with no dedicated test file:
    `CDRipperService`, `DeviceDetectionService`, `DeviceCatalogStore`,
    `FingerprintMatchService`. At least cover the pure planning/matching
    parts.

### Docs housekeeping

14. `CLAUDE.md` drift: `:21` says "a dozen" App test files and "~900 tests"
    (actual 18 files, 1146 tests); `:88` says `LibraryViewModel` is ~4300
    lines (actual 4880). Also add the new `+Queue`, `+Resume`, `+Sleep`,
    `+MiniPlayer`, `+Listening`, `+NowPlaying` extensions to the extension
    list and mention gapless once it lands.
15. `docs/superpowers/plans/`: ten of eleven plans are shipped with 0/N boxes
    ticked. Move them to `docs/superpowers/plans/archive/`. The eleventh,
    `2026-09-02-phase-2-smart-crates.md`, is **not shipped** (`SmartCrate`
    has no hits in `Sources/`). Decide: cut from 2.0 and say so on
    `website/roadmap.html`, or it is the last feature before GA.
16. `docs/OLED_VISUALIZER_PLAN.md` is "planned, not implemented"; keep as a
    2.1 item or delete. `docs/GITHUB_SECURITY_SCANNING_SPEC.md` §4 is an
    open owner action (repo settings) and names a stale branch.
17. Add "Performance audit" and "Gapless verification" items to
    `docs/BETA_RELEASE_CHECKLIST.md` so the GA gate includes them.

### Verification for this phase

- `scripts/test.sh` green; `swift build -c release` with `-warnings-as-errors`
  once to surface anything the cleanup touched.
- `scripts/package-app.sh` and the clean-Mac smoke test from the checklist.
- Grep gates: `grep -rn "NSLog\|print(" Sources` empty outside `AppLog`;
  `grep -rn "CRATEDIGGER_" Sources` only inside `#if DEBUG` or
  `ExternalToolLocator`/`LastFMCredentials`.

---

## Suggested order and sizing

| Step | Scope | Size |
|------|-------|------|
| 3.1-3.2 | 1.5.11 merge-back + changelog rewrite | small, do first so every later commit lands under a final note |
| 1 | Gapless (engine + service + tests + wiring) | 1-2 days |
| 2 sessions 1-4 | Measure on release build | half a day |
| 2 A-B | Audio hot path + timers | 1 day |
| 2 C-D | View-model slicing, off-main persistence, launch deferral | 1-2 days, measure after each |
| 3.3-3.7 | Traversal fix, dev harness, README, version flips, tag | half a day |
| 3.8-3.17 | Should-fix + docs | half a day |
