#!/bin/bash
# A FAT disk image for FATSandboxTests: what macOS does on a real FAT volume
# (._ twins, .TemporaryItems, rename, name bytes) without touching a device.
# The image is 64 MB of FAT32, as on the iPod (plain "-fs MS-DOS" would make
# FAT16 at this size).
#
#   scripts/fat-sandbox.sh up <dir>     create <dir>/fat.dmg, attach it at <dir>/mnt,
#                                       print `export CRATEDIGGER_FAT_SANDBOX=<dir>/mnt`
#   scripts/fat-sandbox.sh down <dir>   detach every attachment of <dir>/fat.dmg, then delete it
#
# The image is attached with -nobrowse at a mount point inside <dir>, never
# under /Volumes, so CrateDigger's device detection cannot see it. <dir> must
# already exist and must not be under /Volumes. Only stdout carries the
# export line; hdiutil's own messages go to stderr, so a failure says why.
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

fail() {
    echo "fat-sandbox: $*" >&2
    exit 1
}

[[ $# -eq 2 ]] || usage
command="$1"
dir="$2"

[[ -d "$dir" ]] || fail "$dir does not exist (or is not a folder); refusing."
# Resolve symlinks so /tmp and friends cannot hide a /Volumes path.
dir="$(cd "$dir" && pwd -P)"
case "$dir" in
    /Volumes|/Volumes/*) fail "$dir is under /Volumes; refusing (device detection would see it)." ;;
esac
command -v hdiutil >/dev/null 2>&1 || { echo "fat-sandbox: hdiutil is not available." >&2; exit 69; }

image="$dir/fat.dmg"
mountpoint="$dir/mnt"

# The whole-disk device of every attachment of $image, from hdiutil's own
# list (it reports the image by its real path, which $image already is).
attached_disks() {
    hdiutil info | awk -v img="$image" '
        /^=+$/ { current = 0; next }
        /^image-path[ \t]*:/ { path = $0; sub(/^image-path[ \t]*:[ \t]*/, "", path); current = (path == img); next }
        current && /^\/dev\/disk[0-9]+[ \t]/ { print $1 }'
}

something_mounted_at_mountpoint() {
    mount | grep -F " on $mountpoint (" >/dev/null 2>&1
}

# Detach every attachment, and delete the image only once hdiutil no longer
# lists it: never remove an image that is still attached.
teardown() {
    local disk
    for disk in $(attached_disks); do
        echo "fat-sandbox: detaching $disk" >&2
        hdiutil detach "$disk" >&2 || hdiutil detach -force "$disk" >&2 || true
    done
    if [[ -n "$(attached_disks)" ]]; then
        fail "$image is still attached ($(attached_disks | tr '\n' ' ')); not deleting it."
    fi
    if something_mounted_at_mountpoint; then
        fail "something is still mounted at $mountpoint; not deleting anything."
    fi
    rm -f "$image"
    if [[ -d "$mountpoint" && ! -L "$mountpoint" ]]; then
        rmdir "$mountpoint" 2>/dev/null || echo "fat-sandbox: left $mountpoint in place: it is not empty." >&2
    fi
}

case "$command" in
    up)
        if [[ -e "$image" ]] || [[ -n "$(attached_disks)" ]] || something_mounted_at_mountpoint; then
            fail "a sandbox already exists in $dir; run '$0 down $dir' first."
        fi
        # The mount point must be ours: absent, or a real, empty folder.
        if [[ -L "$mountpoint" ]]; then
            fail "$mountpoint is a symlink; refusing."
        elif [[ -e "$mountpoint" ]]; then
            [[ -d "$mountpoint" ]] || fail "$mountpoint exists and is not a folder; refusing."
            [[ -z "$(ls -A "$mountpoint")" ]] || fail "$mountpoint is not empty; refusing."
        fi
        mkdir -p "$mountpoint"
        # Whatever fails from here, leave no image or mount behind.
        trap 'echo "fat-sandbox: setup failed; cleaning up." >&2; teardown' ERR
        hdiutil create -size 64m -fs "MS-DOS FAT32" -volname CDTEST "$image" >&2
        hdiutil attach -nobrowse -mountpoint "$mountpoint" "$image" >&2
        trap - ERR
        echo "export CRATEDIGGER_FAT_SANDBOX=$mountpoint"
        ;;
    down)
        teardown
        ;;
    *)
        usage
        ;;
esac
