#!/usr/bin/env bash
# Boots one image in QEMU once per simulated iMac model and checks the model-dependent panel
# parameter (4096x2304 only on the 21.5" 4K iMacs). Used by CI, runnable locally:
#
#   ./scripts/ci-smoke.sh out/remotedisplay-<version>-dev.img
#
# Needs Docker and the rd-image-builder:native image (built by scripts/build.sh).
# Uses KVM inside the container when the host has /dev/kvm.
set -uo pipefail

img="${1:?usage: ci-smoke.sh <image>}"
repo="$(cd "$(dirname "$0")/../.." && pwd)"
img_abs="$(cd "$(dirname "$img")" && pwd)/$(basename "$img")"
case "$img_abs" in "$repo"/*) ;; *) echo "the image must live inside the repository ($repo)"; exit 1;; esac
rel="${img_abs#"$repo"/}"

kvm=()
[ -w /dev/kvm ] && kvm=(--device /dev/kvm)
timeout_s="${SMOKE_TIMEOUT:-600}"

failed=0
smoke() {  # smoke <SMBIOS product> <yes|no: expects the 4096x2304 parameter>
    echo "::group::QEMU smoke test, SMBIOS product $1 (panel parameter expected: $2)"
    if docker run --rm ${kvm[@]+"${kvm[@]}"} -v "$repo":/work \
            -e SMOKE_PRODUCT="$1" -e SMOKE_EXPECT_VIDEO="$2" \
            rd-image-builder:native /work/image/scripts/qemu-smoke.sh "/work/$rel" "$timeout_s"; then
        echo "PASS $1"
    else
        echo "FAIL $1"; failed=1
    fi
    echo "::endgroup::"
}

smoke "iMac18,2" yes
smoke "iMac19,2" yes
smoke "iMac19,1" no
smoke "iMac18,1" no

[ "$failed" = 0 ] && echo "all smoke tests passed" || echo "some smoke tests FAILED"
exit "$failed"
