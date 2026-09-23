# CrateDigger 2.3 cycle plan

2026-09-23. Status: **proposed**, waiting on the decisions at the end.
Follows 2.2.1 (build 96). Built on `v2.3`, cut from `main`.

## The idea of 2.3

2.2 added a lot of surface. 2.3 makes that surface **safe, legible and
reachable**, then ships the three features already designed or approved.
It does not open v3 work (smart crates, stock iPod sync); it prepares the
ground for it.

Sources: the 2026-09-23 UI/UX review (findings numbered below as R1 to R29;
R1, R2, R4, R5 and R6 shipped in 2.2.1), `website/roadmap.html`, the specs'
out-of-scope sections, and the CD Shelf spec on `feature/cd-shelf`.

## Opening the cycle

Per CLAUDE.md "Two release lines":

- [ ] Cut `v2.3` from `main` at 2.2.1; set `AppVersion.channel = "BETA"`,
      `marketing = "2.3.0"`, `channelOrdinal = "1"`.
- [ ] `BETA_BRANCH="v2.3"` in `scripts/update-appcast.sh`; the beta column of
      `.claude/skills/press-the-record/SKILL.md`; CLAUDE.md's release lines.
- [ ] Move the 2.2.0 DMG out of `dist/updates-beta/` into `old_updates`.
- [ ] Refresh `website/roadmap.html` (still says current v2.1.0 and lists none
      of 2.2) with this plan's "Next" column. Copy without dashes.
- [ ] Archive `docs/superpowers/plans/2026-09-19-beta-3-...md`; relabel
      `docs/OLED_VISUALIZER_PLAN.md` (still says "2.1 candidate").
- [ ] Decide on the stale branches: `worktree-theme-editor-pass`,
      `worktree-inspector-wide-layout`, `tooling/app-screenshots`,
      `origin/worktree-website-refresh`.

## Beta 1: trust and legibility (all S)

One batch of small, independent fixes from the review, plus two foundations.
Every decidable value goes in Core with a test; the rest is view glue.

| # | Fix | Core seam |
|---|---|---|
| R3 | Empty playlist, unconfigured remote and empty device get their own empty states, not "No library loaded / OPEN FOLDER" | `BrowserEmptyKind` + cases |
| R7 | Radio ▸ Downloads empty state says how to download | |
| R8 | "Set a destination" alerts carry a Choose Folder… button; one shared message; drop the "once that screen is available" copy | |
| R9 | View menu says "Now Playing", not "Now Display" / "Cnvrt Display" | `OLEDView.menuTitle` |
| R10 | A disabled `KeyButton` is disabled for VoiceOver and the keyboard too | |
| R11 | `carbonTip` always sets an accessibility label; the preference hides only the tooltip. "+" keys get names | |
| R12 | The global Space monitor leaves Space alone on a focused control, and only acts in the main window and mini player | |
| R13 | ADD TO CRATE names its target on the key; clicking a crate no longer silently retargets it | |
| R17 | DUB is reachable from DISPLAY and the View menu while a rip or download runs | `DisplayModeButton.cycle` |
| R19 | The Downloaded notice names the folder, with Show in Finder | |
| R22 | Subsonic sync says "30 OF N ARTISTS" with a Load All key | |
| R24 | DISPLAY key has an accessibility label and value | |
| R25 | One name each: Dig Crate, Library Cleanup, Settings, organize | |
| R27 | Sidebar section headers are buttons (keyboard and VoiceOver can collapse them); the Remote row shows no count instead of a misleading 0 when not selected | |
| R28 | FIX TAGS reads CHECK ALL when nothing is selected | |
| R29 | A search with no hits in a crate offers SEARCH ALL RECORDS | |

Foundations:

- **Native notifications** (roadmap). Scan, convert, rip, download and
  device sync done, posted only while the app is in the background. Guarded
  on a real bundle the way Sparkle is. S.
- **`LibraryIndex.build` off the main actor.** 830 ms on the main thread at
  15k tracks, cold. Groundwork for smart crates and for iPod reads, which
  both rebuild the whole library. S to M, Core with a test.

## Beta 2: reach (M)

- **R14 CONVERT is a real control.** Button trait, accessibility action,
  Cmd-Return to arm, and the hold hint visible at every width.
- **R15 One conversion UI.** Shift-Cmd-C queues the selection and opens the
  Patch Bay; the old options sheet stays only for the per-album review.
