# Website Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Linear/CleanShot-style feature spotlight sections and a blog (3 launch articles + full SEO/GEO plumbing) to the static `website/` marketing site.

**Architecture:** Pure static HTML/CSS/JS, zero build tooling — matches the existing site exactly. New pages are hand-authored files under `website/blog/`, sharing the same nav/footer chrome and `index.css` stylesheet as the homepage. No JS framework, no templating engine, no new dependency.

**Tech Stack:** HTML5, CSS (existing `website/index.css`, extended not replaced), vanilla JS (existing `website/index.js`, no changes needed).

## Global Constraints

- Canonical domain for every absolute URL: `https://cratedigger.mrbarkan.com` (from the approved spec).
- No build tooling, no new dependency, no JS framework — plain static files only.
- All new pages default to `data-theme="dark"` (Carbon), matching the homepage's hardcoded default — there is no user-facing site-wide theme toggle (the existing theme switcher only swaps the demo screenshot, not the page theme).
- All new pages reuse `website/index.css` (`<link rel="stylesheet" href="../index.css">` from one directory down) — no second stylesheet file.
- Every page carries the same nav bar and footer structure as `website/index.html`, with relative hrefs adjusted for the file's depth.
- Full spec: `docs/superpowers/specs/2026-07-05-website-expansion-design.md`.

---

### Task 1: Capture 4 feature screenshots

**Files:**
- Create: `website/assets/screenshot_conversion.png`
- Create: `website/assets/screenshot_crates.png`
- Create: `website/assets/screenshot_radio.png`
- Create: `website/assets/screenshot_artwork.png`

**Interfaces:**
- Produces: 4 PNG files at `website/assets/` referenced by `src="assets/screenshot_*.png"` in Task 3's spotlight `<img>` tags.

This is the one exploratory task in the plan — there's no computer-use desktop tool connected in this session, so it's driven from Bash via `screencapture` + AppleScript System Events, reading back each PNG with the Read tool to check framing before moving on. Treat coordinates as discovered live, not pre-specified.

- [ ] **Step 1: Build and launch the debug binary**

```bash
swift build
.build/arm64-apple-macosx/debug/CrateDiggerApp &
sleep 3
osascript -e 'tell application "System Events" to tell process "CrateDiggerApp" to set frontmost to true'
```

If `osascript` errors with something like "not allowed assistive access", stop and ask the user to grant Accessibility permission to Terminal/iTerm (System Settings → Privacy & Security → Accessibility), or to capture the 4 shots manually — don't retry blindly.

- [ ] **Step 2: Get the window bounds and take a baseline screenshot**

```bash
osascript -e 'tell application "System Events" to tell process "CrateDiggerApp" to get {position, size} of window 1'
```

Use the returned `{x, y}` / `{w, h}` for every subsequent capture:

```bash
screencapture -x -R "$X,$Y,$W,$H" /Users/mrbarkan/Development/Code/CrateDigger/website/assets/_baseline.png
```

Read `_baseline.png` to see the current state of the app (library view is fine as a starting point).

- [ ] **Step 3: Capture the conversion / Patch Bay view**

Click into the OLED conversion mode (per `CLAUDE.md`, selecting `conversion` in the `OLEDView` mode switch swaps the Inspector for the "Patch Bay" and auto-collapses the browser) via `System Events` clicks on the coordinates found from the baseline screenshot, then:

```bash
screencapture -x -R "$X,$Y,$W,$H" /Users/mrbarkan/Development/Code/CrateDigger/website/assets/screenshot_conversion.png
```

Read the file back to confirm the Patch Bay is actually visible before moving on.

- [ ] **Step 4: Capture the Crates / Prep Crate view**

Click the Sources sidebar to select the Prep Crate source, then capture:

```bash
screencapture -x -R "$X,$Y,$W,$H" /Users/mrbarkan/Development/Code/CrateDigger/website/assets/screenshot_crates.png
```

- [ ] **Step 5: Capture the Radio view**

Select the Radio source in the sidebar. If a stream needs to be added first and the field needs typing, try `System Events`' `keystroke` (this is a different permission gate than the computer-use extension's click/type tiers, so typing may work here even though the memory notes it doesn't via computer-use):

```bash
osascript -e 'tell application "System Events" to keystroke "https://www.youtube.com/watch?v=jfKfPfyJRdk"'
```

If `keystroke` also fails, stop here and ask the user to paste a YouTube URL into the Radio field themselves, then re-run just this capture:

```bash
screencapture -x -R "$X,$Y,$W,$H" /Users/mrbarkan/Development/Code/CrateDigger/website/assets/screenshot_radio.png
```

- [ ] **Step 6: Capture the Artwork viewer**

Click a track's artwork / open the Album Artwork Viewer, then:

```bash
screencapture -x -R "$X,$Y,$W,$H" /Users/mrbarkan/Development/Code/CrateDigger/website/assets/screenshot_artwork.png
```

- [ ] **Step 7: Clean up and verify all 4 files exist**

```bash
pkill -f CrateDiggerApp
rm -f /Users/mrbarkan/Development/Code/CrateDigger/website/assets/_baseline.png
ls -la /Users/mrbarkan/Development/Code/CrateDigger/website/assets/screenshot_conversion.png \
       /Users/mrbarkan/Development/Code/CrateDigger/website/assets/screenshot_crates.png \
       /Users/mrbarkan/Development/Code/CrateDigger/website/assets/screenshot_radio.png \
       /Users/mrbarkan/Development/Code/CrateDigger/website/assets/screenshot_artwork.png
```

Expected: all 4 files listed with non-zero size.

- [ ] **Step 8: Commit**

```bash
git add website/assets/screenshot_conversion.png website/assets/screenshot_crates.png website/assets/screenshot_radio.png website/assets/screenshot_artwork.png
git commit -m "feat(website): capture feature spotlight screenshots"
```

---

### Task 2: Homepage SEO/GEO head additions

**Files:**
- Modify: `website/index.html:6-16`

**Interfaces:**
- Produces: canonical link, OG/Twitter tags, and `Organization`/`SoftwareApplication` JSON-LD in `<head>`, establishing the meta-tag pattern Tasks 6-9's pages copy.

- [ ] **Step 1: Insert canonical link, Open Graph, Twitter Card, and JSON-LD**

In `website/index.html`, replace:

```html
  <meta name="description" content="CrateDigger is a native macOS music utility with a skeuomorphic hardware aesthetic. Scan, tag, batch-convert, and organize your offline music library.">
  
  <!-- Modern Typography -->
```

with:

```html
  <meta name="description" content="CrateDigger is a native macOS music utility with a skeuomorphic hardware aesthetic. Scan, tag, batch-convert, and organize your offline music library.">
  <link rel="canonical" href="https://cratedigger.mrbarkan.com/">

  <!-- Open Graph -->
  <meta property="og:type" content="website">
  <meta property="og:title" content="CrateDigger — Bringing the fun back to managing your offline music">
  <meta property="og:description" content="A native macOS music utility with a skeuomorphic hardware aesthetic. Scan, tag, batch-convert, and organize your offline music library.">
  <meta property="og:url" content="https://cratedigger.mrbarkan.com/">
  <meta property="og:image" content="https://cratedigger.mrbarkan.com/assets/app_icon.png">
  <meta property="og:site_name" content="CrateDigger">

  <!-- Twitter Card -->
  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:title" content="CrateDigger — Bringing the fun back to managing your offline music">
  <meta name="twitter:description" content="A native macOS music utility with a skeuomorphic hardware aesthetic. Scan, tag, batch-convert, and organize your offline music library.">
  <meta name="twitter:image" content="https://cratedigger.mrbarkan.com/assets/app_icon.png">

  <!-- Structured Data -->
  <script type="application/ld+json">
  {
    "@context": "https://schema.org",
    "@type": "Organization",
    "name": "CrateDigger",
    "url": "https://cratedigger.mrbarkan.com/",
    "logo": "https://cratedigger.mrbarkan.com/assets/app_icon.png"
  }
  </script>
  <script type="application/ld+json">
  {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    "name": "CrateDigger",
    "operatingSystem": "macOS 13+",
    "applicationCategory": "MusicApplication",
    "offers": {
      "@type": "Offer",
      "price": "0",
      "priceCurrency": "USD"
    },
    "description": "A native macOS music utility with a skeuomorphic hardware aesthetic. Scan, tag, batch-convert, and organize your offline music library."
  }
  </script>

  <!-- Modern Typography -->
```

