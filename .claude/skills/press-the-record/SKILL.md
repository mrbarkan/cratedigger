---
name: press-the-record
description: CrateDigger release macro. Use when the user says "press the record" (also "press record", "cut a release", "ship a release"), optionally with a stage modifier (alpha, beta, rc, ga) and a version. Decides the stage and version itself from the branch and the release history, confirms once with a short list, then verifies the build, bumps the version, updates the changelog (and, for GA, the README and website), commits, pushes, builds the signed + notarized DMG, publishes the GitHub release, and writes the update feed(s) for that stage.
---

# Press the Record — CrateDigger release macro

Run these steps in order. Stop and report if any step fails; never push or
package on a red build.

Invocation: `press the record [alpha|beta|rc|ga] [<version>]`. Usually just
"press the record": **the stage and the version are decided by the rules in
step 0, not by asking.** The user confirms once, from a short list, and then
the rest runs without further questions (it still stops on any failure).

## 0. Decide everything, then confirm once

Never ask the user to pick a stage, a version or a build. Work them out from
the rules below, which are the decisions the user actually made for every
release from 1.0 to 2.3.2, and put the result in one list for a yes/no.

### Gather

```bash
git fetch origin --tags --quiet
git branch --show-current
grep -E 'static let (marketing|build|channel|channelOrdinal) ' Sources/CrateDiggerApp/AppVersion.swift
grep '^BETA_BRANCH=' scripts/update-appcast.sh
# Last GA anywhere, and the last release this branch contains
git tag -l 'v[0-9]*' --sort=-version:refname | grep -vE -- '-(alpha|beta|rc)\.' | head -1
git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD
# Since that release: features and fixes (merges left out, merged commits counted)
git log --no-merges --format=%s <last release>..HEAD | grep -c '^feat'
git log --no-merges --format=%s <last release>..HEAD | grep -c '^fix'
# Fix branches with work the release branch doesn't have
for b in $(git for-each-ref --format='%(refname:short)' refs/heads/fix/ refs/remotes/origin/fix/); do
  n=$(git rev-list --count HEAD..$b); [ "$n" -gt 0 ] && echo "$b $n"
done
```

"Shipped" means a tag `v<version>` (no suffix) exists. A shipped version is
never reused.

### Stage

A modifier the user gave wins, within the limits in the last column. Otherwise:

| Branch | Last release this branch contains | Stage | Limits on a modifier |
|---|---|---|---|
| `main` | anything | `ga`, a stable patch | `alpha`, `beta`, `rc` refused |
| `BETA_BRANCH` | a GA | `beta` 1 | |
| `BETA_BRANCH` | a beta | the next `beta` | `rc` turns it into RC 1 |
| `BETA_BRANCH` | an RC, no `feat` since | `ga`, promoting the line into `main` | `rc` gives the next RC |
| `BETA_BRANCH` | an RC, `feat` commits since | `beta` 1 of the next patch | |
| any other branch (`v2.4`, `next/*`, `feat/*`) | anything | `alpha` | `beta` opens a new beta line here (see below); `ga` refused |
| `v2`, `v2.1`, `v2.2` | | refuse: history only | |

- **RC is never automatic.** Betas stay betas until the user says `rc`. Every
  RC so far went straight to GA, so after an RC the default is GA.
- **New features after an RC restart the line** on the next patch: 2.3.0 RC 1
  took Busy Signals and EQ presets and became 2.3.1 beta 1.
- **`beta` from a branch other than `BETA_BRANCH` opens a new beta line** on
  that branch. List it in the confirmation as "Opens beta line: `<old>` to
  `<branch>`" and do the step 9 flips before building.

### Version

- **Build:** the current build + 1, always.
- **Marketing**, unless the user named one:

| Stage | Version | Precedent |
|---|---|---|
| `ga` on `main` | last GA + patch. Minor (`X.(Y+1).0`) when 10 or more `feat` commits are in the range | 2.0.1 to 2.0.5 and 2.2.1 to 2.2.3 carried 0 to 3 features; 2.1.0 carried 12 |
| `ga` promotion | the beta line's version, unchanged | 2.2.4, 2.3.1 |
| next `beta` or `rc` | unchanged | 2.0.0 beta 2 to 9 |
| `beta` 1 on a branch named `vX.Y` with no `X.Y` GA yet | `X.Y.0` | 2.2.0, 2.3.0 |
| `beta` 1 after a GA on the same line | that GA + patch | 2.2.3, then 2.2.4 beta 1 |
| `beta` 1 after an RC plus new features | the RC's version + patch | 2.3.0 RC 1, then 2.3.1 beta 1 |
| `alpha` on `vX.Y` | `X.Y.0` | |
| `alpha` on `next/X.Y.Z` | `X.Y.Z` | |
| `alpha` on any other branch | last GA + patch | |

- Then, whatever the table gave: **while that version is shipped, add one to
  the patch.** That is how `next/2.3.2` lands on 2.3.3 now that 2.3.2 shipped
  from `main`.
- **Major versions are never automatic.** 2.0 happened because the user named
  it. Go to `X+1.0.0` only when the user says the number.
- **`main` takes the next patch even when a work branch is named for it.** The
  branch moves on (rule above), and the confirmation says so.
- **Ordinal:** +1 within the same channel and version; a new channel or a new
  version restarts it at `"1"` (alpha 3, then beta 1, then RC 1). For an alpha,
  count the existing `v<ver>-alpha.*` tags. GA sets it to `""`.

### What goes where

- **`ga` on `main`:** every `fix/*` branch the gather step found is merged in
  first. That is what 2.3.2 did with the window and footer fixes; a fix branch
  left out is a fix nobody gets. `feat/*` and `next/*` never go in.
- **`beta`, `rc`, `ga` promotion:** `main` is merged into the beta branch first
  (step 5). Fix branches go to `main`, not straight into a beta.
- **`alpha`:** the branch as it is.

### Confirm

Show this list, filled in, then ask one `AskUserQuestion` with two options,
"Press it" and "Change something". Drop lines that don't apply.

```
Press the record: <ver> <stage + ordinal> (build <b>)
- From: <branch>
- Merging in: <branches, or "nothing">
- Not included: <unmerged fix/next/feat branches worth naming, or "nothing waiting">
- Why <ver>: <one line, e.g. "patch: 0 features, 3 fixes since 2.3.1">
- Tag: <tag>, <prerelease | normal release, becomes the Latest download>
- Feeds: <feed on branch>, ...
- Copy: CHANGELOG ## <ver><, README, website footer for GA>
- Pushes: <branches>
- Also: <side effects, e.g. "next/2.3.2's next alpha becomes 2.3.3", "Opens beta line: v2.3 to v2.4">
```

On "Press it", run steps 1 to 10 without asking again. On "Change something",
apply the user's change, show the list again, and ask again.

### The four stages

| | alpha | beta | rc | ga |
|---|---|---|---|---|
| Audience | people you send the link to | stable users who turned on Receive beta updates | same as beta | everyone |
| Branch | any work branch | open beta branch | open beta branch | `main` (patch) or the beta branch merged in (promotion) |
| `AppVersion.channel` | `"ALPHA"` | `"BETA"` | `"RC"` | `""` |
| `channelOrdinal` | alpha number | beta number | RC number | `""` |
| Tag | `v<ver>-alpha.<build>` | `v<ver>-beta.<build>` | `v<ver>-rc.<build>` | `v<ver>` |
| GitHub release | `--prerelease` | `--prerelease` | `--prerelease` | normal (becomes `/releases/latest`) |
| Title | `CrateDigger <ver> alpha <n> (build <b>): <tagline>` | `… beta <n> …` | `… RC <n> …` | `CrateDigger <ver> (build <b>): <tagline>` |
| Feed(s) | `website/appcast-nightly.xml` | `website/appcast-beta.xml` | `website/appcast-beta.xml` | `website/appcast.xml` **and** `website/appcast-beta.xml` |
| Staging | `dist/updates-nightly/` | `dist/updates-beta/` | `dist/updates-beta/` | `dist/updates/` and `dist/updates-beta/` |
| CHANGELOG | add to the one `## <ver>` section | add to it | add to it | finalize it (GA intro) |
| README + website footer | untouched | untouched | untouched | updated |

