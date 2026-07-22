# OLED Visualizer — future screen plan

*Status: planned, not implemented (2026-07-22). Replaces the RTA spectrum-analyzer
screen, which shipped briefly on `beta/1.1.0-theming` and was removed the same week —
it pegged a core and "no one is going to mix music" with an RTA. This doc keeps the
lessons and the design so the build is cheap when we pick it up.*

## Concept

A retro **8/16-bit audio-reactive visualizer** on the OLED glass — something cool to
look at while listening, not a measurement tool. Think chunky pixels, limited palette,
CRT vibes: the OLED already sells the hardware fantasy.

## Why the RTA burned CPU (don't repeat this)

The RTA drew 12 columns × 14 segments = **168 individual SwiftUI views**, each with a
conditional `.shadow`, re-diffed up to 30×/s. It also raised `MeterDriver.bandQuantum`
from 1/6 to 1/14, so far more ticks produced a distinct publish → full body re-render.
The FFT itself (vDSP in the playback tap) is cheap and still runs for the footer meters.

**Hard rules for the visualizer:**
1. Render with **`TimelineView(.animation)` + `Canvas`** (or a `CALayer`-backed
   `NSViewRepresentable`) — one draw pass per frame, zero per-pixel SwiftUI views.
2. No `.shadow` per element; bake glow into the palette or one `blur` compositing pass.
3. Target ~20–24 fps; it's a lo-fi visualizer, jitter is aesthetic.
4. Run only while the screen is visible **and** playback is playing (RTA already did
   the start/stop-on-state part right — copy `syncRunning()`).

## Data source (already exists — no new DSP)

- `model.currentPlaybackSpectrum()` → 12 log bands, 20 Hz–20 kHz, volume-scaled.
- `model.currentPlaybackLevels()` → L/R levels.
- Cheap beat/onset detection: rising-edge threshold on the sum of the 2–3 lowest bands
  (spectral flux lite). No new dependencies.

## Visual design

- **Virtual pixel grid** ~64×24, integer-scaled to the pane with nearest-neighbor —
  the chunky-pixel look comes free and caps draw cost regardless of window size.
- Palette from `CarbonTheme` accents + `oledFG` (4–5 colors max, per 8-bit constraint).
- Keep the fixed OLED geometry: annunciator rail + bottom cells stay; the visualizer
  swaps into the same context zone the RTA used, with the same readout (clock + track).

### Modes (pick one per track by seeded hash of the file path — deterministic, no RNG)

1. **Starfield** — warp speed follows overall level; stars flash on beat.
2. **Pixel invader** — a little sprite dances/jumps on onsets; idle bob otherwise.
3. **Plasma** — classic sine-plasma; speed and palette cycling follow band energy.
4. **Fireworks** — a rocket per onset, burst size from bass energy.
5. **Oscilloscope** — fake Lissajous from L/R levels (retro scope green).

Start with **one** mode (starfield is the cheapest win), add the rest incrementally.
A long-press or repeated tap on the screen strip could manually cycle modes later.

## Integration checklist (when building)

- [ ] New `OLEDView` case `visualizer` (the old `vu` rawValue is retired; prefs with
      `"vu"` already fall back to NOW at restore — `LibraryViewModel.swift` restore path).
- [ ] Add to `DisplayModeButton.cycle` after `.nowPlaying`; accent `theme.cyanGlow`
      (the freed icy-teal slot); annunciator `"VIZ"` in `DisplayRail`.
- [ ] Pane file: `UI/Carbon/Header/VisualizerPane.swift` — `OLEDPaneScaffold` with the
      same readout/cells the RTA used (`LibraryNowPlayingCells.make`).
- [ ] Do **not** touch `MeterDriver.bandQuantum` — read the spectrum providers directly
      inside the `TimelineView` closure; the visualizer needs no quantized publishes at all.
- [ ] View-menu entry optional (RTA was deliberately chrome-only; keep that).
- [ ] Verify CPU with the snapshot hook + `ps -o %cpu` while playing: budget ≤ ~20%
      of one core above the NOW-screen baseline.