- [ ] **Step 2: Verify the JSON-LD parses and required tags are present**

```bash
python3 -c "
import re, json
text = open('website/index.html').read()
blocks = re.findall(r'<script type=\"application/ld\+json\">(.*?)</script>', text, re.S)
assert len(blocks) == 2, f'expected 2 JSON-LD blocks, got {len(blocks)}'
for b in blocks:
    json.loads(b)
print('OK:', len(blocks), 'JSON-LD blocks parse')
"
grep -q 'rel="canonical"' website/index.html && grep -q 'property="og:title"' website/index.html && echo "OK: canonical + OG present"
```

Expected: both `OK:` lines print, no exceptions.

- [ ] **Step 3: Commit**

```bash
git add website/index.html
git commit -m "feat(website): add SEO/GEO meta tags and JSON-LD to homepage"
```

---

### Task 3: Homepage feature spotlight sections

**Files:**
- Modify: `website/index.html` (insert new section after the `demo-section` closing `</section>`, before `<!-- Core Features Section -->`)
- Modify: `website/index.css` (append new rules; extend the existing `@media (max-width: 1024px)` block)

**Interfaces:**
- Consumes: `website/assets/screenshot_conversion.png`, `screenshot_crates.png`, `screenshot_radio.png`, `screenshot_artwork.png` (Task 1).
- Produces: `.spotlight-section`, `.spotlight-row`, `.spotlight-row.reverse`, `.spotlight-media`, `.spotlight-img`, `.spotlight-copy`, `.spotlight-eyebrow`, `.spotlight-title`, `.spotlight-text`, `.spotlight-list` CSS classes — no other task reuses these, but keep the names as-is for consistency with the design doc.

- [ ] **Step 1: Insert the 4 spotlight sections into `index.html`**

Insert immediately before the line `  <!-- Core Features Section -->`:

```html
  <!-- Feature Spotlights -->
  <section class="spotlight-section" id="spotlights">
    <div class="container">

      <div class="spotlight-row">
        <div class="spotlight-media">
          <img src="assets/screenshot_conversion.png" alt="CrateDigger batch conversion Patch Bay view" class="spotlight-img">
        </div>
        <div class="spotlight-copy">
          <span class="spotlight-eyebrow">Conversion Engine</span>
          <h3 class="spotlight-title">Batch-convert your whole library, safely.</h3>
          <p class="spotlight-text">
            CrateDigger's FFmpeg engine queues entire directories of mixed formats at once, using every core but one. Every destination path is planned before a single file is written.
          </p>
          <ul class="spotlight-list">
            <li>Flat, source-relative, or metadata-template folder output</li>
            <li>Collision-safe naming — never silently overwrites a file</li>
            <li>Review sheet shows every destination path before you commit</li>
            <li>Preflight checks disk space and write permissions first</li>
          </ul>
        </div>
      </div>

      <div class="spotlight-row reverse">
        <div class="spotlight-media">
          <img src="assets/screenshot_crates.png" alt="CrateDigger Prep Crate staging sidebar" class="spotlight-img">
        </div>
        <div class="spotlight-copy">
          <span class="spotlight-eyebrow">Library Organization</span>
          <h3 class="spotlight-title">Stage new imports before they join your library.</h3>
          <p class="spotlight-text">
            Newly scanned folders land in the Prep Crate first — a staging area for tagging and review — instead of dumping straight into your permanent collection.
          </p>
          <ul class="spotlight-list">
            <li>Crates are portable, human-readable <code>.cdlib</code> JSON files</li>
            <li>Review and tag imports before they touch your main crates</li>
            <li>Switch instantly between local, remote, CD, and playlist sources</li>
            <li>No proprietary database — your library folders stay yours</li>
          </ul>
        </div>
      </div>

      <div class="spotlight-row">
        <div class="spotlight-media">
          <img src="assets/screenshot_radio.png" alt="CrateDigger Radio streaming a YouTube source" class="spotlight-img">
        </div>
        <div class="spotlight-copy">
          <span class="spotlight-eyebrow">Radio</span>
          <h3 class="spotlight-title">Stream YouTube live sets and mixes, right in your library.</h3>
          <p class="spotlight-text">
            Paste a YouTube link and CrateDigger resolves it to a playable stream alongside your offline tracks — no separate app or browser tab.
          </p>
          <ul class="spotlight-list">
            <li>Supports live streams, videos, mixes, and playlists</li>
            <li>Sources grouped into sidebar categories like "YT Live" and "YT Records"</li>
            <li>Chapter markers surface for long DJ sets and mixes</li>
            <li>Same transport, EQ, and VU meters as local playback</li>
          </ul>
        </div>
      </div>

      <div class="spotlight-row reverse">
        <div class="spotlight-media">
          <img src="assets/screenshot_artwork.png" alt="CrateDigger album artwork inspector and viewer" class="spotlight-img">
        </div>
        <div class="spotlight-copy">
          <span class="spotlight-eyebrow">Artwork</span>
          <h3 class="spotlight-title">See your covers the way they deserve to be seen.</h3>
          <p class="spotlight-text">
            The artwork inspector resolves embedded art, folder images, and remote iTunes covers into one hash-keyed store, then lets you browse it full-size.
          </p>
          <ul class="spotlight-list">
            <li>Full-size album artwork viewer, not just a thumbnail</li>
            <li>Falls back from embedded art → folder image → remote lookup</li>
            <li>Supports album booklets — scanned inserts and liner-note PDFs</li>
            <li>One shared artwork cache, so covers load instantly across crates</li>
          </ul>
        </div>
      </div>

    </div>
  </section>

```

- [ ] **Step 2: Append spotlight CSS to `index.css`**

Add before the `/* Features Section */` comment block:

```css
/* ==========================================================================
   Feature Spotlights
   ========================================================================== */

.spotlight-section {
  padding: 40px 0 80px;
}

.spotlight-row {
  display: grid;
  grid-template-columns: 1fr 1fr;
  align-items: center;
  gap: 60px;
  margin-bottom: 100px;
}

.spotlight-row:last-child {
  margin-bottom: 0;
}

.spotlight-row.reverse .spotlight-media {
  order: 2;
}

.spotlight-row.reverse .spotlight-copy {
  order: 1;
}

.spotlight-media {
  border-radius: 20px;
  overflow: hidden;
  border: 1px solid var(--border);
  box-shadow: 0 30px 60px rgba(0, 0, 0, 0.35);
}

.spotlight-img {
  display: block;
  width: 100%;
  height: auto;
}

.spotlight-eyebrow {
  display: inline-block;
  font-family: var(--font-mono);
  font-size: 11px;
  font-weight: 700;
  letter-spacing: 0.14em;
  text-transform: uppercase;
  color: var(--cyan);
  margin-bottom: 14px;
}

.spotlight-title {
  font-size: 30px;
  line-height: 1.2;
  margin-bottom: 16px;
}

.spotlight-text {
  font-size: 15px;
  line-height: 1.6;
  color: var(--text-muted);
  margin-bottom: 20px;
}

.spotlight-list {
  list-style: none;
  display: flex;
  flex-direction: column;
  gap: 10px;
}

.spotlight-list li {
  font-size: 14px;
  color: var(--text-muted);
  padding-left: 22px;
  position: relative;
}

.spotlight-list li::before {
  content: "";
  position: absolute;
  left: 0;
  top: 7px;
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: var(--coral);
  box-shadow: 0 0 6px var(--coral);
}

```

