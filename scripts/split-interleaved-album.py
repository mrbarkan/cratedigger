#!/usr/bin/env python3
"""Un-interleave a second album rip that CrateDigger wrote into an existing
album folder as "Track (2).m4a"-style siblings.

Moves every "<name> (N).<ext>" audio file (N >= 2) into a sibling folder
"<album folder name> [version N]", stripping the " (N)" suffix. Dry-run by
default — pass --apply to actually move files.

Usage:
    scripts/split-interleaved-album.py "/path/to/Artist/2001 Album"          # preview
    scripts/split-interleaved-album.py "/path/to/Artist/2001 Album" --apply  # do it
"""
import re
import shutil
import sys
from pathlib import Path

AUDIO_EXTS = {".mp3", ".m4a", ".aac", ".flac", ".wav", ".aiff", ".aif", ".ogg", ".opus", ".alac"}
SUFFIX = re.compile(r"^(?P<base>.+) \((?P<n>[2-9]|\d{2,})\)$")

def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--apply"]
    apply = "--apply" in sys.argv
    if len(args) != 1:
        print(__doc__)
        return 2
    folder = Path(args[0]).expanduser().resolve()
    if not folder.is_dir():
        print(f"error: {folder} is not a directory")
        return 1

    moves = []  # (source, destination)
    for file in sorted(folder.iterdir()):
        if not file.is_file() or file.suffix.lower() not in AUDIO_EXTS:
            continue
        match = SUFFIX.match(file.stem)
        if not match:
            continue
        version_dir = folder.parent / f"{folder.name} [version {match['n']}]"
        moves.append((file, version_dir / f"{match['base']}{file.suffix}"))

    if not moves:
        print(f"nothing to do: no ' (N).<audio>' files in {folder}")
        return 0

    for source, destination in moves:
        print(f"{'MOVE' if apply else 'would move'}  {source.name}  ->  {destination.parent.name}/{destination.name}")
        if apply:
            if destination.exists():
                print(f"  skip: {destination} already exists")
                continue
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(source), str(destination))

    if not apply:
        print("\n(dry run — re-run with --apply to move the files)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
