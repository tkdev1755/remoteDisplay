#!/usr/bin/env bash
# Host entry point: builds the receiver image inside a Debian container.
#
#   PROFILE=dev|release   (default: dev — SSH + serial console, never ship it)
#   SNAPSHOT=<id>         snapshot.debian.org snapshot to build from; default: the id in
#                         image/SNAPSHOT (reproducible builds). SNAPSHOT=none: latest packages.
#   DEV_SSH_KEY=<path>    public key installed for root in the dev profile
#   EXTRA_PROFILES=a,b    more mkosi profiles (e.g. bpo-kernel); NAME_SUFFIX=-x tags the image
#
# Output: image/out/remotedisplay-<version>-<profile>.img(.zst) + manifest.json
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(dirname "$here")"

PROFILE="${PROFILE:-dev}"
VERSION="${VERSION:-$(git -C "$repo" describe --always --dirty --tags 2>/dev/null || echo unknown)}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$repo" log -1 --format=%ct 2>/dev/null || date +%s)}"

SNAPSHOT="${SNAPSHOT:-$(head -n1 "$here/SNAPSHOT" 2>/dev/null | tr -d '[:space:]')}"
[ "$SNAPSHOT" != none ] || SNAPSHOT=""
echo "Debian snapshot: ${SNAPSHOT:-none (latest packages)}"

command -v docker >/dev/null || { echo "docker not found"; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker daemon is not running"; exit 1; }

# --- payload: rd_helper (Dart cross-compiles to Linux from macOS) --------------
payload="$here/payload/opt/remotedisplay"
mkdir -p "$payload"
echo "==> rd_helper (linux/x64)"
(
    cd "$repo/receiver_helper"
    dart pub get --enforce-lockfile
    dart compile exe --target-os linux --target-arch x64 bin/rd_helper.dart -o "$payload/rd_helper"
)

# --- dev SSH key ---------------------------------------------------------------
keyfile="$here/mkosi.profiles/dev/mkosi.extra/root/.ssh/authorized_keys"
if [ "$PROFILE" = dev ]; then
    key="${DEV_SSH_KEY:-$HOME/.ssh/id_ed25519.pub}"
    if [ -f "$key" ]; then
        mkdir -p "$(dirname "$keyfile")"
        cp "$key" "$keyfile"
    else
        echo "warning: no SSH public key at $key — the dev image will have no remote access" >&2
    fi
fi

# --- builder images and build --------------------------------------------------
# Two stages: receiver_app needs an x86-64 container; mkosi must run natively
# (it cannot run under user-mode x86 emulation).
echo "==> builder containers"
docker build --platform linux/amd64 -t rd-image-builder:amd64 -f "$here/builder/Containerfile" "$here/builder"
docker build -t rd-image-builder:native -f "$here/builder/Containerfile" "$here/builder"
docker volume create rd-image-build >/dev/null

echo "==> receiver_app (linux/amd64)"
docker run --rm --platform linux/amd64 \
    -v "$repo":/work -v rd-image-build:/var/lib/rd-build \
    rd-image-builder:amd64 /work/image/scripts/inside-receiver.sh

echo "==> image build ($PROFILE, $VERSION)"
docker run --rm --privileged \
    -v "$repo":/work -v rd-image-build:/var/lib/rd-build \
    -e PROFILE="$PROFILE" -e VERSION="$VERSION" \
    -e SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" -e SNAPSHOT="${SNAPSHOT:-}" \
    -e EXTRA_PROFILES="${EXTRA_PROFILES:-}" -e NAME_SUFFIX="${NAME_SUFFIX:-}" \
    rd-image-builder:native /work/image/scripts/inside-build.sh

echo "==> done: $here/out"
ls -lh "$here/out"