Then, inside the existing `@media (max-width: 1024px)` block, add:

```css
  .spotlight-row {
    grid-template-columns: 1fr;
    gap: 30px;
    margin-bottom: 60px;
  }

  .spotlight-row.reverse .spotlight-media,
  .spotlight-row.reverse .spotlight-copy {
    order: initial;
  }
```

- [ ] **Step 3: Verify HTML parses and all 4 images resolve**

```bash
python3 -c "
import html.parser
html.parser.HTMLParser().feed(open('website/index.html').read())
print('OK: index.html parses')
"
python3 -c "
import re, os
text = open('website/index.html').read()
for url in re.findall(r'src=\"(assets/screenshot_[a-z]+\.png)\"', text):
    assert os.path.exists(os.path.join('website', url)), f'missing {url}'
print('OK: all 4 spotlight images resolve')
"
```

Expected: both `OK:` lines print.

- [ ] **Step 4: Commit**

```bash
git add website/index.html website/index.css
git commit -m "feat(website): add feature spotlight sections to homepage"
```

---

### Task 4: Feature grid — trim overlapping cards, add 3 new ones

**Files:**
- Modify: `website/index.html:187-233` (the `.features-grid` block)

**Interfaces:**
- Consumes: none new (reuses existing `.feature-card`/`.feature-icon`/`.font-icon` CSS — no CSS changes in this task).

- [ ] **Step 1: Remove the 3 cards now covered by spotlight #1, add 3 new cards**

Replace:

```html
        <div class="feature-card">
          <div class="feature-icon font-icon">⚙️</div>
          <h3 class="feature-card-title">Batch FFmpeg Engine</h3>
          <p class="feature-card-text">
            Converts entire directories of mixed audio formats. Powered by multi-threaded operations, CrateDigger queues runs (utilizing all but one core) for rapid encoding, artwork preservation, and tag injection.
          </p>
        </div>

        <div class="feature-card">
          <div class="feature-icon font-icon">📁</div>
          <h3 class="feature-card-title">Collision-Safe Path Planner</h3>
          <p class="feature-card-text">
            Organize output structures automatically using Flat, Source-Relative, or Metadata-Template modes. Guarantees file safety by generating unique non-colliding file names instead of overwriting existing paths.
          </p>
        </div>

        <div class="feature-card">
          <div class="feature-icon font-icon">🏷️</div>
          <h3 class="feature-card-title">Review Album Folders</h3>
          <p class="feature-card-text">
            Don't trust script automation blind. CrateDigger provides an interactive sheet that maps and displays destination paths for each album, allowing you to edit target folder names directly before running the conversion.
          </p>
        </div>
```

with:

```html
        <div class="feature-card">
          <div class="feature-icon font-icon">✂️</div>
          <h3 class="feature-card-title">Record Divider</h3>
          <p class="feature-card-text">
            Split one continuous vinyl-side rip into clean per-track exports. Auto-detects breaks from sustained silence, with a sensitivity slider and manual marker editing before you commit.
          </p>
        </div>

        <div class="feature-card">
          <div class="feature-icon font-icon">🔌</div>
          <h3 class="feature-card-title">External Device Transfer</h3>
          <p class="feature-card-text">
            Push tracks straight to an iPod, USB drive, or phone with ⌘⇧T. CrateDigger detects connected devices and lets you browse and transfer without leaving your library.
          </p>
        </div>

        <div class="feature-card">
          <div class="feature-icon font-icon">🛡️</div>
          <h3 class="feature-card-title">Sandbox & Preflight Safety</h3>
          <p class="feature-card-text">
            Runs fully sandboxed with security-scoped bookmarks for every folder you grant access to. Every batch job checks destination write permissions and free disk space before it starts.
          </p>
        </div>
```

The unchanged cards (CD Ripper & Subsonic Client, Tactile Hardware Feel, Last.fm & Metadata Probes) stay exactly as-is — grid is still 6 cards, 2 rows of 3.

- [ ] **Step 2: Verify the grid still has exactly 6 cards**

```bash
python3 -c "
import re
text = open('website/index.html').read()
grid = text.split('features-grid\">')[1].split('</div>\n    </div>\n  </section>')[0]
count = grid.count('feature-card\">')
assert count == 6, f'expected 6 feature-card divs, got {count}'
print('OK: 6 feature cards')
"
```

Expected: `OK: 6 feature cards`.

- [ ] **Step 3: Commit**

```bash
git add website/index.html
git commit -m "feat(website): refresh feature grid — fold conversion cards into spotlight, add 3 new"
```

---

### Task 5: Comparison table — add Swinsian, correct 2 stale claims

**Files:**
- Modify: `website/index.html:246-302` (the `.comparison-table`)

**Interfaces:** none — content-only change, reuses existing `.feat-yes`/`.feat-no`/`.highlight` CSS.

Research backing this task (confirmed via WebFetch against swinsian.com and foobar2000.org during planning):
- **Swinsian**: $34.95 one-time, macOS-only. No batch conversion/transcoding, no CD ripping, no streaming-service sync beyond an Apple Music library import. Flat/smart playlists only, no staging concept. Proprietary internal library, not portable JSON. Native macOS app.
- **foobar2000**: has a genuine native macOS build (not a Wine wrapper — Wine is only for running the *Windows* build on *Linux*). Built-in converter ("File > Convert") plus CD ripping, not a third-party plugin. The existing table's "Wine wrapper/Basic port" and "Requires external plugin setup" claims are stale/inaccurate and are corrected here.
- **Plex/Navidrome**: the existing table already describes it as "Electron client or web browser" in the description text, but scores it ✓ Yes for "Native macOS Performance" — that's a self-contradiction (Electron/web isn't native). Corrected to ✗ No.

- [ ] **Step 1: Add the Swinsian header column**

Replace:

```html
            <tr>
              <th>Feature</th>
              <th class="highlight">CrateDigger</th>
              <th>Apple Music / iTunes</th>
              <th>Foobar2000</th>
              <th>Plex / Navidrome</th>
            </tr>
```

with:

```html
            <tr>
              <th>Feature</th>
              <th class="highlight">CrateDigger</th>
              <th>Apple Music / iTunes</th>
              <th>Foobar2000</th>
              <th>Plex / Navidrome</th>
              <th>Swinsian</th>
            </tr>
```

- [ ] **Step 2: Add a Swinsian cell to every row, and correct the 2 stale cells**

Replace each of the 6 `<tr>` bodies with the versions below (only the Foobar2000/Plex cells for "Batch FFmpeg Conversion" and "Native macOS Performance" actually change value; the rest just gain a trailing Swinsian `<td>`):

