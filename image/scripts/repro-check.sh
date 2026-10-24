#!/usr/bin/env bash
# Reproducibility check: builds the same profile twice, each time from scratch (the persistent
# Docker volume holding the SDL build and the mkosi cache is deleted before each build), then
# compares the two images. If they differ, it says which component does.
#
#   ./scripts/repro-check.sh                 # release profile (the one that ships)
#   PROFILE=dev ./scripts/repro-check.sh
#
# Slow (two full builds): about 25 minutes each on an Apple Silicon Mac, much less on a CI runner.
# Both builds use the same commit, hence the same SOURCE_DATE_EPOCH and the same pinned snapshots.
# The dev profile only compares equal when DEV_SSH_KEY is the same for both builds (it is here).
set -uo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
export PROFILE="${PROFILE:-release}"
export VERSION="${VERSION:-$(git -C "$here" describe --always --dirty --tags 2>/dev/null || echo unknown)}"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$here" log -1 --format=%ct 2>/dev/null || date +%s)}"

mkdir -p "$here/out"
for n in 1 2; do
    echo "==> build $n/2 ($PROFILE, $VERSION), from a clean cache"
    docker volume rm -f rd-image-build >/dev/null
    if ! NAME_SUFFIX="-repro$n" "$here/scripts/build.sh" > "$here/out/repro-build$n.log" 2>&1; then
        echo "build $n FAILED, see out/repro-build$n.log"; exit 2
    fi
done

img1="remotedisplay-$VERSION-$PROFILE-repro1.img"
img2="remotedisplay-$VERSION-$PROFILE-repro2.img"
sha1="$(shasum -a 256 "$here/out/$img1" | cut -d' ' -f1)"
sha2="$(shasum -a 256 "$here/out/$img2" | cut -d' ' -f1)"
echo "build 1: $sha1"
echo "build 2: $sha2"

if [ "$sha1" = "$sha2" ]; then
    echo "REPRODUCIBLE: the two images are byte-identical."
    exit 0
fi

echo "NOT reproducible: the images differ. Looking for what differs..."
ndiff="$(cmp -l "$here/out/$img1" "$here/out/$img2" 2>/dev/null | wc -l | tr -d ' ')"
echo "differing bytes: $ndiff (first offsets below; the FAT partition starts at byte 1048576)"
cmp -l "$here/out/$img1" "$here/out/$img2" 2>/dev/null | head -5 | awk '{print "  byte offset " $1}'
echo "(if every file below reads \"same\", only the FAT/GPT metadata differs, e.g. timestamps)"
docker run --rm -v "$here/out":/out -e IMG1="$img1" -e IMG2="$img2" rd-image-builder:native bash -c '
    cd /tmp
    files="vmlinuz initrd.img EFI/BOOT/BOOTX64.EFI live/filesystem.squashfs"
    mkdir -p p1/live p1/EFI/BOOT p2/live p2/EFI/BOOT
    for f in $files; do
        mcopy -i "/out/$IMG1@@1M" ::"$f" "p1/$f"
        mcopy -i "/out/$IMG2@@1M" ::"$f" "p2/$f"
    done
    echo "--- per-file SHA-256 (build 1 | build 2)"
    for f in $files; do
        a=$(sha256sum "p1/$f" | cut -c1-16); b=$(sha256sum "p2/$f" | cut -c1-16)
        if [ "$a" = "$b" ]; then s=same; else s=DIFFERENT; fi
        printf "%-28s %s | %s  %s\n" "$f" "$a" "$b" "$s"
    done
    if ! cmp -s p1/live/filesystem.squashfs p2/live/filesystem.squashfs; then
        echo "--- files that differ inside the squashfs (first 40)"
        unsquashfs -q -d r1 p1/live/filesystem.squashfs >/dev/null 2>&1
        unsquashfs -q -d r2 p2/live/filesystem.squashfs >/dev/null 2>&1
        diff -rq r1 r2 2>&1 | head -40
    fi
'
exit 1
