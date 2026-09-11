# Now Playing widget — design

2026-09-11. Target: 2.1.

## What

A WidgetKit widget (small and medium) that shows what CrateDigger is
playing: art, title, band, album, progress. Show-only: tapping it opens
the app, there are no buttons. It runs on the desktop and in Notification
Center and takes the system's Liquid Glass on macOS 26.

## Why this shape

- **Show-only** keeps it on the app's macOS 13 floor and one-directional:
  the app writes, the widget reads, nothing ever has to call back.
- **No Xcode project.** The widget is a third SwiftPM executable target;
  `scripts/package-app.sh` folds it into `Contents/PlugIns/` the same way it
  already folds Sparkle into `Contents/Frameworks/`.
- **Native look.** WidgetKit draws the glass itself as long as the views
  stay plain (text, image, `containerBackground`, `widgetAccentable`). A
  Carbon chassis inside a widget would fight the material and would have
  to be redrawn without the app's theme environment.

## Pieces

### `NowPlayingFeed` (new library target, `Sources/NowPlayingFeed`)

The one type both processes agree on. Kept out of `CrateDiggerCore` so the
sandboxed extension does not link AVFoundation, Accelerate and the whole
library model to draw three lines of text.

```swift
public struct NowPlayingFeed: Codable, Equatable {
    public enum State: String, Codable { case idle, playing, paused }
    public var state: State
    public var title, artist, album: String
    public var isLive: Bool          // radio stream: no progress bar
    public var duration: Double      // seconds
    public var playhead: Double      // seconds, as of playheadAt
    public var playheadAt: Date      // wall clock, so the widget can extrapolate
    public var artworkFile: String?  // "art-<sha256>.jpg" in the container
}
```

Plus the container plumbing:

- `NowPlayingFeed.groupIdentifier` — one constant.
- `NowPlayingFeed.containerURL()` —
  `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`.
- `NowPlayingFeedStore` — `write(_:artwork:)` and `read()`. `write` encodes,
  compares with the bytes on disk and returns without touching the file
  when nothing changed, the same rule `PlaybackSnapshot` uses, so ticking
  playback costs nothing. Artwork is written once per hash and old files
  are removed when the hash changes.

### App side (`LibraryViewModel+NowPlaying.swift`)

`refreshNowPlayingInfo()` is already "what the system should show". It also
builds a `NowPlayingFeed`, hands it to the store, and calls
`WidgetCenter.shared.reloadTimelines(ofKind:)` when the store reports a
change. The seek path (`updateNowPlayingElapsed`, which only fires when
playback diverged from the extrapolation) does the same. At quit the app
writes `idle`.

Nothing in the tick path reaches the widget: the widget animates progress
from `(playhead, playheadAt, duration)` on its own.

### Widget (`Sources/CrateDiggerWidget`, executable target)

`@main` `WidgetBundle` with one `StaticConfiguration` widget, kind
`"NowPlaying"`, families `.systemSmall` and `.systemMedium`.

Timeline: one entry from `NowPlayingFeedStore.read()`, policy `.never`. The
app pushes every reload; the widget never polls.

Views:

- Small: art fills the widget; title and band over a bottom gradient.
- Medium: art left (square), right column: title, band, album, progress —
  the mini player's three lines.
- Progress: `ProgressView(timerInterval: start...end)` while playing,
  where `start = playheadAt - playhead`, `end = start + duration`; a static
  `ProgressView(value:)` while paused; none when `isLive`.
- Idle: "Nothing playing" and the app glyph.
- Placeholder / snapshot: the idle view with redacted text.
- `containerBackground(.fill.tertiary, for: .widget)` on macOS 14+, plain
  background below; text `widgetAccentable` so accented and clear
  rendering modes work.

### Packaging (`scripts/package-app.sh`, `Packaging/CrateDiggerWidget/`)

- Build: `swift build -c release --product CrateDiggerWidget` alongside the
  app product.
- Assemble `Contents/PlugIns/CrateDiggerWidget.appex/Contents/{MacOS,Info.plist}`
  from a template plist: `CFBundleIdentifier = com.cratedigger.app.widget`,
  `CFBundlePackageType = XPC!`, `LSMinimumSystemVersion = 13.0`,
  `NSExtension.NSExtensionPointIdentifier = com.apple.widgetkit-extension`.
- Entitlements: `Packaging/CrateDiggerWidget/CrateDiggerWidget.entitlements`
  with `com.apple.security.app-sandbox` and
  `com.apple.security.application-groups`. The app's own entitlements gain
  the same `application-groups` key.
- Sign the `.appex` before the app, inside-out, in both the ad-hoc and the
  Developer ID branch.
- Verify, field by field, before finishing: the plist keys above,
  `codesign -d --entitlements` shows the group on both, and
  `codesign --verify --deep --strict` passes.

## The risk, and the spike that retires it first

Whether a hand-assembled, ad-hoc-signed `.appex` loads under macOS 15+ and
reads the group container, and which group id format the system accepts
(`group.com.cratedigger.app` versus a team-prefixed id). Task 1 is a
throwaway widget that shows one string from the container, packaged and
added on this machine. If ad-hoc fails, the fallback is that the widget is
a Developer ID-only feature, which is what ships anyway, and the script
skips it on ad-hoc builds with a printed note.

## Tests

- `NowPlayingFeedTests`: Codable round trip; `write` returns `false` and
  leaves the file's mtime alone when the feed is unchanged; artwork is
  written once per hash and the previous hash's file is removed.
- Widget views: SwiftUI, untested, like the rest of the app's views.
- Packaging: the field-by-field check in the script is the test.

## Out of scope for 2.1

Buttons (macOS 14 App Intents, plus a channel back to the app), the large
size with Up Next, a URL scheme, lock-screen or StandBy variants.
