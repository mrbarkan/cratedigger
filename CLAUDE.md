# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

CrateDigger is a native **macOS** music-library utility (AppKit + SwiftUI, Swift Package Manager). It scans folders of audio files, browses/plays them, inspects & edits metadata and artwork, organizes/cleans up libraries, and batch-converts files with **FFmpeg**. It also has integrations for Subsonic/Navidrome streaming, Audio-CD ripping, YouTube "radio" streaming (via **yt-dlp**), splitting continuous vinyl-side rips into per-track exports, and Last.fm scrobbling. The UI is a skeuomorphic "hardware" aesthetic ("Carbon").

## Commands

```bash
swift build                      # build (debug). App binary: .build/arm64-apple-macosx/debug/CrateDiggerApp
swift build -c release           # release build
scripts/test.sh                  # run the XCTest suite (preferred — see note below)
scripts/test.sh --filter OutputPathPlannerTests           # run one test class
scripts/test.sh --filter OutputPathPlannerTests/testFoo   # run one test method
scripts/package-app.sh           # assemble dist/CrateDigger.app (bundles ffmpeg/ffprobe, ad-hoc signed)
```

- **Run `scripts/test.sh`, not bare `swift test`.** It forces `--enable-xctest --disable-swift-testing`, points at a full Xcode install, and uses a repo-local module cache (`.build/tests`). XCTest needs a *full* Xcode developer dir (not just Command Line Tools); the script prints clear remediation if the license isn't accepted or `PlatformPath` lookup fails.
- Tests live in `Tests/CrateDiggerCoreTests` (most coverage — the core library is the testable layer) and `Tests/CrateDiggerAppTests` (only `WindowFramePlanner`). **UI / `LibraryViewModel` behavior is largely untested.**
- To launch and verify a change in the running app, build then run the binary directly (the local permission allowlist already covers `swift build`, running the debug binary, and `pkill -f CrateDiggerApp`).
- Release/distribution (Developer ID signing + notarization + DMG) and the full beta gate are documented in `README.md` and `docs/BETA_RELEASE_CHECKLIST.md`.

## Two release lines (read before committing anything)

- **`main` is the stable line**, currently 1.5.x, and it is what the public
  downloads and what every installed copy auto-updates from. Only ship
  bug fixes here.