- **R16 Library and Track menus.** New Crate, New Playlist, Edit Tags, Fix
  Tags, Deep Scan, Cleanup, Record Divider, Add Stream, Download, Rip CD,
  Gallery, show and hide Sources and Inspector, EQ, Theme. Gated in
  `validateMenuItem` like the rest.
- **R18 Radio behaves like the library.** Click selects, double click
  plays, arrow keys walk `filteredStreams`, and the Radio inspector gets
  DOWNLOAD and ADD TO CRATE keys.
- **R21 One dialog system.** An `AppAlert.success` tone routed to
  `showOLEDNotice`, so "Library Moved", "Exported" and friends stop being
  modals; a dot coloured by tone; one destructive-confirm helper (2.2.1 added
  `LibraryViewModel.confirmDelete`, which is its seed).
- **R23 Text size.** Settings ▸ Interface: 100 / 115 / 130 %, applied in
  `CarbonFont`, plus a contrast floor for `ink4` on text.
- **R26 Dashes out of in-app copy** (if you agree: decision 5).

## Beta 3: two approved features (M each)

Each starts with a spec in `docs/superpowers/specs/`, then a task plan.

- **Versions in their own folders.** Approved 2026-09-17, no spec yet. Each
  version of one release gets its own folder on Move, Consolidate and
  conversion, with a flair appended only when two would collide. Conversion
  already offers "Album [2]" when the target holds foreign audio; the rule
  moves into `OutputPathPlanner` so every planner shares it.
- **Loudness normalisation** (roadmap). ffmpeg `ebur128` analysis into a
  path-keyed store beside `library.cdplays`, applied at playback through
  `AudioLevelTap.setMasterGain`, which already survives track changes and
  gapless handovers. The store is path-keyed, so every file mover must
  repoint it, like `ListeningStore` and `StreamStore`. The Replay-Gain switch
  comes back to the Patch Bay only once it does something.

## Beta 4: CD Shelf (M to L)

Fully designed on `feature/cd-shelf` (2026-09-15, written for 2.2). Every
disc you insert is remembered, browsable and playable when it is back in the
drive, identified by its MusicBrainz disc ID. It also fixes a real bug: every
disc's track N shares one play record keyed on `/Volumes/Audio CD/N Audio
Track.aiff`, and unidentified discs never count a play. The spec needs a
rebase: its line numbers predate 2.2, and the offline library changed how
sources load.

## Stretch, if a beta has room

- **R20 Record Divider you can hear.** A play button per boundary,
  click-to-edit times, a resizable sheet, a warning when zero rows are kept.
  A step toward v3's vinyl provenance.
- Kill the in-flight ffmpeg on conversion cancel.
- Up Next on the large widget.
- A CI build and test job.
- The OLED starfield visualizer.

## Design only in 2.3

- **The smart-crate rule language**, so v3 opens with smart crates and the
  HEALTH screen instead of a design debate. The spec and the 10-task plan
  exist (`2026-09-02-phase-2-3-...`); what is unsettled is the rules.

## Stays v3

Smart crates and Library health; stock-firmware iPod sync (four specs, spec 1
unapproved, design device mirror sync with it); extended library management;
vinyl and cassette provenance; the gear library; DJ tools; companion Wi-Fi
sync; `LibraryViewModel` slicing; offline editing with merge.

## Risks

- **`LibraryViewModel` is where bugs land.** The 2.0 whole-branch review
  found every cross-task defect in view-model glue. Keep the rule: decidable
  values in Core, with a test, even when the wiring stays untested.
- **Path-keyed stores.** Loudness adds a third. Grep every mover, not only the
  funnels that already call `repoint`; CLAUDE.md lists the two that were
  missed last time.
- **Index off main** changes when `index` is ready at launch. Anything that
  reads it during startup needs to wait for it, not assume it.

## Decisions for you

1. **Loudness target and scope.** Which reference level (-14, -16 or -18
   LUFS), per track or per album, and should conversion also write
   ReplayGain tags, or only playback apply it?
2. **Versions flair.** Edition label first, then the distinguisher's label:
   is that still the rule, and what is the fallback when neither exists
   (year, country, "[2]")?
3. **CD Shelf as designed?** It was written for 2.2. Still wanted, and still
   a separate source rather than part of All Records?
4. **Notifications.** Only while the app is in the background, or always?
   Which events?
5. **Dashes in the app.** 182 string literals contain a dash; many are the
   lone empty-value glyph and stay. Sweep the sentence ones?
6. **Beta cadence.** Four betas as above, or fold beta 2 into beta 1 and
   ship 2.3 in three?