**Alpha has its own feed, `appcast-nightly.xml`, and that feed must exist in
the app before the first alpha ships.** An `ALPHA` build has to read the nightly
feed, or it can never be offered the next alpha. The routing landed on `v2.4`
for 2.4.0: `UpdateFeed.override` (`Updates/SoftwareUpdater.swift`) returns
`UpdateFeed.nightly` for `"ALPHA"`, and `UpdateFeedTests` pins it. Branches cut
before that (`main` at 2.3.x, `v2.3`, `next/2.3.2` until it takes the change)
still send *every* non-empty channel to the beta feed. So before an alpha,
check that the branch's `UpdateFeed` has `nightly`. If it doesn't, put "Needs
the nightly feed routing from `v2.4` merged in first" under "Also" in the
confirmation, and merge it on "Press it". Never ship an alpha into the beta
feed as a stand-in, because that offers it to every beta tester.
`scripts/update-appcast.sh` accepts `--appcast website/appcast-nightly.xml` from
any branch except `main`, which it refuses, and stages it in
`dist/updates-nightly/`.

### Where the lines stand

- **2.3.2 shipped GA on 2026-10-19 (build 114)** as a stable patch from `main`
  (window minimum size, compact deck centred on fold, footer faders centred).
  2.3.1 (build 113) shipped earlier the same day, promoted from `v2.3`.
- **`BETA_BRANCH` is still `v2.3`,** fast-forwarded to `main`, so a beta pressed
  there today is 2.3.3 beta 1.
- **`v2.4`** holds the Stock iPod spec (parked) and has `next/2.3.2` merged in.
  The profile-decode fix (M0) must land before any 2.4 beta; put it under
  "Also" in the confirmation if it still hasn't.
- **`next/2.3.2`** (the hidden assistant) can no longer be 2.3.2; by the rules
  above its next alpha is 2.3.3.

## 1. Verify green

```bash
swift build > "$S/build.log" 2>&1; echo "build exit=$?"
scripts/test.sh > "$S/test.log" 2>&1; echo "test exit=$?"
grep -E "Test Suite '.*\.xctest' (passed|failed)|Executed [0-9]{3,} tests" "$S/test.log"
grep -E ': error:' "$S/test.log"
```

(`$S` is the scratchpad directory.)

- **Read the real exit code and both bundles' totals.** Never pipe the run
  through `tail`: the pipeline then reports `tail`'s exit status, and the
  totals for `CrateDiggerCoreTests` scroll away, so a run with failures can
  look green. Expect two `.xctest` lines (Core and App); at 2.3.1 they were
  1,594 and 198 tests.
- Any failure: stop. If the test passes when run alone and the failure is
  timing-related, fix the test (a bounded wait on the condition rather than a
  fixed number of yields), commit that separately as `test(...)`, and run the
  whole suite again. Do not release on "it was flaky".

## 2. Bump the version

- `Sources/CrateDiggerApp/AppVersion.swift`: `marketing`, `build`, `channel`,
  `channelOrdinal` per the stage table. `betaExpiry` stays `nil` unless the user
  asks for one, and must be `nil` for GA.
- `Packaging/CrateDiggerApp/Info.plist`: `CFBundleShortVersionString`
  (= marketing) and `CFBundleVersion` (= build). **Never touch `SUFeedURL`**:
  the feed is chosen at runtime by `UpdateFeed.override`.
- Re-run `swift build` to confirm the bump compiles.

## 3. Update the copy