```html
            <tr>
              <td class="feat-name">Batch FFmpeg Conversion</td>
              <td class="highlight feat-yes">✓ Yes (Built-in, Multi-threaded)</td>
              <td class="feat-no">✗ Single file only (AAC/ALAC)</td>
              <td class="feat-yes">✓ Yes (Built-in converter + CD ripping)</td>
              <td class="feat-no">✗ No (On-the-fly streaming transcode only)</td>
              <td class="feat-no">✗ No (Playback-only, no transcoding)</td>
            </tr>
            <tr>
              <td class="feat-name">Tactile Hardware Interface</td>
              <td class="highlight feat-yes">✓ Yes (Carbon/Linen Themes)</td>
              <td class="feat-no">✗ No (Modern flat list style)</td>
              <td class="feat-no">✗ No (Windows-classic sheet grids)</td>
              <td class="feat-no">✗ No (Responsive grid layout)</td>
              <td class="feat-no">✗ No (Standard native list/table UI)</td>
            </tr>
            <tr>
              <td class="feat-name">Collision-Safe Path Renamer</td>
              <td class="highlight feat-yes">✓ Yes (Flat / Template / Mirror)</td>
              <td class="feat-no">✗ No (Forces proprietary folders)</td>
              <td class="feat-yes">✓ Yes (Complex tag-scripts)</td>
              <td class="feat-no">✗ No (Requires prep-organized folders)</td>
              <td class="feat-no">✗ No (No batch export/rename)</td>
            </tr>
            <tr>
              <td class="feat-name">Double-Tier Crate Staging</td>
              <td class="highlight feat-yes">✓ Yes (Prep Crate vs. Saved Crates)</td>
              <td class="feat-no">✗ No (Imports directly to main database)</td>
              <td class="feat-no">✗ No (Flat playlists only)</td>
              <td class="feat-no">✗ No (Monolithic library folders)</td>
              <td class="feat-no">✗ No (Flat/smart playlists only)</td>
            </tr>
            <tr>
              <td class="feat-name">JSON Portable Libraries</td>
              <td class="highlight feat-yes">✓ Yes (Lightweight .cdlib files)</td>
              <td class="feat-no">✗ No (Locked in binary SQLite/XML db)</td>
              <td class="feat-no">✗ No (Proprietary database binary)</td>
              <td class="feat-no">✗ No (SQL databases on server host)</td>
              <td class="feat-no">✗ No (Proprietary internal library)</td>
            </tr>
            <tr>
              <td class="feat-name">Native macOS Performance</td>
              <td class="highlight feat-yes">✓ Yes (AppKit/SwiftUI + Sandbox)</td>
              <td class="feat-yes">✓ Yes (Native, but bloated)</td>
              <td class="feat-yes">✓ Yes (Genuine native macOS build)</td>
              <td class="feat-no">✗ No (Electron client or web browser)</td>
              <td class="feat-yes">✓ Yes (Native, lightweight)</td>
            </tr>
```

- [ ] **Step 3: Verify every row has 6 cells and the table still parses**

```bash
python3 -c "
import re, html.parser
html.parser.HTMLParser().feed(open('website/index.html').read())
text = open('website/index.html').read()
table = text.split('comparison-table\">')[1].split('</table>')[0]
rows = re.findall(r'<tr>(.*?)</tr>', table, re.S)
for i, row in enumerate(rows):
    cells = re.findall(r'<t[hd]', row)
    assert len(cells) == 6, f'row {i} has {len(cells)} cells, expected 6'
print('OK:', len(rows), 'rows all have 6 cells')
"
```

Expected: `OK: 7 rows all have 6 cells` (1 header + 6 data rows).

- [ ] **Step 4: Commit**

```bash
git add website/index.html
git commit -m "feat(website): add Swinsian to comparison table, correct stale foobar2000/Plex claims"
```

---

### Task 6: Blog styles + Post 1 — "Swinsian vs. CrateDigger vs. Foobar2000"

**Files:**
- Create: `website/blog/swinsian-vs-cratedigger-vs-foobar2000.html`
- Modify: `website/index.css` (append blog + article CSS)

**Interfaces:**
- Produces CSS classes reused by Tasks 7-9: `.blog-hero`, `.blog-list-section`, `.post-grid`, `.post-card` (+ `-date`/`-title`/`-excerpt`/`-read`), `.article-section`, `.article-container`, `.breadcrumb`, `.article-header`, `.article-eyebrow`, `.article-title`, `.article-meta`, `.article-body`, `.article-faq`, `.faq-item`, `.article-cta`, `.related-posts`, `.related-posts-grid`.
- Produces: `website/blog/swinsian-vs-cratedigger-vs-foobar2000.html` — linked from Task 9's index and Task 10's feed.

Content brief for this article — write real prose from these facts (word count target ~1100-1300, `datePublished` 2026-07-05):

1. **Intro (~100 words):** why a native, offline library manager still matters in 2026 even though Apple Music/Spotify dominate — you own the files, you control the formats.
2. **The three contenders:** Swinsian ($34.95 one-time, macOS-only, playback + library veteran), foobar2000 (free, plugin/component architecture, genuinely native on Windows/macOS/Android/iOS), CrateDigger (free, MIT-licensed, hardware-inspired UI, batch conversion + organization focus).
3. **Batch conversion & format handling:** Swinsian has no transcoding — it plays FLAC/MP3/AAC/ALAC/OGG/WMA/WAV/Opus/AC3/AIFF/MusePack/DSF/APE but doesn't convert between them. foobar2000 has a built-in converter plus CD ripping via its component architecture. CrateDigger's FFmpeg engine batch-converts whole directories, multi-threaded, with collision-safe output naming and 3 folder modes.
4. **Library organization:** Swinsian's real strengths here — folder watching, Apple Music library import, a duplicate-track finder with flexible criteria, smart playlists, regex find-and-replace tagging. foobar2000 leans on tag-script-driven renaming and playlists. CrateDigger's Prep Crate stages new imports for review before they join a saved crate, and crates are portable `.cdlib` JSON files rather than a database.
5. **Interface & feel:** Swinsian is a classic native table/list UI with a mini window and desktop widget. foobar2000's Layout Editing Mode makes it endlessly customizable but with a real learning curve. CrateDigger trades some of that blank-slate flexibility for a designed-out Carbon/Linen hardware aesthetic — OLED display, physical-feeling transport controls.
6. **Price & platform:** Swinsian $34.95 one-time, macOS only. foobar2000 free, Windows/macOS/Android/iOS. CrateDigger free & open source (MIT) + optional Patreon, macOS 13+ only.
7. **Which should you pick:** Swinsian if you want a mature EQ-rich player with duplicate-finding and don't need conversion; foobar2000 if you want maximum plugin flexibility across platforms; CrateDigger if batch conversion, organized output, and a tactile interface are the priority.

FAQ section (3 Q&A, feeds an `FAQPage` JSON-LD block):
- "Is there a free alternative to Swinsian on Mac?" → Yes — foobar2000 and CrateDigger are both free; CrateDigger is also MIT-licensed and open source.
- "Does Swinsian convert or transcode audio files?" → No — it's a playback/library tool, no batch format conversion.
- "Can foobar2000 run natively on macOS?" → Yes, it ships an official native macOS build alongside Windows, Android, and iOS.

- [ ] **Step 1: Append blog + article CSS to `index.css`**

Add before the `/* Footer */` comment block:

```css
/* ==========================================================================
   Blog
   ========================================================================== */

.blog-hero {
  padding: 150px 0 40px;
  text-align: center;
}

.blog-hero .hero-lead {
  max-width: 600px;
  margin: 0 auto;
}

.blog-list-section {
  padding: 40px 0 100px;
}

.post-grid {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 30px;
}

.post-card {
  display: flex;
  flex-direction: column;
  background: var(--card-bg);
  border: 1px solid var(--border);
  border-radius: 20px;
  padding: 28px;
  transition: all 0.3s cubic-bezier(0.16, 1, 0.3, 1);
}

.post-card:hover {
  transform: translateY(-5px);
  border-color: var(--cyan);
  box-shadow: 0 20px 40px rgba(0,0,0,0.15);
}

.post-card-date {
  font-family: var(--font-mono);
  font-size: 11px;
  letter-spacing: 0.1em;
  color: var(--cyan);
  margin-bottom: 12px;
}

.post-card-title {
  font-size: 18px;
  margin-bottom: 10px;
}

.post-card-excerpt {
  font-size: 14px;
  color: var(--text-muted);
  line-height: 1.6;
  margin-bottom: 16px;
  flex-grow: 1;
}

.post-card-read {
  font-size: 13px;
  font-weight: 600;
  color: var(--coral);
}

/* Article */
.article-section {
  padding: 150px 0 100px;
}

.article-container {
  max-width: 720px;
  margin: 0 auto;
  padding: 0 24px;
}

.breadcrumb {
  font-size: 13px;
  color: var(--text-muted);
  margin-bottom: 24px;
}

.breadcrumb a {
  color: var(--cyan);
}

.article-header {
  margin-bottom: 40px;
}

.article-eyebrow {
  font-family: var(--font-mono);
  font-size: 11px;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  color: var(--cyan);
  margin-bottom: 14px;
  display: block;
}

.article-title {
  font-size: 38px;
  line-height: 1.15;
  margin-bottom: 14px;
}

.article-meta {
  font-size: 13px;
  color: var(--text-muted);
  font-family: var(--font-mono);
}

.article-body h2 {
  font-size: 24px;
  margin: 40px 0 16px;
}

.article-body p {
  font-size: 16px;
  line-height: 1.75;
  color: var(--text-muted);
  margin-bottom: 20px;
}

.article-body ul, .article-body ol {
  margin: 0 0 20px 20px;
  color: var(--text-muted);
}

.article-body li {
  font-size: 16px;
  line-height: 1.75;
  margin-bottom: 8px;
}

.article-body code {
  font-family: var(--font-mono);
  background: var(--well);
  padding: 2px 6px;
  border-radius: 4px;
  font-size: 14px;
}

.article-faq {
  margin-top: 50px;
  padding-top: 30px;
  border-top: 1px solid var(--border);
}

.article-faq h2 {
  font-size: 22px;
  margin-bottom: 20px;
}

.faq-item {
  margin-bottom: 20px;
}

.faq-item h3 {
  font-size: 16px;
  margin-bottom: 6px;
}

.faq-item p {
  font-size: 15px;
  color: var(--text-muted);
  line-height: 1.6;
}

.article-cta {
  margin-top: 50px;
  padding: 30px;
  background: var(--card-bg);
  border: 1px solid var(--border);
  border-radius: 16px;
  text-align: center;
}

.article-cta p {
  margin-bottom: 16px;
  color: var(--text-muted);
}

.related-posts {
  margin-top: 60px;
  padding-top: 30px;
  border-top: 1px solid var(--border);
}

.related-posts h2 {
  font-size: 20px;
  margin-bottom: 20px;
}

.related-posts-grid {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 20px;
}

```

