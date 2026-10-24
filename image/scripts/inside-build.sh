#!/usr/bin/env bash
# Runs in the builder container on the host's native platform (see build.sh):
# assembles the root tree with mkosi, then packs the disk image.
set -euo pipefail

cd /work/image
BUILD_DIR=/var/lib/rd-build
PROFILE="${PROFILE:-dev}"

echo "==> mkosi"
args=(--force
      --output-directory="$BUILD_DIR/output"
      --workspace-directory="$BUILD_DIR/work"
      --cache-directory="$BUILD_DIR/cache")
profiles="$PROFILE"; [ "$PROFILE" = release ] && profiles=""
[ -z "${EXTRA_PROFILES:-}" ] || profiles="${profiles:+$profiles,}$EXTRA_PROFILES"
[ -z "$profiles" ] || args+=(--profile="$profiles")
# mkosi 25.3 (Debian trixie) has no --snapshot: point its mirror at the snapshot instead. mkosi
# hardcodes security.debian.org (not mirrored), so security updates published after the snapshot
# are still pulled in: the pin covers main/non-free-firmware/updates, not trixie-security.
[ -z "${SNAPSHOT:-}" ] || args+=(--mirror="https://snapshot.debian.org/archive/debian/$SNAPSHOT")
mkdir -p "$BUILD_DIR"/{output,work,cache}
mkosi "${args[@]}" build

echo "==> pack"
ROOT_TREE="$BUILD_DIR/output/rootfs" NAME_SUFFIX="${NAME_SUFFIX:-}" ./scripts/pack.sh
