---
name: press-the-record
description: CrateDigger release macro. Use when the user says "press the record" (also "press record", "cut a release", "ship a release"). Verifies the build, bumps the version, updates the changelog + README + website copy, commits, pushes, builds the signed + notarized DMG, and publishes the GitHub release with the DMG attached. Handles both lines: stable from main, and the 2.1 betas from the v2.1 branch.
---

# Press the Record — CrateDigger release macro

Run these steps in order. Stop and report if any step fails; never push or
package on a red build.

## 0. Work out which line you are releasing

**Run `git branch --show-current` first.** The two lines differ at almost every
step, and getting this wrong is the one mistake here that reaches real users.

| | `main` (stable) | `v2.1` (beta) |
|---|---|---|
| Audience | everyone | stable users who turned on Receive beta updates |
| Marketing version | patch bump | stays `2.1.0` |
| `AppVersion.channel` | `""` | `"BETA"` |
| Tag | `v2.0.5` | `v2.1.0-beta.<build>` |
| GitHub release | normal | `--prerelease` |
| Feed | `website/appcast.xml` | `website/appcast-beta.xml` |
| CHANGELOG section | new per release | one `## 2.1.0` that accumulates |

Then pick the version:
- Read the current `marketing` and `build` from `Sources/CrateDiggerApp/AppVersion.swift`.
- **Build number:** always bump by 1, on either line. It is monotonic across both.
- **Marketing version (main):** if the user named one in the invocation (e.g.
  "press the record 1.1.0"), use it. Otherwise default to a **patch bump**
  (`X.Y.Z` → `X.Y.(Z+1)`) and state the version you chose in your first message
  so the user can correct it.
- **Marketing version (v2.1):** stays `2.1.0`. Bump `channelOrdinal` instead — it
  is the beta number in the About pill, so beta 3 is `channelOrdinal = "3"`.
  The first 2.1 beta takes it from `""` to `"1"`.
- `channel` stays `""` on main and `"BETA"` on v2.1 unless the user says otherwise.

## 1. Verify green
- `swift build` must succeed.
- `scripts/test.sh` must pass with 0 failures.
- If either fails, stop and report — do not release.

## 2. Bump the version (keep both in sync)
- `Sources/CrateDiggerApp/AppVersion.swift`: `marketing` and `build`.
- `Packaging/CrateDiggerApp/Info.plist`: `CFBundleShortVersionString` (= marketing)
  and `CFBundleVersion` (= build). On v2.1 only `CFBundleVersion` moves, and do
  not touch `SUFeedURL` — pointing it back at the stable feed is exactly the
  mistake the beta line exists to prevent.
- Re-run `swift build` to confirm the bump compiles.

## 3. Update the copy
- **`CHANGELOG.md`** (create if missing): add a new `## <marketing> (<build>), <YYYY-MM-DD>`
  section at the top, above the previous entry. Draft the entries by reading
  `git log <last release commit>..HEAD` (the previous `chore(release):` commit)
  and grouping into **Added / Changed / Fixed**. Write them for users — one
  bullet per user-visible change, not one per commit. Pass today's date in;
  don't call `date` from a script. No em or en dashes in anything a user reads.
- **`README.md`**: update the release line (currently "Now at the X release.").
- **`website/index.html`**: update the footer "Current Release: vX.Y.Z".

**On v2.1, step 3 is different.** There is one `## 2.1.0 (<build>), <date>`
section at the top of the CHANGELOG that you *add to* each beta rather than
replacing, since a tester wants to read everything in 2.1.0 so far. Keep the
heading matching `## 2.1.0 ` exactly — the appcast script finds the notes by
that prefix. Do **not** touch `README.md` or `website/index.html`: those
describe the shipping stable release, which is still 2.0.x.

## 4. Commit
- If there is uncommitted **feature/code** work in the tree, commit it first with a
  focused `feat(...)` / `fix(...)` message (or several) — the release commit should
  only carry the version + copy.
- Then commit the version bump + copy as:
  `chore(release): <marketing> (build <build>)`
- End every commit message with the required trailer:
  `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`

