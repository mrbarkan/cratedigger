#!/bin/bash
# A FAT disk image for FATSandboxTests: what macOS does on a real FAT volume
# (._ twins, .TemporaryItems, rename, name bytes) without touching a device.
# The image is 64 MB of FAT32, as on the iPod (plain "-fs MS-DOS" would make
# FAT16 at this size).
#
#   scripts/fat-sandbox.sh up <dir>     create <dir>/fat.dmg, attach it at <dir>/mnt,
#                                       print `export CRATEDIGGER_FAT_SANDBOX=<dir>/mnt`
#   scripts/fat-sandbox.sh down <dir>   detach <dir>/mnt and delete the image
#
# The image is attached with -nobrowse at a mount point inside <dir>, never
# under /Volumes, so CrateDigger's device detection cannot see it. <dir> must
# already exist and must not be under /Volumes.
#
# Typical use:
#   eval "$(scripts/fat-sandbox.sh up "$SCRATCH")"
#   scripts/test.sh --filter FATSandboxTests
#   scripts/fat-sandbox.sh down "$SCRATCH"
set -euo pipefail

usage() {
    echo "usage: $0 up|down <existing directory outside /Volumes>" >&2
    exit 64
}

[[ $# -eq 2 ]] || usage
command="$1"
dir="$2"

if [[ ! -d "$dir" ]]; then
    echo "fat-sandbox: $dir does not exist (or is not a folder); refusing." >&2
    exit 1
fi
# Resolve symlinks so /tmp and friends cannot hide a /Volumes path.
dir="$(cd "$dir" && pwd -P)"
case "$dir" in
    /Volumes|/Volumes/*)
        echo "fat-sandbox: $dir is under /Volumes; refusing (device detection would see it)." >&2
        exit 1
        ;;
esac

image="$dir/fat.dmg"
mountpoint="$dir/mnt"

is_mounted() {
    mount | grep -F " on $mountpoint (" >/dev/null 2>&1
}

detach() {
    if is_mounted; then
        hdiutil detach "$mountpoint" -quiet || hdiutil detach "$mountpoint" -force -quiet
    fi
    rm -f "$image"
    rmdir "$mountpoint" 2>/dev/null || true
}

case "$command" in
    up)
        if ! command -v hdiutil >/dev/null 2>&1; then
            echo "fat-sandbox: hdiutil is not available." >&2
            exit 69
        fi
        if [[ -e "$image" ]] || is_mounted; then
            echo "fat-sandbox: a sandbox already exists in $dir; run '$0 down $dir' first." >&2
            exit 1
        fi
        mkdir -p "$mountpoint"
        # Whatever fails from here, leave no image or mount behind.
        trap 'echo "fat-sandbox: setup failed; cleaning up." >&2; detach' ERR
        hdiutil create -size 64m -fs "MS-DOS FAT32" -volname CDTEST "$image" -quiet
        hdiutil attach -nobrowse -mountpoint "$mountpoint" "$image" -quiet
        trap - ERR
        echo "export CRATEDIGGER_FAT_SANDBOX=$mountpoint"
        ;;
    down)
        detach
        ;;
    *)
        usage
        ;;
esac