Then, inside the existing `@media (max-width: 768px)` block, add:

```css
  .post-grid {
    grid-template-columns: 1fr;
  }

  .related-posts-grid {
    grid-template-columns: 1fr;
  }

  .article-title {
    font-size: 28px;
  }
```

- [ ] **Step 2: Write `website/blog/swinsian-vs-cratedigger-vs-foobar2000.html`**

Full page skeleton (fill `<!-- ... -->` body markers with the prose from the content brief above; keep every tag shown, including breadcrumb, meta, and the 3 JSON-LD blocks):

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Swinsian vs. CrateDigger vs. Foobar2000: Native macOS Music Library Managers in 2026</title>
  <meta name="description" content="Comparing Swinsian, CrateDigger, and foobar2000 for macOS — batch conversion, tagging, library organization, and price — so you can pick the right offline music manager.">
  <link rel="canonical" href="https://cratedigger.mrbarkan.com/blog/swinsian-vs-cratedigger-vs-foobar2000.html">

  <meta property="og:type" content="article">
  <meta property="og:title" content="Swinsian vs. CrateDigger vs. Foobar2000: Native macOS Music Library Managers in 2026">
  <meta property="og:description" content="Comparing Swinsian, CrateDigger, and foobar2000 for macOS — batch conversion, tagging, library organization, and price.">
  <meta property="og:url" content="https://cratedigger.mrbarkan.com/blog/swinsian-vs-cratedigger-vs-foobar2000.html">
  <meta property="og:image" content="https://cratedigger.mrbarkan.com/assets/app_icon.png">
  <meta property="og:site_name" content="CrateDigger">

  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:title" content="Swinsian vs. CrateDigger vs. Foobar2000: Native macOS Music Library Managers in 2026">
  <meta name="twitter:description" content="Comparing Swinsian, CrateDigger, and foobar2000 for macOS — batch conversion, tagging, library organization, and price.">
  <meta name="twitter:image" content="https://cratedigger.mrbarkan.com/assets/app_icon.png">

  <link rel="alternate" type="application/rss+xml" title="CrateDigger Blog" href="feed.xml">

  <script type="application/ld+json">
  {
    "@context": "https://schema.org",
    "@type": "Article",
    "headline": "Swinsian vs. CrateDigger vs. Foobar2000: Native macOS Music Library Managers in 2026",
    "datePublished": "2026-07-05",
    "dateModified": "2026-07-05",
    "author": { "@type": "Organization", "name": "CrateDigger" },
    "publisher": {
      "@type": "Organization",
      "name": "CrateDigger",
      "logo": { "@type": "ImageObject", "url": "https://cratedigger.mrbarkan.com/assets/app_icon.png" }
    },
    "image": "https://cratedigger.mrbarkan.com/assets/app_icon.png",
    "mainEntityOfPage": "https://cratedigger.mrbarkan.com/blog/swinsian-vs-cratedigger-vs-foobar2000.html"
  }
  </script>
  <script type="application/ld+json">
  {
    "@context": "https://schema.org",
    "@type": "BreadcrumbList",
    "itemListElement": [
      { "@type": "ListItem", "position": 1, "name": "Home", "item": "https://cratedigger.mrbarkan.com/" },
      { "@type": "ListItem", "position": 2, "name": "Blog", "item": "https://cratedigger.mrbarkan.com/blog/index.html" },
      { "@type": "ListItem", "position": 3, "name": "Swinsian vs. CrateDigger vs. Foobar2000", "item": "https://cratedigger.mrbarkan.com/blog/swinsian-vs-cratedigger-vs-foobar2000.html" }
    ]
  }
  </script>
  <script type="application/ld+json">
  {
    "@context": "https://schema.org",
    "@type": "FAQPage",
    "mainEntity": [
      {
        "@type": "Question",
        "name": "Is there a free alternative to Swinsian on Mac?",
        "acceptedAnswer": { "@type": "Answer", "text": "Yes — foobar2000 and CrateDigger are both free. CrateDigger is also MIT-licensed and open source." }
      },
      {
        "@type": "Question",
        "name": "Does Swinsian convert or transcode audio files?",
        "acceptedAnswer": { "@type": "Answer", "text": "No — Swinsian is a playback and library-management tool; it does not include batch format conversion." }
      },
      {
        "@type": "Question",
        "name": "Can foobar2000 run natively on macOS?",
        "acceptedAnswer": { "@type": "Answer", "text": "Yes, foobar2000 ships an official native macOS build alongside its Windows, Android, and iOS versions." }
      }
    ]
  }
  </script>

  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700;800&family=JetBrains+Mono:wght@400;500;600;700&display=swap" rel="stylesheet">
  <link rel="stylesheet" href="../index.css">
