#!/usr/bin/env bash
# Boots a (dev) image in QEMU/OVMF as a USB drive and waits for the serial login prompt.
# Checks that the whole chain works — firmware → GRUB → kernel → live-boot (toram) →
# systemd — and reports the time to login. It cannot test the GPU or Thunderbolt.
#
#   ./qemu-smoke.sh out/remotedisplay-<version>-dev.img [timeout-seconds]
#
# On an Apple Silicon host QEMU emulates x86 (TCG): expect a few minutes.
# Without a local QEMU, run it inside the builder container (it ships qemu + OVMF):
#   docker run --rm -v "$PWD/out":/out rd-image-builder:native /work/image/scripts/qemu-smoke.sh /out/<image>
set -euo pipefail

img="${1:?usage: qemu-smoke.sh <image> [timeout]}"
# SMOKE_PRODUCT fakes the SMBIOS model name; SMOKE_EXPECT_VIDEO=yes|no checks the 4096x2304 parameter.
PRODUCT="${SMOKE_PRODUCT:-iMac18,2}"; EXPECT_VIDEO="${SMOKE_EXPECT_VIDEO:-yes}"
timeout_s="${2:-420}"

command -v qemu-system-x86_64 >/dev/null || { echo "qemu not found (brew install qemu)"; exit 1; }

code=""
for f in "$(brew --prefix qemu 2>/dev/null || true)/share/qemu/edk2-x86_64-code.fd" \
         /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd; do
    [ -f "$f" ] && { code="$f"; break; }
done
[ -n "$code" ] || { echo "no OVMF firmware found"; exit 1; }

log="$(mktemp)"
qpid=""
trap '[ -z "$qpid" ] || kill "$qpid" 2>/dev/null || true; rm -f "$log"' EXIT

# accel=kvm:tcg uses KVM when /dev/kvm is available (CI runners) and falls back to emulation.
qemu-system-x86_64 -machine q35,accel=kvm:tcg -cpu max -m 4096 -smp 2 \
    -drive if=pflash,format=raw,readonly=on,file="$code" \
    -device qemu-xhci -drive if=none,id=stick,file="$img",format=raw,snapshot=on \
    -device usb-storage,drive=stick,bootindex=0,removable=on \
    -smbios "type=1,manufacturer=Apple Inc.,product=${PRODUCT//,/,,}" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -display none -serial file:"$log" -monitor none &
qpid=$!

start=$SECONDS
while (( SECONDS - start < timeout_s )); do
    grep -q "login:" "$log" 2>/dev/null && break
    kill -0 "$qpid" 2>/dev/null || { echo "QEMU exited early"; break; }
    sleep 3
done
elapsed=$(( SECONDS - start ))

fail=0
check() {  # check <description> <regex>
    local hit
    if hit="$(grep -m1 -E "$2" "$log" | tr -d '\r' | cut -c1-110)"; then echo "  ok    $1  [$hit]"; else echo "  FAIL  $1"; fail=1; fi
}
echo "console log after ${elapsed} s:"
check "login prompt reached"               "login:"
check "multi-user target reached"          "Reached target.*Multi-User"
# rd-doctor runs ~5 s after the target (dev profile) and prints its own verdict.
for _ in $(seq 1 20); do grep -q "RD-DOCTOR RESULT" "$log" && break; sleep 3; done
check "rd-doctor ran"                      "RD-DOCTOR RESULT"
check "  root is a RAM overlay"            "RD-DOCTOR ok    root filesystem is a RAM overlay"
check "  image copied to RAM (toram)"      "RD-DOCTOR ok    system image copied to RAM"
check "  journal volatile"                 "RD-DOCTOR ok    journal is volatile"
check "  networkd running"                 "RD-DOCTOR ok    systemd-networkd running"
check "  firewall loaded"                  "RD-DOCTOR ok    firewall loaded"
check "  rd-helper active"                 "RD-DOCTOR ok    rd-helper.service active"
check "  libGL / libOpenGL present"        "RD-DOCTOR ok    libGL / libOpenGL present"
check "  pinned SDL"                       "RD-DOCTOR ok    receiver uses the pinned SDL"
if [ "$EXPECT_VIDEO" = yes ]; then
    check "  panel mode parameter for $PRODUCT" "RD-DOCTOR grub:.*product=$PRODUCT video=video=eDP-1:4096x2304MR@60"
else
    check "  no panel parameter for $PRODUCT"   "RD-DOCTOR grub:.*product=$PRODUCT video=[[:cntrl:]]*\$"
fi
check "  receiver binary present"          "RD-DOCTOR ok    receiver binary present"
check "  no failed units"                  "RD-DOCTOR ok    no failed units"
grep -E "RD-DOCTOR (kernel|root|medium|memory|timeline|journal|uptime|info|FAIL|RESULT)" "$log" | tr -d '\r' | sed 's/^/    /'

if (( fail )); then
    echo "--- last console output ---"; tail -40 "$log"; exit 1
fi
echo "OK"
