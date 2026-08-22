# Spec: GitHub CodeQL & Security Scanning for CrateDigger

**Status:** Files implemented (§1–3). Repo settings (§4) still to be ticked by the owner.
**Branch:** `claude/github-ql-sec-compliance-06jjjc`
**Repo:** `mrbarkan/cratedigger` (public)

## Why

As of 2026-08-22 the repo has **no code scanning of any kind**. The only
workflows are the Pages website deploy (`deploy-pages.yml`) and GitHub's
automatic `pages-build-deployment` — all runs green, but neither looks at the
Swift code. There is no CodeQL workflow, and "default setup" code scanning is
not enabled in the repo settings (no CodeQL runs appear in the Actions
history). So the question "do we pass CodeQL?" currently has no answer: the
project is unscanned, not passing.

A quick local audit suggests enabling scanning is low-risk:

- No hardcoded API keys / tokens / passwords in `Sources/` (checked common
  patterns incl. 32-hex Last.fm-style keys; the Last.fm session key lives in
  `PreferencesStore`, not source).
- `Package.swift` declares **zero third-party dependencies** (no
  `Package.resolved`), so dependency scanning only has the three `actions/*`
  steps in the Pages workflow to watch.
- `deploy-pages.yml` already uses least-privilege `permissions:`.

## Constraints that shape the design

1. **CodeQL for Swift requires a real build on macOS.** The Swift extractor
   observes an actual compile; GitHub's zero-config "default setup" cannot do
   a macOS Swift build. We need a custom workflow on a `macos-*` runner.
   The repo is public, so macOS runner minutes are free (they are 10× the
   metered rate on private repos — worth knowing if the repo ever goes
   private).
2. **Project facts:** SwiftPM, `swift-tools-version: 5.9`, platform
   `.macOS(.v13)`, two targets (`CrateDiggerCore` library +
   `CrateDiggerApp` AppKit executable). A plain `swift build` compiles both
   and is all CodeQL needs — no tests, no packaging, no ffmpeg/yt-dlp.
3. **Workflow-file analysis is cheap.** CodeQL's `actions` language (scans
   the YAML workflows themselves for injection/permissions issues) runs fine
   on `ubuntu-latest` — no macOS minutes needed.

## Deliverables

### 1. `.github/workflows/codeql.yml` — CodeQL analysis

Two jobs, one per language, so the cheap one never waits on the macOS queue:

| Job | Runner | Language | Build |
|-----|--------|----------|-------|
| `analyze-swift` | `macos-15` | `swift` | `build-mode: manual` + `swift build` |
| `analyze-actions` | `ubuntu-latest` | `actions` | none (interpreted) |

**Triggers:**

- `push` to `main` and `pull_request` targeting `main`, both with a `paths`
  filter for the Swift job's inputs: `Sources/**`, `Tests/**`,
  `Package.swift` (the actions job filters on `.github/workflows/**`).
  Website/docs/branding churn must not burn macOS minutes.
- `schedule`: weekly (e.g. `cron: "26 8 * * 1"`) with **no** path filter, so
  new CodeQL queries still sweep the whole codebase even in quiet weeks.
  Pick an arbitrary minute, not `0 0`, to avoid the top-of-hour stampede.
- `workflow_dispatch` for manual runs.

**Skeleton (the implementer should start from this, not from GitHub's
generic template):**

```yaml
name: CodeQL

on:
  push:
    branches: [main]
    paths: ["Sources/**", "Tests/**", "Package.swift", ".github/workflows/**"]
  pull_request:
    branches: [main]
    paths: ["Sources/**", "Tests/**", "Package.swift", ".github/workflows/**"]
  schedule:
    - cron: "26 8 * * 1"
  workflow_dispatch:

permissions:
  contents: read

jobs:
  analyze-swift:
    runs-on: macos-15
    timeout-minutes: 60
    permissions:
      contents: read
      security-events: write
    steps:
      - uses: actions/checkout@v4
      - uses: github/codeql-action/init@v3
        with:
          languages: swift
          build-mode: manual
      - name: Build
        run: swift build
      - uses: github/codeql-action/analyze@v3
        with:
          category: "/language:swift"

  analyze-actions:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    permissions:
      contents: read
      security-events: write
      actions: read
    steps:
      - uses: actions/checkout@v4
      - uses: github/codeql-action/init@v3
        with:
          languages: actions
      - uses: github/codeql-action/analyze@v3
        with:
          category: "/language:actions"
```