</head>
<body data-theme="dark">

  <div class="backdrop"></div>

  <header class="navbar">
    <div class="nav-container">
      <div class="logo">
        <span class="logo-led"></span>
        <span class="logo-text">CrateDigger</span>
        <span class="logo-sub">CD-01</span>
      </div>
      <nav class="nav-links">
        <a href="../index.html#features">Features</a>
        <a href="../index.html#demo">Interactive UI</a>
        <a href="../index.html#comparison">Compare</a>
        <a href="../index.html#specs">Specs</a>
        <a href="index.html">Blog</a>
        <a href="../index.html#signup" class="btn btn-secondary">Get Beta</a>
      </nav>
    </div>
  </header>

  <section class="article-section">
    <div class="article-container">
      <div class="breadcrumb">
        <a href="../index.html">Home</a> / <a href="index.html">Blog</a> / Swinsian vs. CrateDigger vs. Foobar2000
      </div>

      <div class="article-header">
        <span class="article-eyebrow">Comparison</span>
        <h1 class="article-title">Swinsian vs. CrateDigger vs. Foobar2000: Native macOS Music Library Managers in 2026</h1>
        <div class="article-meta">CrateDigger Team · July 5, 2026 · 7 min read</div>
      </div>

      <div class="article-body">
        <!-- Intro paragraph -->
        <!-- "The three contenders" section, h2 + p -->
        <!-- "Batch conversion & format handling" section, h2 + p -->
        <!-- "Library organization" section, h2 + p -->
        <!-- "Interface & feel" section, h2 + p -->
        <!-- "Price & platform" section, h2 + p -->
        <!-- "Which should you pick" section, h2 + p -->
      </div>

      <div class="article-faq">
        <h2>Frequently Asked Questions</h2>
        <div class="faq-item">
          <h3>Is there a free alternative to Swinsian on Mac?</h3>
          <p>Yes — foobar2000 and CrateDigger are both free. CrateDigger is also MIT-licensed and open source.</p>
        </div>
        <div class="faq-item">
          <h3>Does Swinsian convert or transcode audio files?</h3>
          <p>No — Swinsian is a playback and library-management tool; it does not include batch format conversion.</p>
        </div>
        <div class="faq-item">
          <h3>Can foobar2000 run natively on macOS?</h3>
          <p>Yes, foobar2000 ships an official native macOS build alongside its Windows, Android, and iOS versions.</p>
        </div>
      </div>

      <div class="article-cta">
        <p>CrateDigger is free, open source, and in closed beta right now.</p>
        <a href="../index.html#signup" class="btn btn-primary">Reserve Your Spot</a>
      </div>
    </div>
  </section>

  <footer class="footer">
    <div class="container footer-container">
      <p class="copyright">&copy; 2026 CrateDigger. All rights reserved. macOS, SwiftUI, and AppKit are trademarks of Apple Inc.</p>
      <div class="footer-meta">
        <a href="index.html">Blog</a>
        <span class="footer-led"></span>
      </div>
    </div>
  </footer>

</body>
</html>
```

- [ ] **Step 3: Verify the file parses and JSON-LD is valid**

```bash
python3 -c "
import html.parser
html.parser.HTMLParser().feed(open('website/blog/swinsian-vs-cratedigger-vs-foobar2000.html').read())
print('OK: post 1 parses')
"
python3 -c "
import re, json
text = open('website/blog/swinsian-vs-cratedigger-vs-foobar2000.html').read()
blocks = re.findall(r'<script type=\"application/ld\+json\">(.*?)</script>', text, re.S)
assert len(blocks) == 3, f'expected 3 JSON-LD blocks, got {len(blocks)}'
for b in blocks:
    json.loads(b)