- **`v2` is the beta line** and is where all work up to 2.0 goes. Everything
  from here ships as a GitHub **prerelease** so `/releases/latest` (and the
  website's Download button) stay on stable.

Isolation is at the **feed**, not the channel: `v2`'s `SUFeedURL` points at
`website/appcast-beta.xml`, which no shipped 1.5.x app knows about, so
`website/appcast.xml` is frozen for the whole 2.0 cycle. Never repoint
`SUFeedURL` on `v2` — that single line is what keeps betas off other people's
Macs.

The one thing that does cross over: GitHub Pages only serves `website/` from
`main`, so publishing a beta feed means copying *just*
`website/appcast-beta.xml` onto `main` (`git checkout v2 -- <that file>`).
Never carry anything else across. The `press-the-record` skill scripts both
paths — use it rather than releasing by hand.

## Two-target architecture

`Package.swift` defines two targets — keep the boundary clean:

- **`CrateDiggerCore`** (`Sources/CrateDiggerCore`) — a pure library: `Models/` + `Services/`. No AppKit *views*, no app state. This is the unit-tested layer; put logic here when it can be tested in isolation. Most types are `public`, `Sendable`, `Codable`.
- **`CrateDiggerApp`** (`Sources/CrateDiggerApp`) — the AppKit executable + all SwiftUI views, depends on Core.

### App launch & control flow

There is no `@main` / SwiftUI App lifecycle. The chain is explicit:

```
main.swift  →  AppDelegate  →  MainWindowController  →  CarbonHostingController  →  CarbonRootView (SwiftUI)
(NSApplication)  (menu bar,      (NSWindow: frame        (NSHostingController        (root view tree)
                  Space monitor)   persistence,            owns the single
                                   appearance)              LibraryViewModel)
```

- **`AppDelegate`** builds the entire NSMenu programmatically and is the target for every menu action. Menu actions forward to `MainWindowController`, which forwards to `LibraryViewModel`. `validateMenuItem` gates enablement on view-model state. It also installs a global Space-key monitor (AppKit swallows plain Space otherwise) for play/pause.
- **AppKit ↔ SwiftUI bridge:** the menu bar, window chrome, and all **sheets** are AppKit. Sheets are `NSViewController`s (e.g. `ConversionOptionsSheetController`, `AlbumFolderReviewSheetController`, `ExternalDeviceTransferSheetController`) presented via `presentAsSheet`, communicating results back through an `onDecision` closure. The main content is SwiftUI hosted in the window.

### `LibraryViewModel` — the center of gravity

`Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift` (~4200 lines) is a single `@MainActor ObservableObject` that owns **all** app state, **all** services, and **most** behavior. Almost every SwiftUI view binds to it via `@EnvironmentObject`. Behavior is split across `LibraryViewModel+*.swift` extensions in the same folder: `+Conversion`, `+DeepScan`, `+ExternalDeviceTransfer`, `+LibraryFiles`, `+Listening`, `+MultiSelect`, `+Onboarding`, `+Radio`, `+RecordDivider`, `+Rename`, `+TrackActions`. **When fixing app behavior, start here** — this is where the wiring lives.

It is a large god-object; prefer extracting testable logic into a Core service over adding more to it.

**Browser state is no longer here.** Selection (anchors + the three mutually-exclusive multi-selection sets), the three sort pairs and `focusedColumn` live in Core's `BrowserState`; the view model holds one `@Published var browser` and forwards every old property name onto it as a computed property. Add browser state to `BrowserState`, not here. The forwarding setters are where the `PreferencesStore` writes and the `recomputeSortedCollections()` call live — a single `didSet` on `browser` would re-sort the whole library on every click.

### The library data model & index

- The atomic unit is **`LoadedTrack`** = `AudioTrack` (file + tags surfaced for display) + `ConversionMetadata` (the editable/writeable tag set). Defined in `LibraryScanService.swift` and `ConversionModels.swift`.
- A flat `[LoadedTrack]` is turned into a browsable **`LibraryIndex`** (Artist → Album → Track) by `LibraryIndex.build(from:)`.
- **Critical invariant:** grouping into albums uses `OutputPathPlanner.albumFolderKey(for:)`. The browser index, the conversion output planner, and the per-album review sheet **all reuse this same key** so they agree on "what an album is." If you change album grouping, change it there.

### Sources model (Crates, Prep Crate, Remote, CD, Playlists, Radio)

`LibrarySource` (enum in `LibraryViewModel.swift`) selects what's shown — cases: `localCrate(name:)`, `prepCrate`, `remote`, `playlist(name:)`, `cd(volumePath:)`, `device(volumePath:)`, `radio(category:)`. The view model keeps separate cached indexes (`localIndex`, `remoteIndex`, `cdIndex`, `playlistIndex`, `prepCrateIndex`) for fast switching via `selectSource(_:)`.

- **Crates** are the persistence unit, stored in a user-chosen "Crates Index Folder". A crate is a **`.cdcrate` file = a JSON array of file paths** (membership only). The tracks themselves live once in a **shared `TrackStore`** (`library.cdtracks` in the same folder), and artwork lives in `ArtworkStore` keyed by SHA-256 — `ArtworkAsset.encode` deliberately omits the image bytes, so no index file ever carries base64 artwork. `loadCrateTracks`/`saveCrateTracks` are the I/O; a "Personal Crate" is auto-created. Legacy `.cdlib` files (full `LoadedTrack` arrays with embedded art) are migrated once on launch by `migrateLegacyCratesIfNeeded` and renamed `.cdlib.bak`.
- **`saveCrateTracks(_:name:persistStore:)` re-encodes the whole store.** Pass `persistStore: false` inside multi-crate loops and call `persistTrackStore()` once at the end, or a batch operation freezes the UI at library size.
- **Listening history** is a third store in the same folder: `library.cdplays`, a path-keyed `[String: ListeningStats]` holding play count, skip count, last played, date added and rating. Deliberately NOT a field on `LoadedTrack`: `TrackStore.upsert` replaces whole records and the retag, relink and rescan paths all rebuild one, so stats living there would be one forgotten line away from being silently zeroed. Anything that changes a track's path must call `ListeningStore.repoint(from:to:)` alongside the `TrackStore` update — the same choke points already do both. Plays are counted against `PlayThreshold.isPlayed`, which is also what triggers a Last.fm scrobble, so the two can never drift.
- **Prep Crate** is the staging area: newly scanned folders land here first (`handleImport`), not directly into a saved crate.
- Editing a track's tags (or moving/consolidating the library) must **repoint every crate that references it** — `updateTrackURLInIndex` for one track, `updateTrackURLsInIndex` for a batch (loads/saves each crate at most once), plus the loops in `moveLibrary`/`consolidateLibrary`. These also drop the dead old path key from the `TrackStore`. Forgetting this leaves crates pointing at stale paths.
- Remote = Subsonic/Navidrome (`SubsonicClient`); CD = `CDRipperService`; Playlists = M3U via `PlaylistService`; Radio = YouTube streaming (see below).
- **External devices** (`.device`) are mounted removable volumes (`DeviceDetectionService`) that match a saved `ExternalDeviceProfile` — random drives never reach Sources. Matching is `ExternalDeviceProfile.match(_:in:)`: a stored `volumeUUID` is **authoritative** when both the profile and the volume report one, so two iPods that both mount at `/Volumes/IPOD` named "IPOD" stay distinct; profiles saved before UUIDs (or volumes reporting none) fall back to mount path, then name. Legacy profiles self-heal via `backfillVolumeUUIDs` on first connect.

### Radio / YouTube streaming

A second playback path that streams YouTube audio instead of local files. Entirely in Core except the `LibraryViewModel+Radio` wiring.

- A **`StreamSource`** (`Models/StreamSource.swift`) is a saved YouTube URL + `StreamKind` (`live`/`video`/`mix`/`playlist`) + `StreamProvider`. Sources are grouped in the sidebar by **`RadioCategory`** (`youtubeLive` → "YT Live", `youtubeRecords` → "YT Records"), which is the payload of `LibrarySource.radio`.
- **`StreamURLParser`** normalizes a pasted URL into a `StreamSource`; **`StreamStore`** persists the list as a small JSON blob in `PreferencesStore` (app-global, *not* a per-folder `.cdcrate`).
- **`StreamResolver`** invokes **yt-dlp** to turn a `StreamSource` into a `ResolvedStream` (HLS `.m3u8` for live, progressive m4a/AAC for VOD — formats AVPlayer can decode, unlike YouTube's default WebM/Opus). The argument vector is pure and unit-tested with a fake runner. **`StreamMetadataService`** fetches title/channel/thumbnail/viewers/`StreamChapter`s.
- yt-dlp is resolved by `ExternalToolLocator` (`ToolKind.ytdlp`, binary name `yt-dlp`) with the same priority chain as ffmpeg/ffprobe. Missing yt-dlp degrades radio, not the rest of the app.

### Record Divider (vinyl-side rip splitting)

Splits one continuous recording (e.g. a whole vinyl side captured as a single file) into multiple per-track exports. Pure logic in Core, driven by `LibraryViewModel+RecordDivider`.

- A **`RecordMarker`** (`Models/RecordMarker.swift`) is one *kept* track = `[startSeconds, endSeconds]` + title. Playback navigates between markers; conversion cuts one output file per marker; audio outside all markers is audible-but-skipped (omitted from export). Analogous to `StreamChapter` for streams.
- **`RecordDividerService`** auto-detects breaks from sustained near-silence; `RecordDetectionSensitivity` maps a 0…1 UI slider onto a noise-floor (dB) + min-silence-duration pair (conservative by default so long songs aren't split internally).
- **`RecordTrackPlanner`** turns markers into `RecordTrackPlan`s (per-track `ConversionMetadata`, source slice, suggested base name) that then flow through the normal `OutputPathPlanner` + `ConversionService` (ffmpeg cuts the slice).

### Conversion pipeline (FFmpeg)

1. UI builds a `ConversionOptionsSelection`; `LibraryViewModel+Conversion` turns it into an **ad-hoc `ConversionPreset`** and plans `ConversionJob`s.
2. **`OutputPathPlanner`** computes each destination path. Folder modes: `sourceRelative` (mirror source tree from deepest common ancestor), `flat`, `metadataTemplate` (token order: album-artist / year / album / compilation). It guarantees **collision-safe unique filenames** (` (2)`, ` (3)`…) against both existing files and already-reserved paths in the batch.
3. **`ConversionService`** (Core) builds the ffmpeg argument vector (codec, bitrate/sample-rate, artwork embedding/re-encode, metadata tags) and runs jobs via `ProcessCommandRunner` (real `Process`) on an `OperationQueue` (≈ CPU count − 1 workers). `CommandRunning` is a protocol so tests inject a fake runner.
4. Preflight before running: destination writability probe + free-disk-space estimate (`validateBatchPreflight`).
5. **Cancellation is cooperative**: `cancel()` sets a flag checked *between* job dispatches; the in-flight ffmpeg process is **not** killed (documented limitation in `ConversionService`).

### FIX TAGS and DEEP SCAN (metadata matching)

Two lookup paths behind one button, both ending in the same review sheet
(`MetadataMatchSheetView`, driven by `LibraryViewModel+MetadataRepair`).

- **FIX TAGS** (the default) is text matching: `MetadataMatchService` fans out
  over `ReleaseMetadataProvider` (MusicBrainz + iTunes), `ReleaseScorer` ranks
  the candidates and turns the winner into per-track `TrackTagProposal`s.
- **DEEP SCAN** (`FingerprintMatchService`, `LibraryViewModel+DeepScan`) is
  audio matching, for when the tags are blank or wrong and text search has
  nothing to search with. `AudioFingerprintService` runs **fpcalc**,
  `AcoustIDClient` turns each fingerprint into MusicBrainz recordings, the
  album's files **vote** on which release they all appear on, and
  `MusicBrainzReleaseClient.release(id:)` fetches the winner. The score is the
  vote share, not text similarity — the point is that it never read the tags.
  Candidates are re-badged `ReleaseSource.acoustID` so the sheet says how the
  release was found.
- **Never automatic.** Fingerprinting decodes every file, so DEEP SCAN runs
  only when the user presses for it: the sheet's DEEP SCAN key, or the action
  button on the "no match" alert.
- Track pairing goes through `ReleaseScorer.proposals(from:for:recordingIDs:)`.
  The `recordingIDs` pass is DEEP SCAN's: an untagged file has no number and no
  title, so every other pass is guessing, but its fingerprint names the
  recording outright. Empty map = the old behaviour exactly.
- **AcoustID needs an *application* key**, in `AcoustIDClient.applicationKey`.
  Registered once at acoustid.org/new-application, listed afterwards under
  acoustid.org/my-applications. It is **not** the account API key from
  acoustid.org/api-key, which signs fingerprint *submissions*; the two are
  both ten mixed-case characters and are easy to confuse. Sending the account
  key returns error code 4, "invalid API key", with nothing else wrong. If the
  constant is ever left as `AcoustIDClient.placeholderKey`, DEEP SCAN refuses up
  front rather than decoding audio for a doomed request.
- **The `+` in `meta=recordings+releaseids` must stay unescaped.** AcoustID
  separates meta values with a space and a form body decodes `+` to one.
  Percent-encode it to `%2B` and the parameter is silently ignored: results come
  back carrying scores and nothing else, which reads as an unrecognised
  recording rather than a malformed request. Cost an hour once already.

### In-app updates (Sparkle)

The app's **only** third-party dependency. `SoftwareUpdater` (`Updates/`) wraps
`SPUStandardUpdaterController`: the menu item and the daily background check
both go through it, and it does nothing at all unless `Bundle.main` carries
`SUFeedURL` — so a `swift build` run has no updater and the menu item greys out.
The feed is `website/appcast.xml` (GitHub Pages), regenerated per release by
`scripts/update-appcast.sh`; `scripts/package-app.sh` embeds and re-signs
`Sparkle.framework` into `Contents/Frameworks` (SwiftPM links it but can't put
it in a `.app`). Setup and release steps are in README, "In-app updates".

### External tools (ffmpeg / ffprobe)

`ExternalToolLocator` resolves binaries (`ExternalTool`: `ffmpeg`, `ffprobe`, `ytdlp`, `fpcalc`, `sacdExtract`) in this priority: **bundled** (`Bundle.main` Resources) → explicit override → env var (`CRATEDIGGER_FFMPEG_PATH` / `CRATEDIGGER_FFPROBE_PATH` / `CRATEDIGGER_FPCALC_PATH`) → system PATH (`/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, then `$PATH`). `ffprobe` powers richer metadata via `MetadataProbeService`; if it's missing the app degrades gracefully to **AVFoundation-only** metadata, and conversion surfaces a "install ffmpeg" alert. The packaged `.app` bundles both binaries (entitlements disable library validation so they can run).

### Playback

`PlaybackService` (Core) wraps an `AVPlayer` (`AVPlayerEngine`) behind the `PlaybackEngineProtocol`/`PlaybackServiceProtocol` protocols (so tests use a fake engine). It's **callback-based**, not Combine: `onStateChange`/`onCurrentIndexChange`/`onTimeChange`/`onError`. `LibraryViewModel.wirePlaybackBindings()` adapts these into `@Published` state on the main actor. Queue-based with auto-advance, shuffle, repeat modes, ±8s seek, and output-device selection. Last.fm "now playing" + scrobble are driven off the time-change callback.

### Artwork

`ArtworkService` (Core) is a **SHA-256-hash-keyed** in-memory store (`dataByHash`) + thumbnail `NSCache`. `resolveArtwork` prefers embedded art → folder image (e.g. `cover.jpg`) → remote. Tracks reference art by `artworkHash`, not by carrying image bytes. `RemoteArtworkService` fetches remotely from four sources: iTunes then Deezer for a single front cover, and — once a MusicBrainz release is picked in the artwork sheet — the Cover Art Archive (typed Front/Back/Booklet images) plus Discogs, which carries the deep scans of physical pressings. Discogs is found by a three-rung ladder in `discogsImages(for:artist:)`: the `discogs` URL relation MusicBrainz stores for the release, else its barcode, else artist+title with the result's title checked. The sheet loads the two sources in stages (archive first, Discogs appended) because the ladder can take several seconds. Discogs needs no credentials; `PreferencesStore.discogsToken` is optional and only raises the rate limit. Assets fetched outside the scan pipeline must be `ingest`ed so thumbnails resolve. Album folders can carry an `ArtworkManifest` (role mapping) and `AlbumBooklet` (scanned images/PDFs).

### Cross-cutting events & persistence

- **NotificationCenter with string names** is used for several cross-cutting signals (e.g. `"CrateDiggerAudioDeviceChanged"`, `"CrateDiggerCDSpeedChanged"`, `"CrateDiggerMoveLibrary"`, `"CrateDiggerConsolidateLibrary"`, `"CrateDiggerCratesFolderChanged"`, `"CrateDiggerArtworkImported"`, `AppearanceMode.didChangeNotification`). These are untyped string contracts — grep for the literal when tracing.
- **`PreferencesStore`** (Core, `.shared`) wraps `UserDefaults` and persists: window frame, recent library folders, output destination, managed-library folder, crates-index folder, last conversion selection, OLED view, shuffle/repeat, external-device profiles, Last.fm session key, custom ffmpeg path. Folder access across launches uses **security-scoped bookmarks** (`makeBookmark`/`resolveBookmark`/`refreshBookmarkIfStale`) — always go through these helpers for user-chosen folders, never store raw paths.

### UI ("Carbon" design system)

SwiftUI under `Sources/CrateDiggerApp/UI/Carbon/`. Skeuomorphic hardware look: chassis layers, recessed wells, paper panels, an OLED display, LED meters, physical knobs/buttons. Theming flows through the `.carbonThemed(mode:)` environment with light/dark/system `AppearanceMode` (persisted, mirrored in the AppKit menu). Layout: a header, a 3-pane `MainShell` (**Sources | Browser | Inspector**, each independently collapsible with width invariants), and a footer transport. The **`OLEDView`** enum (`nowPlaying`/`vu`/`conversion`/`scan`/`remoteSync`/`cdRip`) is the mode switch that drives what the main area shows (e.g. selecting `conversion` swaps the Inspector for the "Patch Bay" and auto-collapses the browser).

## Conventions & gotchas

- `LibraryViewModel` is `@MainActor`; long work (scan, convert, organize, copy) runs in detached `Task`s and hops back via `await MainActor.run`/`@MainActor`.
- Heads-up: many user-facing messages are surfaced through `appAlert = .error(title:…)` **even for success/info** ("Saved", "Library Moved", "CD Ripped!"). The tone/title in those `.error(...)` calls is often informational despite the case name — don't assume an error occurred from the enum case alone.
- New testable logic belongs in `CrateDiggerCore` with an XCTest; UI glue belongs in `CrateDiggerApp`.
- `CrateDigger_DESIGN/` and `Branding/` are design references/assets, and `website/` is the static marketing landing page — none are build inputs. `dist/` and `.build/` are generated.

# Role & Philosophy
You are an expert Apple platform engineer. All code and interfaces must adhere strictly to Apple's design philosophy: Clarity, Deference, and Depth.

## Design Philosophy
- **Clarity:** Text should be legible, icons precise, and adornments should serve a functional purpose.
- **Deference:** The UI should help users understand and interact with content, but never intrude. Use translucent materials (e.g., glassmorphism, blurred backgrounds) so content breathes.
- **Depth:** Visual layers and realistic motion communicate hierarchy and state. Use standard bottom sheets, navigation stacks, and spring-based animations.

## Coding Philosophy (Swift & SwiftUI)
- **Preview-Driven Development:** Structure your views so they are inherently preview-friendly.
- **State Management:** Use `@StateObject`, `@Observable`, and `@Environment` correctly to separate data models from view rendering.
- **System-First:** Do not over-design or reinvent system controls. Use SF Symbols, SF Pro fonts, and native list groups whenever possible.
- **Accessibility & System Adaptability:** Implement Dynamic Type and semantic colors (e.g., `.background`, `.primary`) to natively support Light/Dark mode by default.

# Corporate & Engineering Philosophy

## Core Values
- **Simplicity Over Elegance:** Choose boring, readable, and maintainable code over clever, deeply abstracted, or overly engineered solutions.
- **User-Centric Pragmatism:** Technical decisions must directly serve the user experience. Do not build features or optimizations that add no value to the end user.
- **Ownership & Quality:** Write production-ready code from the start. Include proper error handling, logging, and edge-case validation without being asked.

## Development Principles
- **Leave it Better:** Follow the scout rule. When modifying existing code, refactor obvious tech debt, update outdated comments, and improve readability.
- **Don't Assume, Ask:** If a requirement or business logic rule is ambiguous, stop and ask for clarification instead of guessing and writing incorrect logic.
- **Fail Fast & Loud:** Design systems to catch errors early in the execution cycle. Write clear, actionable error messages that make debugging straightforward.
