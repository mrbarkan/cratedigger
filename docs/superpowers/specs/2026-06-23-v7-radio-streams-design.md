# CrateDigger v7 — Radio / Streams (YouTube) design

Date: 2026-06-23
Status: approved (user said "build")
Source design: `CrateDigger_DESIGN/CrateDigger_v7.html` (imported from Claude Design)

## Goal

Let the user play audio from **YouTube** channels, playlists, live streams, and videos
inside CrateDigger, surfaced as a new **Radio / Streams** source. Implement the v7 UI
(Sources sidebar, Browser radio list, OLED radio mode, Inspector radio-info, Add-Stream
modal) and **disable the Inspector "Disc" tab** (ignore the v7 cassette/"Tape" concept).

## Key product decisions (from brainstorming)

1. **Two interchangeable playback engines, user-selectable in Settings.**
   - **WebView engine** (YouTube IFrame embed) — zero-config default, ToS-compliant, no binary.
   - **Native engine** (yt-dlp → AVPlayer) — full hardware integration; better fidelity.
2. **yt-dlp is bring-your-own, not bundled.** Detected via `ExternalToolLocator` (PATH) +
   an optional Settings path field (mirrors the existing custom-ffmpeg path). If absent,
   the native engine is unavailable.
3. **Engine selection default = `.auto`** → native if yt-dlp is detected, else WebView.
   Explicit `.native` / `.webview` also selectable.
4. **Disc tab fully hidden** (INFO / ART only). No cassette/tape visualization.
5. **Stream list persisted in `PreferencesStore`** (small app-global JSON), not `.cdlib` files.
6. **No scrobbling / Last.fm now-playing for streams.**

## Architecture overview

The Radio/Streams UI is engine-agnostic. A `RadioPlaybackEngine` protocol abstracts the
two backends. The existing `PlaybackService`/`AVPlayer` is reused by the native engine;
the WebView engine owns its own `WKWebView`. `LibraryViewModel` coordinates which engine
is active and routes transport controls.

```
StreamSource (model)  ──▶ StreamStore (persist via PreferencesStore)
       │
       ▼
LibraryViewModel.currentSource = .radio(channel:)        Add-Stream sheet ──▶ StreamURLParser
       │                                                          │
       ▼                                                          ▼
Sidebar (Radio/Streams)   RadioListView   OLED radio mode   Inspector radio-info
       │
       ▼ (select stream + play)
RadioPlaybackEngine (protocol)
   ├── YtDlpStreamEngine:  StreamResolver(yt-dlp -g -f …) ──▶ PlaybackService/AVPlayer
   └── YouTubeEmbedStreamEngine: hidden WKWebView + IFrame Player API (JS bridge)
```

## Components

### Core (CrateDiggerCore — testable)

- **`StreamSource`** (`Codable, Sendable, Hashable`): `id: String`, `url: String`,
  `title: String`, `channel: String`, `kind: StreamKind`, `hue: Int`, `source: StreamProvider`
  (`.youtube`), `addedDate: Date`, `viewers: String?`, `durationSeconds: Double?`.
  - `StreamKind`: `.live`, `.video`, `.mix`, `.playlist`.
  - `StreamProvider`: `.youtube` (extensible later).
  - `isLive: Bool { kind == .live }`.
- **`StreamURLParser`** (pure): input raw string → `ParsedStream?` with
  `{ valid, kind, suggestedTitle, channel, host }`. Ports the v7 `parseYT` logic:
  - `?list=` or `/playlist` → `.playlist`
  - `/channel/<id>` , `/@handle` , `/c/<name>` , `/user/<name>` → `.live` (channel)
  - `/live` → `.live`
  - `?v=` or `youtu.be/<id>` → `.video`
  - host validation for `youtube.com` / `youtu.be`.
- **`StreamStore`**: load/save `[StreamSource]` via `PreferencesStore.streamSources`
  (JSON-encoded `Data`). `add`, `remove`, `all`, `channels()` helpers. Channels are the
  distinct `channel` values (for sidebar grouping).
- **`StreamResolver`** (native engine support): builds the yt-dlp argument vector and parses
  its stdout into a playable URL. Runs through the existing `CommandRunning` protocol so it
  is unit-tested with a fake runner (same pattern as `ConversionService`).
  - Live: `yt-dlp -g -f "bestaudio/best" <url>` → expect an HLS/`.m3u8` or progressive URL.
  - VOD: `yt-dlp -g -f "ba[ext=m4a]/bestaudio[acodec^=mp4a]/best" <url>` → m4a/AAC URL
    (AVPlayer cannot decode WebM/Opus, so prefer m4a/AAC or HLS).
  - Playlist: `yt-dlp --flat-playlist -J <url>` to enumerate entries, then resolve per-entry
    on demand. (Phase 4 scope; single-entry resolution first.)
  - Output: `ResolvedStream { playbackURL: URL, isLive: Bool, durationSeconds: Double? }`.
