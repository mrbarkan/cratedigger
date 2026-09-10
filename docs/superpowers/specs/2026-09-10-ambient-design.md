# Ambient: hear the room through your headphones

Date: 2026-09-10. Release line: 2.1.0 beta (`v2.1`). Approved in conversation;
the maintainer waived a separate spec review.

## Goal

Someone wearing closed-back headphones while doing chores can keep listening
to music and still hear the doorbell, a kettle, a person talking. CrateDigger
takes a chosen input (usually the Mac's built-in microphone) and plays it into
the same output as the music, at a level they dial.

Primary setup: Bluetooth headphones or a Bluetooth receiver, with the Mac's mic.
Also: wired headphones with the Mac's mic. The input level control is the
feature's most important knob.

## What people get

- **AMB key** in the label row of a new **AMBIENT** fader pod, beside VOLUME in
  the footer. Lit (`transportLamp`) while running.
- **AMBIENT fader**: the input level, 0 = silent, unity at the mark, +12 dB at
  the top. Double-click snaps to unity. Right-click opens the same items as
  the menu.
- **Playback ▸ Ambient** submenu: Ambient on/off (⌘⌥A), Microphone ▸ inputs,
  Delay ▸ Live / Balanced / Smooth, Low Cut, Engine ▸ Split / Combined.
- **Preferences**: an Ambient section under Output Device with the same four
  settings, and "Toggle Ambient" in the rebindable shortcuts.
- **Screen notices** (`showOLEDNotice`) for on, setting changes, blocked,
  and a disconnected mic.

The user asked to be able to triage what sounds best, so delay, low cut and the
engine itself are all switchable while listening.

## Behaviour rules

- Always off at launch. On/off is never persisted; everything else is.
- Refuses to start when the output is the Mac's built-in speakers (feedback
  howl). External outputs cannot be told apart from headphones and are allowed.
- Using a Bluetooth device's own mic while listening on that same device drops
  it to call-quality audio. The app warns once per device: Use Built-in Mic /
  Use Anyway / Cancel. Use Anyway is remembered for that device.
- Mic permission is requested on the first AMB press. Denied: an alert with
  Open Privacy Settings.
- Output device change: rebuild on the new device. Mic unplugged: turn off,
  notice MIC DISCONNECTED. Engine reconfiguration: rebuild.
- Bit-perfect DSD (DoP) playing: pause, resume after. Anything mixed into a DoP
  stream destroys its markers and the DAC plays static.
- Keeps running while music is paused.
- Nothing is recorded or written anywhere; audio only passes through memory.

Defaults: Split engine, Balanced delay, low cut on, level at unity, system
default mic.

## Architecture

Core (`CrateDiggerCore`), unit-tested:

- `AmbientLevelCurve`: fader position to linear gain, dB-linear from -60 to +12.
- `AudioTransport` + `AudioDeviceSummary`: a device's uid, name, connection
  (built-in, Bluetooth, USB, other) and whether it is the built-in speaker
  (built-in transport reporting the `ispk` internal-speaker data source).
- `AmbientPolicy.verdict(input:output:approvedCallModeUIDs:)`: ok, blocked by
  speakers, or needs call-mode approval.
- `AmbientRingBuffer`: mono float ring between input and output threads. Primes
  to the delay target before playing, pads silence and re-primes on underrun,
  drops the oldest audio on overflow, and skips back to the target when the fill
  runs far ahead (clock drift). Applies the output gain on read.
- `AmbientSettings` (Codable) persisted as one blob in `PreferencesStore`.
- `AmbientService` (`@MainActor`): the state machine. Owns the engine through
  the `AmbientEngine` protocol, consults the policy, handles output changes,
  vanished inputs, DoP pauses and engine switches. Tested with a fake engine,
  a fake device provider and a fake permission check.
- `AudioOutputManager` gains input listing, default input, and device summaries.

Core, hardware only (build-verified, tested by ear):

- `SplitAmbientEngine` (A): an input `AVAudioEngine` pinned to the mic with an
  `AVAudioSinkNode` that downmixes to mono, resamples when the rates differ,
  and writes the ring; an output `AVAudioEngine` pinned to the playback device
  with an `AVAudioSourceNode` reading the ring, then the low-cut EQ, then out.
  Delay = ring target.
- `CombinedAmbientEngine` (B): a private aggregate device (output as clock
  source, drift compensation on the mic) and one `AVAudioEngine`: input, low-cut
  EQ, mixer, output. Delay = device buffer size. The aggregate is destroyed on
  stop, and macOS removes private aggregates with the process.

Low cut: `AVAudioUnitEQ` high-pass at 120 Hz, bypassed when off.

App: `LibraryViewModel+Ambient.swift` publishes the service state and settings,
runs the alerts, shows notices, and wires DoP state from
`PlaybackService.isNativeDSDActive`. The AMBIENT pod reuses `VolumeKnob`.

Packaging: `NSMicrophoneUsageDescription` in `Info.plist`,
`com.apple.security.device.audio-input` in the entitlements.

## Release line

- `v2.1` from `main`: marketing 2.1.0, channel BETA. Build and beta ordinal are
  bumped by `press-the-record` at release.
- `update-appcast.sh` expects the beta feed on `v2.1` (`BETA_BRANCH`).
- The 2.0.0 beta DMG moved to `dist/updates-beta/old_updates`, so the beta feed
  starts with 2.1 only. 2.0.4 users get the full DMG, no delta.
- `press-the-record` and CLAUDE.md describe `v2.1` as the beta line.
- `betaExpiry` stays nil: the audience is stable users who opted in.

## Testing

Core XCTests: level curve; transport mapping and speaker detection; policy
(speakers blocked, headphone jack allowed, same Bluetooth device warns, approval
respected, everything else ok); ring buffer (priming, underrun pad, overflow,
drift skip, gain); settings defaults, decoding and persistence; service with
fakes (start, permission denied, blocked, call mode, output change rebuilds or
blocks, input vanished turns off, DoP pause and resume, engine switch rebuilds,
engine failure turns off).

App XCTest: `Info.plist` carries the mic usage string and the entitlements
carry `audio-input`. Missing either, a notarized build silently hears nothing.

Manual, on the signed package (the entitlement only matters under the hardened
runtime; confirm with `codesign -d --entitlements -`):

- Bluetooth headphones + Mac mic, both engines, all three delays
- Wired headphones + Mac mic
- A Bluetooth device's own mic triggers the warning
- Built-in speakers are refused
- Unplug the mic, and switch outputs, while running
- DSD over DoP while Ambient is on
- Permission denied

## Known ceilings

- Drift correction drops or pads whole frames; heavy drift may click. Upgrade
  path: adaptive resampling in the ring.
- The ring buffer uses `os_unfair_lock` on the audio threads (the deployment
  target predates `Mutex`). Critical sections are a few copies long.
- Speaker detection only covers built-in output that reports the `ispk` data
  source (a Mac16,8's speakers do). External speakers are allowed, and so is a
  built-in speaker that reports no data source; the headphone jack's device
  was not available to probe, and refusing it would break wired listening.
- Same-Bluetooth-device detection compares UIDs with any `:input` / `:output`
  suffix removed, then names. Probed: a UGREEN Bluetooth receiver appears as
  `F4-4E-FC-BE-BF-7A:input` and `F4-4E-FC-BE-BF-7A:output`.
