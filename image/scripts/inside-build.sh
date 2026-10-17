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
[ -z "${SNAPSHOT:-}" ] || args+=(--snapshot="$SNAPSHOT")
mkdir -p "$BUILD_DIR"/{output,work,cache}
mkosi "${args[@]}" build

echo "==> pack"
ROOT_TREE="$BUILD_DIR/output/rootfs" NAME_SUFFIX="${NAME_SUFFIX:-}" ./scripts/pack.sh