- **`PreferencesStore`** additions: `streamSources: Data?`, `streamEngine: String`
  (`auto`/`native`/`webview`), `ytDlpPathBookmark`/override key.
- **`ExternalToolLocator`**: add `case ytdlp` (env key `CRATEDIGGER_YTDLP_PATH`), same
  resolution order, **not** added to `package-app.sh` bundling (bring-your-own).

### App (CrateDiggerApp — UI glue)

- **`LibrarySource`**: add `case radio(channel: String?)` (`nil` = All Streams).
- **`SourcesSidebar`**: new "Radio / Streams" section — "All Streams" + one row per channel
  (live channels show `LIVE`), `+` opens Add-Stream sheet. Selecting a row →
  `selectSource(.radio(channel:))`.
- **`MainShell`**: when `currentSource` is `.radio`, render **`RadioListView`** instead of the
  3-column browser / gallery. Rows mirror v7: colored thumb (hue) + play overlay + duration
  badge, title, type badge + channel, "YouTube", watching/added. Header: channel + "N SOURCES"
  + "ADD URL".
- **`OLEDDisplay` / `NowPlayingView`**: radio variant — stream cells (Source/Codec/Bitrate/
  Buffer/Tuned-In); live → ON AIR + UPTIME (hide clock). Under WebView engine, show honest
  values ("YouTube · Embedded"), no fabricated codec/buffer.
- **`InspectorPane`**: INFO pane gains a radio-info panel (thumb, name, channel, specs,
  `LIVE`/`NO DRM` chips) shown when a stream is selected. **Remove `.disc` from
  `InspectorTab`** visible cases + panes.
- **`AddStreamSourceSheetController`** (AppKit `NSViewController`, `presentAsSheet`): URL
  field, live `StreamURLParser` detection preview, ADD SOURCE → `StreamStore.add`, enter radio
  mode, select new stream. `onDecision` closure pattern like existing sheets.
- **Playback engines**:
  - `RadioPlaybackEngine` protocol: `play(_ s: StreamSource)`, `pause()`, `resume()`,
    `stop()`, `setVolume(_:)`, `seek(to:)` (VOD only), callbacks
    `onStateChange`/`onTimeChange`/`onError`.
  - `YtDlpStreamEngine`: resolves via `StreamResolver`, hands the URL to `PlaybackService`.
  - `YouTubeEmbedStreamEngine`: hidden `WKWebView`, IFrame Player API, JS bridge for
    play/pause/volume/seek + state polling. `mediaTypesRequiringUserActionForPlayback = []`.
  - `LibraryViewModel` owns the active engine (per `streamEngine` pref + yt-dlp availability)
    and routes the footer transport + Space-key to it while a stream plays.
- **Settings / menu**: "Stream Engine" picker (Auto/Native/WebView) + yt-dlp path field,
  mirrored in the AppKit menu like Appearance.

### Cross-cutting

- Scrobble guard: skip `checkScrobbleProgress` / now-playing for streams (`isStream` flag).
- VU meters unchanged (already simulated, source-agnostic).
- Loading state: "TUNING IN…" during yt-dlp resolution / IFrame load.
- Live vs VOD: seek bar disabled for live.

## Testing (Core, XCTest via scripts/test.sh)

- `StreamURLParserTests`: every URL shape (channel/@handle/c/user, playlist, live, video,
  youtu.be, invalid hosts, missing scheme).
- `StreamResolverTests`: yt-dlp arg vector + format selection (live vs VOD), stdout parsing,
  error on empty output — fake `CommandRunning`.
- `StreamStoreTests`: add/remove/round-trip via an in-memory `PreferencesStore`, channel
  grouping.

## Build sequence (phases)

1. **Core model + persistence + parser** (+ tests): `StreamSource`, `StreamKind`,
   `StreamProvider`, `StreamURLParser`, `StreamStore`, `PreferencesStore` keys.
2. **UI (engine-agnostic)**: `LibrarySource.radio`, sidebar section, `RadioListView`,
   `MainShell` wiring, OLED radio mode, Inspector radio-info, **disable Disc tab**,
   `AddStreamSourceSheetController`, `LibraryViewModel` radio state (select/filter/persist).
3. **WebView engine** (zero-config default) → streams actually play.
4. **Native engine**: `ExternalToolLocator.ytdlp`, `StreamResolver` (+ tests),
   `YtDlpStreamEngine`, engine picker + yt-dlp path setting, transport routing.

Each phase ends green (`swift build` + `scripts/test.sh`). UI verified by the user in the
running app (UI/`LibraryViewModel` are largely untested per repo conventions).

## Non-goals / later

- Non-YouTube providers (SoundCloud, etc.) — `StreamProvider` is left extensible.
- Full playlist queue auto-advance for the native engine (start with single-entry resolution;
  flat-playlist enumeration is a stretch within phase 4).
- Real audio-tap VU metering (meters stay simulated).
- Artwork fetch for stream thumbnails (use the hue-based poster like the mockup).