## 5. Push
- `git fetch origin` then `git push origin <branch>` — `main` for a stable
  release, `v2.1` for a beta. The website redeploys via GitHub Pages on a push to
  `main` that touches `website/`; a `v2.1` push deploys nothing.
- If the push is rejected (remote moved), `git rebase origin/<branch>` and push
  again.

## 6. Build the signed + notarized DMG
Every release ships a DMG that opens on someone else's Mac, so this runs by
default — not only when the user says "notarized".

Resolve the three inputs rather than hardcoding them:
- **Signing identity:** the Developer ID Application line from
  `security find-identity -v -p codesigning`.
- **Notary profile:** `cratedigger-notary` (confirm with
  `xcrun notarytool history --keychain-profile cratedigger-notary`).
- **ffmpeg/ffprobe:** the *static* binaries in
  `/Volumes/MUSIC/Development/tools/ffmpeg-static-8.1-arm64`. Never the Homebrew ones — a
  Homebrew ffmpeg shipped in a signed bundle dies at launch on other Macs with
  a dyld Team ID mismatch (`package-app.sh` guards this, don't defeat it).

```bash
CRATEDIGGER_NOTARY_PROFILE=cratedigger-notary scripts/package-app.sh \
  --ffmpeg  /Volumes/MUSIC/Development/tools/ffmpeg-static-8.1-arm64/ffmpeg \
  --ffprobe /Volumes/MUSIC/Development/tools/ffmpeg-static-8.1-arm64/ffprobe \
  --sign "<Developer ID Application identity>" \
  --notarize --dmg
```

Notarization is a network round-trip to Apple: allow ~5 minutes, and run it
with a generous timeout rather than polling it to death.

Then verify — report what these actually print, never assume:
- `/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" -c "Print :CFBundleVersion" dist/CrateDigger.app/Contents/Info.plist`
- `spctl -a -t open --context context:primary-signature -v dist/CrateDigger-<version>.dmg` → expect `accepted` / `source=Notarized Developer ID`
- `xcrun stapler validate dist/CrateDigger-<version>.dmg` → expect `The validate action worked!`

If signing or notarization fails (expired cert, missing profile, Apple
rejection), stop and report with the actual error — the push has already
happened, so the fix is a follow-up build, never a rewritten history.

## 7. Publish the GitHub release
Only after step 6 verified clean — never publish a DMG whose staple you haven't
checked.

House style, matched from the previous release (`gh release view <last tag>`):
- **Tag:** `v<marketing>` on main, `v2.1.0-beta.<build>` on v2.1, created by this
  command against the branch you released from (pass `--target main` or
  `--target v2.1`; a raw commit SHA is rejected as an invalid `target_commitish`).
- **On v2.1, pass `--prerelease`.** Without it the beta becomes
  `/releases/latest`, which is what the website's Download button and every
  fresh download resolve to. That hands an untested build to everyone even
  though the update feed is clean.
- **Title:** `CrateDigger <marketing> (build <build>): <short tagline>`, the
  tagline being the release's one idea in three or four words.
- **Body:** the CHANGELOG entry for this version — intro line, then
  `## Added` / `## Changed` / `## Fixed` — followed by `---` and the install
  footer naming the DMG. Write it to a file and pass `--notes-file`; the notes
  contain backticks that a shell-quoted `--notes` mangles.
- **Asset:** the notarized DMG.

```bash
gh release create v<marketing> dist/CrateDigger-<marketing>.dmg \
  --target main \
  --title "CrateDigger <marketing> (build <build>): <tagline>" \
  --notes-file <notes.md>

# v2.1 beta instead:
gh release create v2.1.0-beta.<build> dist/CrateDigger-2.1.0.dmg \
  --target v2.1 --prerelease \
  --title "CrateDigger 2.1.0 beta <ordinal> (build <build>): <tagline>" \
  --notes-file <notes.md>
```

Confirm it landed, don't assume the upload finished:
`gh release view v<marketing> --json isDraft,assets` → `draft:false` and the
asset `state: uploaded`.

## 8. Publish the update feed
The shipped app updates itself from `website/appcast.xml`, so a release that
skips this step is invisible to everyone already running CrateDigger.

Run it after the release exists — the feed points at that release's download
URL, and the signature covers the exact DMG bytes uploaded in step 7:

```bash
scripts/update-appcast.sh                    # stable, from main

# v2.1 beta: its own feed, and a tag that cannot be derived from the DMG name.
scripts/update-appcast.sh \
  --appcast website/appcast-beta.xml \
  --tag v2.1.0-beta.<build>
```

**Publishing the beta feed takes one extra move.** GitHub Pages only deploys
`website/` from `main`, so a feed sitting on `v2.1` is never served. Take just
that one file across, and nothing else:

```bash
git checkout main
git checkout v2.1 -- website/appcast-beta.xml
git commit -m "chore(release): publish 2.1.0-beta.<build> to the beta feed"
git push origin main
git checkout v2.1
```

`main` never receives beta code this way — only the beta feed, which no stable
build reads unless its owner opted in. Confirm `website/appcast.xml` is untouched
by the commit (`git show --stat`); if it appears, stop, because that is the file
every 2.0.x user reads.

It signs the DMG with the private EdDSA key in the Keychain and rewrites
the feed, taking release notes from the CHANGELOG section for this version.
Then commit and push it:

`chore(release): publish <marketing> to the update feed`

Confirm the entry landed: the new `<enclosure url=...>` names this version's
DMG, carries a `sparkle:edSignature`, and its `length` equals the DMG's size.
Do not use "`<item>` count went up": the stable feed is a rolling window of
three items, so the count stays put. If the key is missing the script fails
loudly — stop and report rather than pushing a feed with an unsigned entry,
which every installed copy will refuse.

### Upload the deltas the feed just invented, then prove every URL resolves

The script writes **delta** enclosures (`CrateDigger<new>-<old>.delta`) pointing
at *this* release's download URL, but step 7 only uploaded the DMG — so the feed
now names an asset that does not exist. An installed copy on the previous build
takes the delta in preference to the full DMG, gets a 404, and its update fails
while a fresh download works fine, which is why this hides so well. The script
prints a reminder; nothing enforces it.

Upload only the deltas for **this** build (`CrateDigger<build>-*.delta`; the
staging folder also keeps older builds' deltas, which belong to their own
releases), then check the whole feed rather than just the entry you added — an
older item can be repointed at a tag whose asset was never uploaded. The beta
feed stages in `dist/updates-beta/` instead of `dist/updates/`:

```bash
# no deltas is normal on a first release; only upload when some exist
ls dist/updates/CrateDigger<build>-*.delta >/dev/null 2>&1 \
  && gh release upload v<marketing> dist/updates/CrateDigger<build>-*.delta

grep -o 'url="[^"]*"' website/appcast.xml | sed 's/url="//;s/"//' | while read u; do
  echo "$(curl -sL -o /dev/null -w '%{http_code}' --max-time 30 "$u")  $(basename "$u")"
done
```

Every line must read `200`. Anything else means an installed copy will fail to
update: fix it before committing the feed, because the pushed feed is what every
running app reads within the day.

Push the feed only once that is clean, then confirm the **deployed** file, not
the local one — Pages lags the push by a minute or two:

```bash
curl -sL https://cratedigger.mrbarkan.com/appcast.xml | diff - website/appcast.xml \
  && echo "deployed feed matches"
```

In any shell chain that ends in a push or publish, gate each step with an
explicit `|| { echo "FAIL: ..."; exit 1; }`. `set -e` has been seen not to stop
such a chain in this environment.

## 9. Report
Give the user: the version + build, the commit hashes, confirmation of the push,
the DMG path with its verified staple/spctl result, the release URL, confirmation
that the update feed was published (including the all-200 enclosure check), and
a note that the website will redeploy shortly.

## Notes
- The full beta gate lives in `docs/BETA_RELEASE_CHECKLIST.md`.
- In-app updating (Sparkle, the appcast, the one-time signing key) is documented
  in README under "In-app updates".
- `scripts/package-app.sh` with no flags still produces an ad-hoc-signed
  `dist/CrateDigger.app` — that's the local dev build, useful when the user
  explicitly asks for a quick unsigned one instead of a release.
- The 2.0 cycle ran on a `v2` branch, retired at 2.0.0 GA and kept for history.
  Do not release from it.
