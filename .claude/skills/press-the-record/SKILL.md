---
name: press-the-record
description: CrateDigger release macro. Use when the user says "press the record" (also "press record", "cut a release", "ship a release"), optionally with a stage modifier (alpha, beta, rc, ga) and a version. Verifies the build, bumps the version, updates the changelog (and, for GA, the README and website), commits, pushes, builds the signed + notarized DMG, publishes the GitHub release, and writes the update feed(s) for that stage.
---

# Press the Record — CrateDigger release macro

Run these steps in order. Stop and report if any step fails; never push or
package on a red build.

Invocation: `press the record [alpha|beta|rc|ga] [<version>]`, e.g.
"press the record", "press the record rc", "press the record ga 2.3.1",
"press the record alpha 2.3.2". The modifier picks the **stage**; everything
below branches on it.

## 0. Work out the stage, the branch and the version

**Run `git branch --show-current` first**, then resolve the stage:

| Modifier given | On `main` | On the open beta branch | On any other branch |
|---|---|---|---|
| none | `ga` (a stable patch) | `beta`, unless the last release on the branch was an RC: then ask whether this is the next RC or GA | ask (usually `alpha`) |
| `alpha` | refuse: `main` is stable | allowed | allowed |
| `beta` / `rc` | refuse, switch to the beta branch | allowed | ask: betas and RCs ship from the open beta branch |
| `ga` | a stable patch from `main` | **promote** the beta line into `main` (see GA below) | refuse |

Never release from a history branch: `v2`, `v2.1`, `v2.2`.

### The four stages

| | alpha | beta | rc | ga |
|---|---|---|---|---|
| Audience | people you send the link to | stable users who turned on Receive beta updates | same as beta | everyone |
| Branch | any work branch (ask if unclear) | open beta branch | open beta branch | `main` (patch) or the beta branch merged in (promotion) |
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
feed, or it can never be offered the next alpha. Today `UpdateFeed.override`
(`Updates/SoftwareUpdater.swift`) sends *every* non-empty channel to the beta
feed. So before an alpha, check that `UpdateFeed` has a `nightly` URL and that
`override` returns it for `"ALPHA"`, with `UpdateFeedTests` covering it. If it
doesn't, **stop**: say the plumbing is missing and offer to build it. Never ship
an alpha into the beta feed as a stand-in, because that offers it to every beta tester.
`scripts/update-appcast.sh` already accepts `--appcast website/appcast-nightly.xml`
from any branch and stages it in `dist/updates-nightly/`.

### Where the lines stand

- **2.3.1 shipped GA on 2026-10-19 (build 113)**, promoted from `v2.3` into
  `main`. `main` is the stable line; `v2.3` is at the same commit.
- **The next beta line has not been chosen.** It is either 2.3.2 (the work on
  `next/2.3.2`) or 2.4 (`v2.4`, the parked Stock iPod spec). Until the user
  picks, ask before any beta or RC. `BETA_BRANCH` in `update-appcast.sh` still
  says `v2.3`.

### Pick the version

- Read `marketing`, `build`, `channel` and `channelOrdinal` from
  `Sources/CrateDiggerApp/AppVersion.swift`.
- **Build:** always +1, on every stage and every branch. It is monotonic across
  the whole project, and it is what the feeds and deltas are keyed on.
- **Marketing:** use the version the user named. Otherwise:
  - ga on `main`: a patch bump (`X.Y.Z` to `X.Y.(Z+1)`).
  - ga promotion: the beta line's version, unchanged.
  - alpha, beta, rc: keep the branch's version. A version that already shipped GA
    can never be reused, so on a branch still carrying a shipped version, ask what
    the next one is (e.g. 2.3.2 or 2.4.0).
  - State the version and build you chose in your first message so the user can
    correct them.
- **Ordinal:** +1 within the same channel. Moving to a new channel restarts it
  at `"1"`: alpha 3, then beta 1, then RC 1. GA sets it to `""`.

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

## 9. After a GA promotion

The beta line is done, so the tooling has to point at the next one. **Ask which
branch is next** (for example `next/2.3.2` or `v2.4`), then:
- change `BETA_BRANCH` in `scripts/update-appcast.sh`;
- update "Where the lines stand" in this skill and the "Two release lines"
  section of `CLAUDE.md`;
- move the shipped line's DMGs out of `dist/updates-beta/` into
  `dist/updates-beta/old_updates/` once the next line's first beta is ready
  (the script refuses a DMG whose major version differs from what is staged);
- cut or reset the next beta branch from `main`, and set its `channel`.

## 10. Report

Give the user: the stage, version and build; the commit hashes; which branches
were pushed; the DMG path with its verified spctl and staple results; the
release URL and whether it is a prerelease; each feed written, with the all-200
check and the deployed check; and anything left open (for example the next beta
line after a GA).

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
