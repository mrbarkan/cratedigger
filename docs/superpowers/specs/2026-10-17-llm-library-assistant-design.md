# LLM library assistant (MCP), hidden until 2.4

Status: approved in conversation on 2026-10-17; built on `v2.3` for the 2.3.2
betas, switched off unless a hidden preference is set. Visible in 2.4.

## Why

Someone drops a whole music collection into one crate and does not want to
file it by hand. They already talk to an LLM (Claude Desktop). Let that LLM
see the library and act on it, safely: "sort this crate into crates by
mood", "make a playlist of the Pitchfork Best New Music I own", "my rips
carry five genres each, clean them up", "tag genres the way iTunes does",
"recommend something from what I play most", "find me new radio streams".

CrateDigger does none of the thinking. Moods, Pitchfork's genres, "sounds
like", finding streams: that knowledge and any web search are the LLM's.
CrateDigger shows it the library and gives it a small set of safe actions.

## Goals

- An MCP server that Claude Desktop (or any MCP client that launches local
  stdio servers) can use to read the library and change it.
- Every change is either approved in the chat and undoable from CrateDigger,
  or reviewed in CrateDigger before anything is written.
- Works only while CrateDigger is open.
- Hidden in 2.3.2 betas behind a preference; nothing visible without it.

## Non-goals

- No LLM, API key or account inside CrateDigger.
- No audio analysis. Mood comes from what the LLM knows about the music.
- No file moves, deletes or conversions through the assistant.
- Prep Crate is readable but not writable in v1: filing out of the Prep
  Crate goes through import, which can copy files into the managed library
  (copy-on-import), and that is not a membership change an undo can reverse.
- Remote (Subsonic), CD, device and radio sources are not part of the
  library the assistant sees, apart from the saved stream list.

## Anti-goals (it has failed if)

- A file path, folder name or user name leaves the Mac. The LLM sees tracks
  only by ID.
- An LLM rewrites tags in files without the user looking at the change in
  CrateDigger first. Claude Desktop's "Allow always" must not be able to
  skip that review.
- A bad sort cannot be taken back.

## Decisions (the user's)

- Review: crates, playlists and streams are approved in Claude and undoable
  in CrateDigger; tag edits are reviewed in a CrateDigger sheet.
- Any tag may be proposed (the ten FIX TAGS fields: title, artist, album
  artist, album, track number/total, disc number/total, year, genre), and
  every tag change goes through the review sheet.
- Undo is important.
- Only while CrateDigger is open.
- Tracks are referred to by ID only, never by file path.
- Hidden switch, so the feature can be tested on the betas:
  `defaults write com.cratedigger.app cratedigger.labs.llm -bool YES`.

## Shape

```
Claude Desktop ──stdio──▶ CrateDiggerMCP (helper in the app bundle)
                              │  MCP handshake + tool list answered locally
                              │  tools/call forwarded as one JSON line
                              ▼
            ~/Library/Application Support/CrateDigger/assistant.sock
                              │
                              ▼
                 CrateDigger (running, switch on)
                 AssistantService → LibraryAssistant (Core) → host (view model)
```

- **AssistantKit** (new SwiftPM target, Foundation only): `JSONValue`, the
  MCP JSON-RPC dispatcher, the tool catalogue (names, descriptions, input
  schemas, annotations), the unix-socket line transport, and the Claude
  Desktop config merge. Both the app and the helper link it; the helper does
  not link Core.
- **CrateDiggerMCP** (new executable target): reads newline-delimited
  JSON-RPC on stdin, answers `initialize`, `ping` and `tools/list` itself,
  forwards each `tools/call` over the socket and writes the reply to stdout.
  When the app is not running (or the switch is off) a call returns a tool
  error saying to open CrateDigger, so Claude explains it rather than the
  server failing to start.
- **Core** (`Services/Assistant/`): the library snapshot the tools read, the
  pure tool logic (search, paging, planning crate changes), and the change
  journal. Tested against a fake host.
- **App**: `AssistantService` owns the socket while the switch is on;
  `LibraryViewModel+Assistant` is the host and applies changes through the
  existing write funnels (so the disconnected-library guard and repointing
  apply); a review sheet for tag proposals; Edit ▸ Undo AI Change; a
  Settings ▸ Advanced section, shown only with the switch on, with an
  "Add to Claude Desktop" button.