**Notes for the implementer:**

- `macos-15` ships an Xcode new enough for tools-version 5.9 / macOS 13
  target; no `xcode-select` pinning needed unless the build breaks — if it
  does, pin via `sudo xcode-select -s /Applications/Xcode_<ver>.app` rather
  than downgrading the runner image.
- Keep `build-mode: manual` + plain `swift build` (debug). Release config
  buys nothing for extraction and roughly doubles build time.
- The two `category` values keep the SARIF uploads distinct; don't drop
  them or the second upload clobbers the first.
- Default query suite is fine to start. Only consider
  `queries: security-extended` after the default suite runs clean —
  extended is noticeably noisier.
- Expect the Swift job to take 10–25 min (clean build, no cache). A
  `.build` cache via `actions/cache` is a *follow-up*, not part of v1:
  CodeQL needs to observe compilation, and a fully cached build can
  under-extract. If added later, cache only dependencies — this repo has
  none, so skip caching entirely.

### 2. `.github/dependabot.yml` — keep the actions pinned versions fresh

```yaml
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "monthly"
```

No `swift` ecosystem entry: there are no package dependencies to update, and
an empty ecosystem config just generates a warning.

### 3. `SECURITY.md` — reporting policy (small, root of repo)

The repo has none. One short file: supported version = latest release,
report via GitHub's private vulnerability reporting ("Report a
vulnerability" under the Security tab), please don't open public issues for
exploitable bugs. Keep it to ~15 lines; this is a solo-maintained app, not
an enterprise policy.

### 4. Repo settings — manual, cannot be done from a workflow

Owner checklist at `github.com/mrbarkan/cratedigger/settings/security_analysis`:

All ticked on 2026-08-22 (secret scanning was **off**, not default-on as
originally assumed):

- [x] **Secret scanning** (as "Secret Protection") + **push protection**.
- [x] **Private vulnerability reporting** (SECURITY.md points at it).
- [x] **Dependabot alerts** + **security updates**. Enabling alerts required
      turning on the **dependency graph** first.
- [x] **Code scanning**: left on advanced setup (our workflow); "default
      setup" untouched — it would block SARIF uploads from Actions.

Deliberately left off: Dependabot **version updates** (GitHub switches it on
by itself once `dependabot.yml` lands on `main`), grouped security updates,
malware alerts, and secret-scanning validity checks / non-provider patterns.

## Explicitly out of scope

- **Building/testing the app in CI** (a `swift build` + `scripts/test.sh` CI
  workflow). Worth doing, but it's a separate task — this spec is scanning
  only. Note `scripts/test.sh` needs a full Xcode; the CodeQL job
  deliberately avoids the test suite.
- Branch protection / required checks. Decide after CodeQL has a week of
  green runs.
- `security-extended`/`security-and-quality` query suites (see note above).
- Signing, notarization, release automation — already documented elsewhere.

## Acceptance criteria

1. `codeql.yml` on `main`; both jobs green on a `workflow_dispatch` run and
   on the first real push/PR touching `Sources/`.
2. The Security tab shows CodeQL results for **swift** and **actions**, and
   any findings are triaged (fixed or dismissed with a reason) so the alert
   count is 0 open.
3. A docs-only or website-only push triggers **no** CodeQL run.
4. Dependabot config live; any actions-bump PRs it opens get the Pages
   deploy still passing before merge.
5. `SECURITY.md` present; private vulnerability reporting enabled.
6. Settings checklist in §4 fully ticked.

## Verification steps (after implementing)

```text
1. Push branch, open PR → confirm both CodeQL jobs run and pass on the PR.
2. Merge → confirm push-triggered run on main is green.
3. Actions tab → run "CodeQL" via workflow_dispatch → green.
4. Security ▸ Code scanning → both categories present, 0 open alerts
   (or each open alert has an owner/decision).
5. Push a website/-only commit → Pages deploy runs, CodeQL does not.
```