print('OK:', len(blocks), 'JSON-LD blocks parse')
"
```

- [ ] **Step 4: Commit**

```bash
git add website/index.css website/blog/swinsian-vs-cratedigger-vs-foobar2000.html
git commit -m "feat(website): add blog styles and first launch article (Swinsian/foobar2000 comparison)"
```

---

### Task 7: Post 2 — "How to Batch-Convert and Organize a Messy Music Library on macOS"

**Files:**
- Create: `website/blog/organize-batch-convert-music-library-macos.html`

**Interfaces:**
- Consumes: `.article-section`, `.article-container`, `.breadcrumb`, `.article-header`, `.article-body`, `.article-faq`, `.faq-item`, `.article-cta` CSS from Task 6 (already written — no new CSS in this task).

Content brief (~1200-1400 words, `datePublished` 2026-07-05):

1. Intro — the messy-library problem: mixed formats from downloads/rips/burns, inconsistent folder naming, streaming services that don't help with local files.
2. **Step 1: Scan and stage before you touch anything** — import into a staging area (Prep Crate model) and review before committing.
3. **Step 2: Decide your target format** — FLAC/ALAC for lossless archival, AAC/MP3 for space-constrained/phone/car use; keep-source-untouched as a safe default when unsure.
4. **Step 3: Pick a folder structure** — flat vs. source-relative (mirrors the existing tree) vs. metadata-template (Album Artist/Year/Album/Compilation tokens); which fits an inherited, messy library best.
5. **Step 4: Avoid overwriting files** — why silent overwrites are the #1 risk of manual batch renames/scripts; automatic collision-safe suffixing (` (2)`, ` (3)`) as the fix.
6. **Step 5: Preflight before you commit** — check disk space and destination write permissions before a multi-hour job.
7. **Step 6: Batch convert** — multi-threaded queuing (all-but-one core), preserving artwork and tags during conversion.
8. Closing — CTA to try CrateDigger's free batch converter.

FAQ (2 Q&A):
- "What format should I convert FLAC to for my phone?" → AAC or MP3 at a moderate bitrate (256kbps+) for the best size/quality trade-off; keep the FLAC originals if you have the space.
- "Will batch converting overwrite my original files?" → Not if the tool guarantees collision-safe output naming — conversions should always write to a distinct destination, never silently replace a source file.

- [ ] **Step 1: Write `website/blog/organize-batch-convert-music-library-macos.html`**

Use the exact same page skeleton as Task 6 Step 2 (nav, footer, `<link rel="stylesheet" href="../index.css">`, breadcrumb, article-cta, RSS `<link>`), with these page-specific values:

- `<title>`: `How to Batch-Convert and Organize a Messy Music Library on macOS`
- meta description: `A step-by-step guide to cleaning up a messy offline music library on macOS — batch-converting formats, planning folder structure, and avoiding duplicate or overwritten files.`
- canonical / og:url / twitter: `https://cratedigger.mrbarkan.com/blog/organize-batch-convert-music-library-macos.html`
- `article-eyebrow`: `Guide`
- `article-meta`: `CrateDigger Team · July 5, 2026 · 7 min read`
- breadcrumb 3rd item: `How to Organize a Messy Music Library`
- JSON-LD: `Article` (headline/mainEntityOfPage matching this file) + `BreadcrumbList` (3rd item name "How to Batch-Convert and Organize a Messy Music Library on macOS", item this file's URL) + `FAQPage` with the 2 Q&A above — same structure as Task 6, 3 total blocks.
- `article-body`: the 8 sections from the content brief, each as an `<h2>` + `<p>` (or `<h2>` + `<ol>` for the step-numbered sections).
- `article-faq`: the 2 Q&A above.

- [ ] **Step 2: Verify the file parses and JSON-LD is valid**

```bash
python3 -c "
import html.parser
html.parser.HTMLParser().feed(open('website/blog/organize-batch-convert-music-library-macos.html').read())
print('OK: post 2 parses')
"
python3 -c "
import re, json
text = open('website/blog/organize-batch-convert-music-library-macos.html').read()
blocks = re.findall(r'<script type=\"application/ld\+json\">(.*?)</script>', text, re.S)
assert len(blocks) == 3, f'expected 3 JSON-LD blocks, got {len(blocks)}'
for b in blocks:
    json.loads(b)
print('OK:', len(blocks), 'JSON-LD blocks parse')
"
```

- [ ] **Step 3: Commit**

```bash
git add website/blog/organize-batch-convert-music-library-macos.html
git commit -m "feat(website): add second launch article (batch-convert & organize how-to)"
```

---

### Task 8: Post 3 — "Introducing CrateDigger 0.9"

**Files:**
- Create: `website/blog/introducing-cratedigger-0-9.html`

**Interfaces:** consumes the same Task 6 CSS classes; no `.article-faq` needed (announcement-style post).

Content brief (~800-1000 words, `datePublished` 2026-07-05):

1. Intro — why CrateDigger exists: streaming hides the music you already own; own your files, own your library.
2. **What's in 0.9** — bullet rundown: Carbon/Linen hardware UI, batch FFmpeg conversion + collision-safe planner, Prep Crate staging, CD ripping + Subsonic/Navidrome sync, Radio (YouTube streaming), Record Divider, artwork inspector, Last.fm scrobbling, external device transfer.
3. **What's next** — brief, honest, forward-looking: continued beta hardening based on real-world libraries, more folder-template flexibility. No specific dates or unshipped promises.
4. **Try the beta** — CTA to the signup form.

- [ ] **Step 1: Write `website/blog/introducing-cratedigger-0-9.html`**

Same skeleton as Task 6/7, but **omit** the `.article-faq` block and its `FAQPage` JSON-LD entirely (only 2 JSON-LD blocks total: `Article` + `BreadcrumbList`), with:

- `<title>`: `Introducing CrateDigger 0.9: A Hardware-Inspired Way to Manage Your Offline Music`
- meta description: `CrateDigger 0.9 is now in closed beta — a native macOS music manager with a skeuomorphic hardware interface, batch FFmpeg conversion, YouTube radio streaming, and more.`
- canonical / og:url / twitter: `https://cratedigger.mrbarkan.com/blog/introducing-cratedigger-0-9.html`
- `article-eyebrow`: `Release Notes`
- `article-meta`: `CrateDigger Team · July 5, 2026 · 5 min read`
- breadcrumb 3rd item: `Introducing CrateDigger 0.9`
- `article-body`: the 4 sections from the content brief above.

- [ ] **Step 2: Verify the file parses and JSON-LD is valid**

```bash
python3 -c "
import html.parser
html.parser.HTMLParser().feed(open('website/blog/introducing-cratedigger-0-9.html').read())
print('OK: post 3 parses')
"
python3 -c "
import re, json
text = open('website/blog/introducing-cratedigger-0-9.html').read()
blocks = re.findall(r'<script type=\"application/ld\+json\">(.*?)</script>', text, re.S)
assert len(blocks) == 2, f'expected 2 JSON-LD blocks, got {len(blocks)}'
for b in blocks:
    json.loads(b)
print('OK:', len(blocks), 'JSON-LD blocks parse')
"
```

- [ ] **Step 3: Commit**

```bash
git add website/blog/introducing-cratedigger-0-9.html
git commit -m "feat(website): add third launch article (Introducing CrateDigger 0.9)"
```

---

### Task 9: Blog index page + nav/footer "Blog" links on the homepage

**Files:**
- Create: `website/blog/index.html`
- Modify: `website/index.html` (nav + footer)

**Interfaces:**
- Consumes: Task 6's `.blog-hero`, `.blog-list-section`, `.post-grid`, `.post-card*` CSS, and the 3 post files from Tasks 6-8.

- [ ] **Step 1: Write `website/blog/index.html`**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Blog — CrateDigger</title>
  <meta name="description" content="Guides, comparisons, and release notes from CrateDigger — the native macOS music library manager.">
  <link rel="canonical" href="https://cratedigger.mrbarkan.com/blog/index.html">

  <meta property="og:type" content="website">
  <meta property="og:title" content="Blog — CrateDigger">
  <meta property="og:description" content="Guides, comparisons, and release notes from CrateDigger — the native macOS music library manager.">
  <meta property="og:url" content="https://cratedigger.mrbarkan.com/blog/index.html">
  <meta property="og:image" content="https://cratedigger.mrbarkan.com/assets/app_icon.png">
  <meta property="og:site_name" content="CrateDigger">

  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:title" content="Blog — CrateDigger">
  <meta name="twitter:description" content="Guides, comparisons, and release notes from CrateDigger.">
  <meta name="twitter:image" content="https://cratedigger.mrbarkan.com/assets/app_icon.png">

  <link rel="alternate" type="application/rss+xml" title="CrateDigger Blog" href="feed.xml">

  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700;800&family=JetBrains+Mono:wght@400;500;600;700&display=swap" rel="stylesheet">
  <link rel="stylesheet" href="../index.css">
</head>
<body data-theme="dark">

  <div class="backdrop"></div>

  <header class="navbar">
    <div class="nav-container">
      <div class="logo">
        <span class="logo-led"></span>
        <span class="logo-text">CrateDigger</span>
        <span class="logo-sub">CD-01</span>
      </div>
      <nav class="nav-links">
        <a href="../index.html#features">Features</a>
        <a href="../index.html#demo">Interactive UI</a>
        <a href="../index.html#comparison">Compare</a>
        <a href="../index.html#specs">Specs</a>
        <a href="index.html">Blog</a>
        <a href="../index.html#signup" class="btn btn-secondary">Get Beta</a>
      </nav>
    </div>
  </header>

  <section class="blog-hero">
    <div class="container">
      <div class="badge">CRATEDIGGER BLOG</div>
      <h1 class="hero-title">Notes from the crate.</h1>
      <p class="hero-lead">Guides, comparisons, and release notes for people who still own their music.</p>
    </div>
  </section>

  <section class="blog-list-section">
    <div class="container">
      <div class="post-grid">
        <a class="post-card" href="introducing-cratedigger-0-9.html">
          <span class="post-card-date">JUL 2026</span>
          <h3 class="post-card-title">Introducing CrateDigger 0.9</h3>
          <p class="post-card-excerpt">A hardware-inspired way to manage your offline music is now in closed beta.</p>
          <span class="post-card-read">5 min read →</span>
        </a>
        <a class="post-card" href="swinsian-vs-cratedigger-vs-foobar2000.html">
          <span class="post-card-date">JUL 2026</span>
          <h3 class="post-card-title">Swinsian vs. CrateDigger vs. Foobar2000</h3>
          <p class="post-card-excerpt">Comparing native macOS music library managers on conversion, organization, and price.</p>
          <span class="post-card-read">7 min read →</span>
        </a>
        <a class="post-card" href="organize-batch-convert-music-library-macos.html">
          <span class="post-card-date">JUL 2026</span>
          <h3 class="post-card-title">How to Batch-Convert and Organize a Messy Music Library on macOS</h3>
          <p class="post-card-excerpt">A step-by-step cleanup guide: formats, folder structure, and avoiding overwritten files.</p>
          <span class="post-card-read">7 min read →</span>
        </a>
      </div>
    </div>
  </section>

  <footer class="footer">
    <div class="container footer-container">
      <p class="copyright">&copy; 2026 CrateDigger. All rights reserved. macOS, SwiftUI, and AppKit are trademarks of Apple Inc.</p>
      <div class="footer-meta">
        <a href="index.html">Blog</a>
        <span class="footer-led"></span>
      </div>
    </div>
  </footer>

</body>
</html>
```

- [ ] **Step 2: Add "Blog" to the homepage nav and footer**

In `website/index.html`, replace:

```html
      <nav class="nav-links">
        <a href="#features">Features</a>
        <a href="#demo">Interactive UI</a>
        <a href="#comparison">Compare</a>
        <a href="#specs">Specs</a>
        <a href="#signup" class="btn btn-secondary">Get Beta</a>
      </nav>
```

with:

```html
      <nav class="nav-links">
        <a href="#features">Features</a>
        <a href="#demo">Interactive UI</a>
        <a href="#comparison">Compare</a>
        <a href="#specs">Specs</a>
        <a href="blog/index.html">Blog</a>
        <a href="#signup" class="btn btn-secondary">Get Beta</a>
      </nav>
```

and replace:

```html
      <div class="footer-meta">
        <span>Current Build: v0.9.0 (Beta 1)</span>
        <span class="footer-led"></span>
      </div>
```

with:

```html
      <div class="footer-meta">
        <a href="blog/index.html">Blog</a>
        <span>Current Build: v0.9.0 (Beta 1)</span>
        <span class="footer-led"></span>
      </div>
```

- [ ] **Step 3: Verify the blog index parses and all 3 post links resolve**

```bash
python3 -c "
import html.parser
html.parser.HTMLParser().feed(open('website/blog/index.html').read())
print('OK: blog index parses')
"
python3 -c "
import re, os
text = open('website/blog/index.html').read()
for url in re.findall(r'href=\"([a-z0-9-]+\.html)\"', text):
    assert os.path.exists(os.path.join('website/blog', url)), f'missing {url}'
print('OK: all post links resolve')
"
```

- [ ] **Step 4: Commit**

```bash
git add website/blog/index.html website/index.html
git commit -m "feat(website): add blog index page and Blog nav/footer links"
```

---

### Task 10: RSS feed

**Files:**
- Create: `website/blog/feed.xml`

**Interfaces:** none — references the 3 post URLs from Tasks 6-8.

- [ ] **Step 1: Write `website/blog/feed.xml`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>CrateDigger Blog</title>
    <link>https://cratedigger.mrbarkan.com/blog/index.html</link>
    <description>Guides, comparisons, and release notes from CrateDigger.</description>
    <language>en-us</language>
    <item>
      <title>Introducing CrateDigger 0.9</title>
      <link>https://cratedigger.mrbarkan.com/blog/introducing-cratedigger-0-9.html</link>
      <guid>https://cratedigger.mrbarkan.com/blog/introducing-cratedigger-0-9.html</guid>
      <pubDate>Sun, 05 Jul 2026 00:00:00 -0000</pubDate>
      <description>A hardware-inspired way to manage your offline music is now in closed beta.</description>
    </item>
    <item>
      <title>Swinsian vs. CrateDigger vs. Foobar2000: Native macOS Music Library Managers in 2026</title>
      <link>https://cratedigger.mrbarkan.com/blog/swinsian-vs-cratedigger-vs-foobar2000.html</link>
      <guid>https://cratedigger.mrbarkan.com/blog/swinsian-vs-cratedigger-vs-foobar2000.html</guid>
      <pubDate>Sun, 05 Jul 2026 00:00:00 -0000</pubDate>
      <description>Comparing native macOS music library managers on conversion, organization, and price.</description>
    </item>
    <item>
      <title>How to Batch-Convert and Organize a Messy Music Library on macOS</title>
      <link>https://cratedigger.mrbarkan.com/blog/organize-batch-convert-music-library-macos.html</link>
      <guid>https://cratedigger.mrbarkan.com/blog/organize-batch-convert-music-library-macos.html</guid>
      <pubDate>Sun, 05 Jul 2026 00:00:00 -0000</pubDate>
      <description>A step-by-step cleanup guide: formats, folder structure, and avoiding overwritten files.</description>
    </item>
  </channel>
</rss>
```

- [ ] **Step 2: Verify it's valid XML**

```bash
python3 -c "
import xml.dom.minidom as m
m.parse('website/blog/feed.xml')
print('OK: feed.xml is valid XML')
"
```

- [ ] **Step 3: Commit**

```bash
git add website/blog/feed.xml
git commit -m "feat(website): add blog RSS feed"
```

---

### Task 11: sitemap.xml, robots.txt, llms.txt

**Files:**
- Create: `website/sitemap.xml`
- Create: `website/robots.txt`
- Create: `website/llms.txt`

**Interfaces:** none — references all 5 pages from prior tasks.

- [ ] **Step 1: Write `website/sitemap.xml`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url>
    <loc>https://cratedigger.mrbarkan.com/</loc>
    <changefreq>weekly</changefreq>
    <priority>1.0</priority>
  </url>
  <url>
    <loc>https://cratedigger.mrbarkan.com/blog/index.html</loc>
    <changefreq>weekly</changefreq>
    <priority>0.8</priority>
  </url>
  <url>
    <loc>https://cratedigger.mrbarkan.com/blog/introducing-cratedigger-0-9.html</loc>
    <changefreq>monthly</changefreq>
    <priority>0.6</priority>
  </url>
  <url>
    <loc>https://cratedigger.mrbarkan.com/blog/swinsian-vs-cratedigger-vs-foobar2000.html</loc>
    <changefreq>monthly</changefreq>
    <priority>0.6</priority>
  </url>
  <url>
    <loc>https://cratedigger.mrbarkan.com/blog/organize-batch-convert-music-library-macos.html</loc>
    <changefreq>monthly</changefreq>
    <priority>0.6</priority>
  </url>
</urlset>
```

- [ ] **Step 2: Write `website/robots.txt`**

```
User-agent: *
Allow: /

Sitemap: https://cratedigger.mrbarkan.com/sitemap.xml
```

- [ ] **Step 3: Write `website/llms.txt`**

```
# CrateDigger

> CrateDigger is a free, open-source (MIT) native macOS music utility for managing offline music libraries: scanning, tagging, batch FFmpeg conversion, artwork, and a skeuomorphic hardware-inspired interface.

## Pages

- [Home](https://cratedigger.mrbarkan.com/): Overview, feature spotlights, beta signup.
- [Blog](https://cratedigger.mrbarkan.com/blog/index.html): Guides, comparisons, and release notes.
- [Introducing CrateDigger 0.9](https://cratedigger.mrbarkan.com/blog/introducing-cratedigger-0-9.html): Launch announcement and feature rundown.
- [Swinsian vs. CrateDigger vs. Foobar2000](https://cratedigger.mrbarkan.com/blog/swinsian-vs-cratedigger-vs-foobar2000.html): Comparison of native macOS music library managers.
- [How to Batch-Convert and Organize a Messy Music Library on macOS](https://cratedigger.mrbarkan.com/blog/organize-batch-convert-music-library-macos.html): Step-by-step library cleanup guide.
```

- [ ] **Step 4: Verify sitemap is valid XML and references 5 URLs**

```bash
python3 -c "
import xml.dom.minidom as m
doc = m.parse('website/sitemap.xml')
urls = doc.getElementsByTagName('loc')
assert len(urls) == 5, f'expected 5 <loc> entries, got {len(urls)}'
print('OK: sitemap.xml valid,', len(urls), 'URLs')
"
```

- [ ] **Step 5: Commit**

```bash
git add website/sitemap.xml website/robots.txt website/llms.txt
git commit -m "feat(website): add sitemap, robots.txt, and llms.txt"
```

---

### Task 12: Full-site validation pass

**Files:** none created/modified — verification only, against every file from Tasks 2-11.

- [ ] **Step 1: HTML parses cleanly on every page**

```bash
python3 -c "
import html.parser
files = [
    'website/index.html',
    'website/blog/index.html',
    'website/blog/introducing-cratedigger-0-9.html',
    'website/blog/swinsian-vs-cratedigger-vs-foobar2000.html',
    'website/blog/organize-batch-convert-music-library-macos.html',
]
for f in files:
    html.parser.HTMLParser().feed(open(f).read())
    print('OK:', f)
"
```

- [ ] **Step 2: Every internal link/image reference resolves**

```bash
python3 -c "
import re, os
files = [
    'website/index.html',
    'website/blog/index.html',
    'website/blog/introducing-cratedigger-0-9.html',
    'website/blog/swinsian-vs-cratedigger-vs-foobar2000.html',
    'website/blog/organize-batch-convert-music-library-macos.html',
]
ok = True
for f in files:
    base = os.path.dirname(f)
    text = open(f).read()
    for url in re.findall(r'(?:href|src)=\"([^\"]+)\"', text):
        if url.startswith(('http://', 'https://', '#', 'mailto:')):
            continue
        path = url.split('#')[0]
        if not path:
            continue
        resolved = os.path.normpath(os.path.join(base, path))
        if not os.path.exists(resolved):
            print('BROKEN LINK', f, '->', url)
            ok = False
print('OK: all internal links resolve' if ok else 'FAIL: broken links found')
assert ok
"
```

- [ ] **Step 3: Required meta tags present on every page**

```bash
for f in website/index.html website/blog/index.html website/blog/*.html; do
  grep -q '<title>' "$f" && grep -q 'name="description"' "$f" && grep -q 'rel="canonical"' "$f" && grep -q 'property="og:title"' "$f" && echo "OK: $f" || echo "MISSING META: $f"
done
```

- [ ] **Step 4: sitemap.xml and feed.xml are valid XML**

```bash
python3 -c "
import xml.dom.minidom as m
for f in ['website/sitemap.xml', 'website/blog/feed.xml']:
    m.parse(f)
    print('OK:', f)
"
```

Expected across all 4 steps: every file prints `OK:`, no `FAIL`/`MISSING`/`BROKEN` lines, no exceptions.

- [ ] **Step 5: Final commit if anything was fixed during validation**

```bash
git status
```

If Step 1-4 required fixes, `git add` the touched files and commit with `fix(website): resolve validation issues found in full-site pass`. If nothing needed fixing, no commit is needed for this task.