## Tools

IDs are `AudioTrack.id` (stable across relaunches and retags). Crates and
playlists are named. Results are compact JSON in a text block, paged.

| Tool | Kind | What it does |
|---|---|---|
| `library_overview` | read | totals, crates and playlists with counts, top genres, year range, formats |
| `search_tracks` | read | filter by text, artist, album, genre, years, crate, plays, missing tags; sort; page |
| `list_albums` | read | albums (optionally in one crate) with year, genres, plays and their track IDs |
| `listening_history` | read | most played tracks, artists and albums, all time / this year / this month |
| `list_streams` | read | saved radio streams |
| `list_changes` | read | the undo journal, newest first |
| `file_into_crates` | change | create crates as needed and add tracks to them; optionally remove the filed tracks from one source crate (a move) |
| `create_playlist` | change | create or replace a playlist from track IDs |
| `add_streams` | change | add YouTube stream URLs to Radio |
| `undo_last_change` | change | undo the newest journal entry |
| `propose_tag_changes` | proposal | open the review sheet with per-track tag edits |

Every change and proposal carries a short `summary` from the LLM, which is
what the journal and the menu show ("Undo AI Change: 5 mood crates").

## Journal and undo

- One tool call is one entry, which is why the change tools take whole jobs.
- An entry stores what it replaced: each touched crate's previous membership
  (or "did not exist"), the previous playlist (or "did not exist"), the
  previous stream list, or each retagged track's previous tags.
- Undo restores those and removes the entry. A created crate or playlist is
  moved to the Trash, not deleted.
- Persisted as JSON in `Application Support/CrateDigger/assistant-journal.json`,
  newest 20 kept, so a bad sort can be undone after a relaunch.
- Tag undo writes the previous tags back through the same tag writer, which
  also renames the file back if the library is kept organised.
- Edit ▸ Undo AI Change: <summary> appears only with the switch on.

## Review sheet (tags)

Presented from the root (`LibraryPresentations`), so it shows in compact too.
Header: "Proposed by your assistant" and the LLM's summary. One row per track:
title, then each changed field as before → after; a checkbox per track,
select all / none. Apply writes through `updateTracksMetadata` after
journalling the previous tags; Discard closes it. One proposal at a time: a
second one while the sheet is open is refused with a message the LLM can
relay.

## Calls made by the builder (not discussed)

- Unix socket under Application Support, mode 0600, rather than XPC or a TCP
  port: no network surface, no Mach service registration, works from a plain
  `swift build`.
- Protocol handled by hand in AssistantKit instead of the MCP Swift SDK, to
  keep Sparkle the only third-party dependency.
- The helper ships at `Contents/MacOS/CrateDiggerMCP`, signed like the other
  helpers.
- Result sizes capped (search 100 by default, 500 max) so one call cannot
  flood the LLM's context.
- Prep Crate read-only in v1 (see non-goals).
- Reads (search, albums, history) cover the library, every crate, and leave
  out tracks that are only in the Prep Crate unless `crate: "Prep Crate"` is
  named, the same split `library_overview` reports.
- Numbers can be changed but not removed. The tag writer leaves a nil field
  alone and deletes an empty one, and a number has no empty form, so a
  proposal that removes a year or track number is refused, and an undo that
  would have to remove one leaves it and says so. Text fields are cleared by
  writing "". Found end to end, not in review: undo had left an added genre
  in the file.
- Tag writes touch only the fields that changed. The tag model fills an empty
  tag from what the scan read (a title from the file name); writing all ten
  would have put those into files that never had them.

## Built and verified (2026-10-17)

Unit tests cover the protocol, socket, config merge, every tool, the journal
and the undo planner. End to end, on a scratch library through the real
helper: reads, a three-crate sort and its undo from the Edit menu, a tag
proposal reviewed in the sheet with one track unticked, the files' tags read
back with ffprobe after APPLY and after undo, a second proposal refused while
one is open, the "open CrateDigger" reply with the app closed, and no menu
item or socket with the switch off.
