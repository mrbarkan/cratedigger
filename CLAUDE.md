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

`Sources/CrateDiggerApp/UI/Carbon/Library/LibraryViewModel.swift` (~2600 lines) is a single `@MainActor ObservableObject` that owns **all** app state, **all** services, and **most** behavior. Almost every SwiftUI view binds to it via `@EnvironmentObject`. Behavior is split across `LibraryViewModel+*.swift` extensions in the same folder: `+Conversion`, `+ExternalDeviceTransfer`, `+LibraryFiles`, `+MultiSelect`, `+Onboarding`, `+Radio`, `+RecordDivider`, `+Rename`, `+TrackActions`. **When fixing app behavior, start here** — this is where the wiring lives.

It is a large god-object; prefer extracting testable logic into a Core service over adding more to it.

### The library data model & index

- The atomic unit is **`LoadedTrack`** = `AudioTrack` (file + tags surfaced for display) + `ConversionMetadata` (the editable/writeable tag set). Defined in `LibraryScanService.swift` and `ConversionModels.swift`.
- A flat `[LoadedTrack]` is turned into a browsable **`LibraryIndex`** (Artist → Album → Track) by `LibraryIndex.build(from:)`.
- **Critical invariant:** grouping into albums uses `OutputPathPlanner.albumFolderKey(for:)`. The browser index, the conversion output planner, and the per-album review sheet **all reuse this same key** so they agree on "what an album is." If you change album grouping, change it there.

### Sources model (Crates, Prep Crate, Remote, CD, Playlists, Radio)

`LibrarySource` (enum in `LibraryViewModel.swift`) selects what's shown — cases: `localCrate(name:)`, `prepCrate`, `remote`, `playlist(name:)`, `cd(volumePath:)`, `device(volumePath:)`, `radio(category:)`. The view model keeps separate cached indexes (`localIndex`, `remoteIndex`, `cdIndex`, `playlistIndex`, `prepCrateIndex`) for fast switching via `selectSource(_:)`.

- **Crates** are the persistence unit: each is a `.cdlib` file = a pretty-printed JSON array of `LoadedTrack`, stored in a user-chosen "Crates Index Folder". `loadCrateTracks`/`saveCrateTracks` are the I/O; a "Personal Crate" is auto-created.
- **Prep Crate** is the staging area: newly scanned folders land here first (`handleImport`), not directly into a saved crate.
- Editing a track's tags (or moving/consolidating the library) must **rewrite the file path inside every `.cdlib` that references it** (`updateTrackURLInIndex`, and the loops in `moveLibrary`/`consolidateLibrary`). Forgetting this leaves crates pointing at stale paths.
- Remote = Subsonic/Navidrome (`SubsonicClient`); CD = `CDRipperService`; Playlists = M3U via `PlaylistService`; Radio = YouTube streaming (see below).
- **External devices** (`.device`) are mounted removable volumes (`DeviceDetectionService`) that match a saved `ExternalDeviceProfile` — random drives never reach Sources. Matching is `ExternalDeviceProfile.match(_:in:)`: a stored `volumeUUID` is **authoritative** when both the profile and the volume report one, so two iPods that both mount at `/Volumes/IPOD` named "IPOD" stay distinct; profiles saved before UUIDs (or volumes reporting none) fall back to mount path, then name. Legacy profiles self-heal via `backfillVolumeUUIDs` on first connect.

### Radio / YouTube streaming

A second playback path that streams YouTube audio instead of local files. Entirely in Core except the `LibraryViewModel+Radio` wiring.

- A **`StreamSource`** (`Models/StreamSource.swift`) is a saved YouTube URL + `StreamKind` (`live`/`video`/`mix`/`playlist`) + `StreamProvider`. Sources are grouped in the sidebar by **`RadioCategory`** (`youtubeLive` → "YT Live", `youtubeRecords` → "YT Records"), which is the payload of `LibrarySource.radio`.
- **`StreamURLParser`** normalizes a pasted URL into a `StreamSource`; **`StreamStore`** persists the list as a small JSON blob in `PreferencesStore` (app-global, *not* a per-folder `.cdlib`).
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

### External tools (ffmpeg / ffprobe)

`ExternalToolLocator` resolves binaries (`ToolKind`: `ffmpeg`, `ffprobe`, `ytdlp`) in this priority: **bundled** (`Bundle.main` Resources) → explicit override → env var (`CRATEDIGGER_FFMPEG_PATH` / `CRATEDIGGER_FFPROBE_PATH`) → system PATH (`/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, then `$PATH`). `ffprobe` powers richer metadata via `MetadataProbeService`; if it's missing the app degrades gracefully to **AVFoundation-only** metadata, and conversion surfaces a "install ffmpeg" alert. The packaged `.app` bundles both binaries (entitlements disable library validation so they can run).

### Playback

`PlaybackService` (Core) wraps an `AVPlayer` (`AVPlayerEngine`) behind the `PlaybackEngineProtocol`/`PlaybackServiceProtocol` protocols (so tests use a fake engine). It's **callback-based**, not Combine: `onStateChange`/`onCurrentIndexChange`/`onTimeChange`/`onError`. `LibraryViewModel.wirePlaybackBindings()` adapts these into `@Published` state on the main actor. Queue-based with auto-advance, shuffle, repeat modes, ±8s seek, and output-device selection. Last.fm "now playing" + scrobble are driven off the time-change callback.

### Artwork

`ArtworkService` (Core) is a **SHA-256-hash-keyed** in-memory store (`dataByHash`) + thumbnail `NSCache`. `resolveArtwork` prefers embedded art → folder image (e.g. `cover.jpg`) → remote. Tracks reference art by `artworkHash`, not by carrying image bytes. `RemoteArtworkService` fetches from iTunes; assets fetched outside the scan pipeline must be `ingest`ed so thumbnails resolve. Album folders can carry an `ArtworkManifest` (role mapping) and `AlbumBooklet` (scanned images/PDFs).

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
