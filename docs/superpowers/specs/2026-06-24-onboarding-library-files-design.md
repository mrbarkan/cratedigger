# First-Run Onboarding + Library File Management — Design Note

Date: 2026-06-24
Status: Approved

## Vocabulary (user's model)

- **Library File** — a `.cdlib` crate index file.
- **Local Library** — the folder where albums/tracks live (can be an external drive).
- **Crates** — in-app top-level album categories (Gmail-tabs style); their indexes
  persist as `.cdlib` files.
- **Prep Crate** — temporary staging category.

## Three independent folders (not nested)

- **Local Library folder** → `managedLibraryFolderBookmark` (can be external).
- **Library File location** (crates index) → `cratesIndexFolderBookmark` (local).
- **Default Output** (conversion) → `outputDestinationBookmark`.

## 1. First-run onboarding

- Gated by a new pref `hasCompletedFirstRunSetup` (Bool).
- A Carbon SwiftUI sheet with three folder rows (label · one-line explainer · chosen
  path · **Choose…**), plus **"I already have a library — open it…"** (pick a folder
  that already contains `.cdlib` crates → use it as the Library File location).
- Sensible defaults pre-filled (`~/Music/CrateDigger/{Library, Crates, Converted}`),
  each overridable. **Get Started** persists the bookmarks, sets the flag, and ensures
  a Personal Crate exists. Skippable = accept defaults (dismiss applies defaults + sets
  the flag so it doesn't re-show).
- All three folders remain editable later in Preferences.

## 2. Library file management (File → Library submenu)

- **Import Library File…** — pick a `.cdlib`, copy it into the Library File folder, add
  it as a crate.
- **Export Library File…** — write the selected crate out to a `.cdlib` anywhere.
- **Back Up Library…** — zip **all** `.cdlib` indexes into a dated
  `CrateDigger-Library-YYYY-MM-DD.zip` (indexes only — audio in the Local Library is
  separate files).

## 3. FAQ / tutorial (follow-up, separate)

- **Help → CrateDigger Guide** — a Carbon window with a short FAQ/tutorial (Library vs
  Crates vs Prep Crate, the three folders, convert/backup). Built after #1–2 land.

## Architecture

- **PreferencesStore:** `hasCompletedFirstRunSetup` flag.
- **LibraryViewModel:** onboarding state + folder-pick methods (reusing the existing
  `makeBookmark`/`resolveBookmark` helpers) + library import/export/backup methods.
- **OnboardingView** (SwiftUI Carbon), presented via a `.sheet` driven by a `@Published`
  flag set in the view-model init when the flag is unset.
- **AppDelegate:** a File → Library submenu for import/export/backup.

## Decisions

- Backup = `.cdlib` indexes only.
- Onboarding is skippable (accepting defaults), not a hard gate.

## Out of scope (this iteration)

- The FAQ/tutorial window (#3) — a separate follow-up after onboarding + file ops.