Write for users: one bullet per user-visible change, not one per commit,
grouped into **Added / Changed / Fixed**, drafted from
`git log <previous chore(release) commit>..HEAD`. Pass today's date in rather
than calling `date` from a script. No em or en dashes in anything a user reads.

- **alpha, beta, rc:** one `## <ver> (<build>), <date>` section at the top of
  `CHANGELOG.md` that each release *adds to* rather than replaces, so a tester
  reads everything in that version so far. Update the heading's build and date,
  and rewrite the intro paragraph to name this release (for example "Release
  candidate 1: …. Beta 2 brought …"). Keep the heading starting with
  `## <ver> ` exactly: the appcast script finds the notes by that prefix.
  Leave `README.md` and `website/index.html` alone, because they describe the
  shipping stable release.
- **ga:** finalize the section. Set its heading to the GA build and date, and
  replace the beta/RC intro with one written for stable users, with no "beta 2
  brought" history and no "offered only to people who turned on Receive beta
  updates". **If an earlier version on the same line never shipped GA** (2.3.0
  went straight to 2.3.1), say in the intro that its section below is new in
  this release too, because stable users never saw it. Then update `README.md`
  ("Now at the X release.") and the `website/index.html` footer ("Current
  Release: vX.Y.Z").

## 4. Commit

- Commit any uncommitted feature/code work first, with focused `feat(...)` /
  `fix(...)` / `test(...)` messages. The release commit carries only the
  version and the copy.
- Then: `chore(release): <ver> (build <build>)`.
- End every commit message with
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## 5. Merge and push

- `git fetch origin` first.
- **beta, rc:** merge `main` into the beta branch **before step 1**, so a beta
  never lacks a stable fix. Push the beta branch.
- **alpha:** push the work branch (`git push -u origin <branch>` the first
  time). Merge the open beta branch in first if the alpha builds on it.
- **ga patch on `main`:** push `main`.
- **ga promotion:** do this before step 1. Merge `origin/main` into the beta
  branch, verify green there, and make the release commit on the beta branch.
  Then fast-forward `main` onto it (`git checkout main && git merge --ff-only
  <beta branch>`) and push both. If `main` cannot fast-forward, stop and look:
  something landed on `main` that the merge missed.
- The website redeploys from GitHub Pages on any push to `main` that touches
  `website/`. A push to any other branch deploys nothing.
- If a push is rejected because the remote moved, `git rebase origin/<branch>`
  and push again. Never force-push a release branch.

## 6. Build the signed + notarized DMG

Every stage ships a DMG that has to open on someone else's Mac, so this always
runs.

Resolve the inputs rather than assuming them:
- **Signing identity:** the `Developer ID Application` line from
  `security find-identity -v -p codesigning`.
- **Notary profile:** `cratedigger-notary` (confirm with
  `xcrun notarytool history --keychain-profile cratedigger-notary`).
- **ffmpeg/ffprobe:** the *static* binaries in
  `/Volumes/MUSIC/Development/tools/ffmpeg-static-8.1-arm64`. Never Homebrew's:
  a Homebrew ffmpeg in a signed bundle dies at launch on other Macs with a dyld
  Team ID mismatch (`package-app.sh` guards this; don't defeat it).

```bash
CRATEDIGGER_NOTARY_PROFILE=cratedigger-notary scripts/package-app.sh \
  --ffmpeg  /Volumes/MUSIC/Development/tools/ffmpeg-static-8.1-arm64/ffmpeg \
  --ffprobe /Volumes/MUSIC/Development/tools/ffmpeg-static-8.1-arm64/ffprobe \
  --sign "<Developer ID Application identity>" \
  --notarize --dmg > "$S/package.log" 2>&1; echo "package exit=$?"
```

Notarization is a round trip to Apple. Allow about 5 minutes and run it in the
background rather than polling it.

Then verify, and report what each command actually prints:
- `/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" -c "Print :CFBundleVersion" dist/CrateDigger.app/Contents/Info.plist`
- `spctl -a -t open --context context:primary-signature -v dist/CrateDigger-<ver>.dmg`: expect `accepted` and `source=Notarized Developer ID`
- `xcrun stapler validate dist/CrateDigger-<ver>.dmg`: expect `The validate action worked!`

If signing or notarization fails (expired certificate, missing profile, Apple
rejection), stop and report the actual error. The push has already happened, so
the fix is a follow-up build, never rewritten history.

## 7. Publish the GitHub release

Only after step 6 has verified clean.

- **Tag and title:** from the stage table. The command creates the tag against
  the branch you released from: pass `--target <branch>`, because a raw commit
  SHA is rejected as an invalid `target_commitish`.
- **alpha, beta, rc: pass `--prerelease`.** Without it the build becomes
  `/releases/latest`, which is what the website's Download button and every fresh
  download resolve to. That hands an untested build to everyone, even though the
  feeds are clean.
- **Body:** the CHANGELOG section (intro, then `## Added` / `## Changed` /
  `## Fixed`), then `---` and the install footer naming the DMG. For a GA that
  folds in an unreleased version, follow it with that version's section under
  `# Also new in <minor>, from <unreleased version>`. Write the body to a file and
  pass `--notes-file`, because the notes contain backticks that a shell-quoted
  `--notes` mangles.
- **Asset:** the notarized DMG.

```bash
gh release create <tag> dist/CrateDigger-<ver>.dmg \
  --target <branch> [--prerelease] \
  --title "<title>" --notes-file "$S/notes-<ver>.md"
gh release view <tag> --json isDraft,isPrerelease,assets \
  -q '"draft=\(.isDraft) prerelease=\(.isPrerelease)", (.assets[] | "\(.name) \(.state) \(.size)")'
```

Expect `draft=false`, the right `prerelease` value, and the asset `uploaded` with
the local DMG's exact size (`stat -f %z`).

## 8. Publish the update feed(s)

The shipped app updates itself from these feeds, so a release that skips this
step is invisible to everyone already running CrateDigger. Run it after the
release exists: the feed points at that release's download URL, and the
signature covers the exact DMG bytes uploaded in step 7.

Each feed is written on the branch that owns it:

| Feed | Written on | Command |
|---|---|---|
| `appcast.xml` (stable) | `main` | `scripts/update-appcast.sh` |
| `appcast-beta.xml` | the beta branch (`BETA_BRANCH`) | `scripts/update-appcast.sh --appcast website/appcast-beta.xml --tag <tag>` |
| `appcast-nightly.xml` | the alpha's branch | `scripts/update-appcast.sh --appcast website/appcast-nightly.xml --tag <tag>` |

For each feed this stage writes (one, or two for GA), do the following in order:

1. **Run the script.** It signs the DMG with the EdDSA key in the Keychain and
   takes the notes from the `## <ver> ` CHANGELOG section. If the key is
   missing it fails loudly. Stop then, because an unsigned entry is refused by
   every installed copy.
2. **Check the new entry.** Its `<enclosure url=…>` names this tag and DMG,
   carries `sparkle:edSignature`, and its `length` equals the DMG's size. Older
   items keep the URLs they were published with. Don't count `<item>`s: the
   stable feed is a rolling window, so the count stays the same.
3. **Upload the deltas the script just created.** It writes delta enclosures
   (`CrateDigger<build>-<old>.delta`) pointing at *this* release, but step 7
   only uploaded the DMG. An installed copy prefers the delta, gets a 404, and
   its update fails while a fresh download still works, which is why this hides
   so well. Upload only this build's deltas from that feed's staging folder:
   `gh release upload <tag> dist/updates<-suffix>/CrateDigger<build>-*.delta`.
   Having none is normal for a first release on a feed.
4. **Prove every URL in the feed resolves**, not just the new entry. An older
   item can point at a tag whose asset was never uploaded:

   ```bash
   grep -o 'url="[^"]*"' website/<feed> | sed 's/url="//;s/"//' | while read u; do
     echo "$(curl -sL -o /dev/null -w '%{http_code}' --max-time 30 "$u")  $u"
   done
   ```

   Every line must read `200`. Fix anything else before committing.
5. **Commit:** `chore(release): publish <tag without v> to the <stable|beta|nightly> feed`.
   `git show --stat` must list only that feed's file. If a beta or nightly
   commit touches `website/appcast.xml`, stop: that is the file every stable
   user reads.

**Getting a feed onto `main`.** GitHub Pages deploys `website/` from `main`
only, so a feed committed anywhere else is never served:
- If the branch is `main` plus only the feed commit (always true for a GA
  promotion), fast-forward `main` onto it and push both.
- Otherwise take that one file across and nothing else:

  ```bash
  git checkout main
  git checkout <branch> -- website/<feed>
  git commit -m "chore(release): publish <tag without v> to the <beta|nightly> feed"
  git push origin main
  git checkout <branch>
  ```

**Which feeds each stage writes:**
- **alpha:** nightly only.
- **beta, rc:** beta. Also nightly, if alpha testers exist on this line, so
  that they move up onto the beta.
- **ga:** stable on `main`, **and** beta on the beta branch. A stable build with
  Receive beta updates on reads *only* the beta feed, so a GA missing from it is
  never offered to opted-in users (2.1.1 shipped that way). The two feeds stage
  separately, so each gets its own deltas (step 3). The beta feed's deltas have
  different names (from the beta builds), so they upload to the same release
  without a clash.

**Confirm the deployed feeds**, not just the local files. Pages takes a minute or
two after the push:

```bash
for f in appcast.xml appcast-beta.xml appcast-nightly.xml; do
  [ -f website/$f ] && curl -sL https://cratedigger.mrbarkan.com/$f | diff -q - website/$f >/dev/null \
    && echo "$f deployed" || echo "$f NOT deployed yet"
done
```

In any shell chain that ends in a push or publish, gate each step with an
explicit `|| { echo "FAIL: ..."; exit 1; }`. `set -e` has been seen not to stop
such a chain in this environment.

## 9. Beta lines: after a GA, and opening a new one

The beta line is done. **Leave `BETA_BRANCH` where it is**: the next beta
pressed there is that line's next patch (2.2.3 GA, then 2.2.4 beta 1). The
tooling moves only when a beta is pressed from another branch, which opens a
new line there (step 0). Opening a line means:
- change `BETA_BRANCH` in `scripts/update-appcast.sh`;
- update "Where the lines stand" in this skill and the "Two release lines"
  section of `CLAUDE.md`;
- move the shipped line's DMGs out of `dist/updates-beta/` into
  `dist/updates-beta/old_updates/` once the next line's first beta is ready
  (the script refuses a DMG whose major version differs from what is staged);
- merge `main` into the new beta branch (or cut it from `main` if it doesn't
  exist yet), and set its `channel` to `"BETA"`.

## 10. Report

Give the user: the stage, version and build; the commit hashes; which branches
were pushed; the DMG path with its verified spctl and staple results; the
release URL and whether it is a prerelease; each feed written, with the all-200
check and the deployed check; and anything left open (for example a work branch whose next version moved).

## Notes

- The full beta gate lives in `docs/BETA_RELEASE_CHECKLIST.md`.
- In-app updating (Sparkle, the feeds, the one-time signing key) is documented
  in README under "In-app updates"; the runtime feed choice and why it is not in
  `Info.plist` are in `CLAUDE.md`, "Two release lines".
- `scripts/package-app.sh` with no flags produces an ad-hoc-signed
  `dist/CrateDigger.app`: the local dev build, for when the user explicitly asks
  for a quick unsigned one instead of a release.
- The release commands (`gh release`, `git push origin`, `update-appcast.sh`,
  `spctl`, `stapler`, `curl`) can be stopped by the auto-mode permission
  check. If they are, stop and say which step is blocked; don't route around it.
