# Website Expansion — Design Note

Date: 2026-07-05
Status: Approved

## Goal

`website/` (static marketing landing page, no build step) reads flatter than
its stated inspirations (Swinsian, CleanShot, Linear): a small icon-driven
feature grid, no deep feature storytelling, and no blog. Add Linear/CleanShot-
style feature spotlights to the homepage and stand up a blog, with SEO/GEO
plumbing throughout. Site stays a hand-authored static site — no bundler, no
new dependency — since the only content producer going forward is Claude
generating full HTML per post/page for the user to review and publish.

## Homepage: feature spotlights

Four large alternating sections (screenshot one side, copy + bullets the
other, flipping side each section), inserted between the existing
"Interactive UI Tour" and the feature grid:

1. **Batch conversion + path planner** — FFmpeg engine, collision-safe output
   naming, folder modes (flat/source-relative/metadata-template). Folds in
   the "Review Album Folders" preflight sheet as a bullet.
2. **Crates & Prep Crate staging** — the two-tier organization model (staging
   area vs. saved crates).
3. **Radio (YouTube streaming)** — not represented on the site today.
4. **Big Artwork display** — the artwork inspector/viewer — also not
   represented today.

Each section: eyebrow label, heading, 2-3 sentence description, 3-4 bullets,
framed screenshot matching the hero's existing glow/chassis treatment. New
rules added to `index.css` (no new stylesheet); reuse existing color tokens
(`--cyan`, `--coral`, `--card-bg`, etc.) so it stays visually consistent with
Carbon.

## Feature grid: trim + fill

Remove the two cards that become spotlight #1 ("Batch FFmpeg Engine",
"Collision-Safe Path Planner"). Add three real, currently-unmentioned shipped
features to backfill the grid to 6 (2 clean rows of 3):

- **Record Divider** — vinyl-side rip splitting into per-track exports.
- **External Device Transfer** — ⌘⇧T to iPods/USB drives/phones.
- **Sandbox & Preflight Safety** — security-scoped bookmarks, destination
  writability + disk-space checks before conversion.

Unchanged: CD Ripper & Subsonic Client, Tactile Hardware Feel, Last.fm &
Metadata Probes.

## Comparison table: add Swinsian

Add a column for Swinsian — the closest direct competitor and the site's own
stated reference point, currently missing from the table. Verify Swinsian's
actual feature set (via its site) before writing claims, so the row is fair
rather than a strawman.

## Blog

Flat static files, matching the site's existing pattern (no per-post
folders, no templating engine):

- `website/blog/index.html` — card listing (title, date, excerpt, read time),
  same nav/footer/theme chrome as the homepage.
- `website/blog/<slug>.html` × 3 — article template: breadcrumb, title/date/
  read-time, prose body with H2 subheadings, related-posts + beta-signup CTA
  footer.
- Nav bar and footer both get a "Blog" link.

**Launch articles** (written now, real content):

1. *Swinsian vs. CrateDigger vs. Foobar2000: Native macOS Music Library
   Managers in 2026* — comparison/buyer's-guide, mirrors the homepage table.
2. *How to Batch-Convert and Organize a Messy Music Library on macOS* —
   evergreen how-to, showcases the conversion engine.
3. *Introducing CrateDigger 0.9* — launch/announcement post; dated, gives a
   freshness signal and an internal-linking anchor.

## SEO/GEO plumbing (site-wide)

- Per page: unique `<title>`/description, canonical `<link>`, Open Graph +
  Twitter Card tags (the homepage currently has none of this).
- JSON-LD: `Organization` + `SoftwareApplication` on the homepage; `Article` +
  `BreadcrumbList` on posts; `FAQPage` where a post has natural Q&A content.
- `website/sitemap.xml` + `website/robots.txt`.
- `website/blog/feed.xml` — hand-maintained RSS 2.0.
- `website/llms.txt` — plain-text page/section summary for LLM crawlers.
- Canonical domain: `https://cratedigger.mrbarkan.com`.

## Screenshot capture

Four new feature screenshots needed (conversion/Patch Bay, Crates/Prep Crate,
Radio, Artwork viewer) — none of these views are captured anywhere today.
This session has no desktop computer-use tool connected (only browser
automation), so capture will be attempted via `swift build` + launching the
debug binary + `screencapture`/AppleScript System Events from Bash, reading
the resulting PNGs to verify framing. Any view that can't be reliably reached
that way (e.g. requires typing a URL into the Radio field) falls back to
asking the user for a manual screenshot rather than blocking the rest of the
page.

## File manifest

New:
- `website/blog/index.html`
- `website/blog/<3 slugs>.html`
- `website/blog/feed.xml`
- `website/sitemap.xml`, `website/robots.txt`, `website/llms.txt`
- `website/assets/` — 4 new feature screenshots

Changed:
- `website/index.html` — spotlights, trimmed/refilled grid, Swinsian column,
  nav/footer blog link, SEO meta + JSON-LD
- `website/index.css` — spotlight + blog styles

## Out of scope

- Any build tooling / static site generator (revisit only if the blog grows
  well past a handful of posts).
- RSS/sitemap automation (both hand-maintained; fine at this content volume).
- A CMS or comment system.
