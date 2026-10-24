# image — the receiver system image

Reproducible build of the bootable USB image that turns an Intel iMac into a
remoteDisplay receiver. **Work in progress.**

**Status.** Tested on one machine, a 2017 21.5" 4K iMac (`iMac18,2`) over Thunderbolt 3:

- The `dev` profile boots from a USB stick in about 32 s (picker to picture) and streams at
  3840x2160 and at the panel's native 4096x2304 (59-60 fps, no packet loss, about 14-23 ms
  measured receiver-side).
- The `release` profile boots and streams on the same machine. A build that stopped the
  systemd first-boot wizard from blocking boot was produced afterwards and has **not** yet
  been re-tested on the iMac.
- Other models (2015-2019, 27") and the 5K path are untested. CI only checks that the
  image boots in QEMU (and the model-dependent panel parameter), not the GPU or Thunderbolt.

## What the image is

A GPT disk image with one FAT32 partition (`RDISPLAY`, EFI System type):

| File | Role |
|---|---|
| `EFI/BOOT/BOOTX64.EFI` | standalone GRUB, the fallback path Apple firmware boots |
| `vmlinuz`, `initrd.img` | Debian kernel + initramfs (with `live-boot`) |
| `live/filesystem.squashfs` | the whole system, zstd-compressed |

`toram` makes the initramfs copy the squashfs to RAM, so the drive is only read once
at boot (sequential, ~130 MB/s measured on the test drives) and a flaky drive cannot
take the system down afterwards. The root filesystem is read-only plus a RAM overlay;
logs are volatile and capped; core dumps are disabled.

Inside: Debian 13 (trixie), `systemd-networkd` (static `10.0.0.1/16`, MTU 65 520 on
`thunderbolt0`), a default-drop `nftables` policy (only the Mac, only UDP 5000/5002),
`rd_helper` and `receiver_app` in `/opt/remotedisplay`, and `rd-helper.service`
**without** the `network-online.target` dependency.

## Building

Needs Docker and the Dart SDK (rd_helper is cross-compiled on the host).

```bash
./scripts/build.sh                 # dev profile (SSH key + serial console)
PROFILE=release ./scripts/build.sh # what would be shipped
```

Output goes to `out/`: `.img`, `.img.zst`, `manifest.json` (version, sizes, SHA-256).
mkosi builds the root tree inside a Linux container (`builder/Containerfile`);
`scripts/pack.sh` assembles the disk image.

The `dev` profile adds `openssh-server` (key only, from `DEV_SSH_KEY` or
`~/.ssh/id_ed25519.pub`), a serial console, and a few diagnostic tools. Never ship it.

Reproducibility: the Debian packages come from the snapshot.debian.org snapshot named in
`SNAPSHOT` (one line, currently a date-time id), so a build next month installs the same
package versions. `SNAPSHOT=<id> ./scripts/build.sh` overrides it, `SNAPSHOT=none` uses
the latest packages. To update the pin: pick a recent id from
`https://snapshot.debian.org/archive/debian/?year=YYYY&month=M`, put it in `SNAPSHOT`,
rebuild, and re-test on the iMac. `SOURCE_DATE_EPOCH` defaults to the last commit time.

## Testing

```bash
docker run --rm -v "$PWD/..":/work rd-image-builder:native \
    /work/image/scripts/qemu-smoke.sh /work/image/out/remotedisplay-<version>-dev.img
```

`scripts/ci-smoke.sh <image>` runs that test once per simulated iMac model (SMBIOS
product name), to check that the 4096x2304 panel parameter is only added on the 21.5" 4K
models. It is what CI runs (`.github/workflows/image.yml`: build the dev image on a native
amd64 runner, then the four boots, using KVM when available; the image is kept as a
7-day artifact for testing only). Hardware checks stay manual.

(or run `scripts/qemu-smoke.sh` directly if QEMU is installed locally.) It boots the
image as a USB drive in QEMU/OVMF, waits for the serial login prompt, then checks the
output of `rd-doctor`, which the dev image runs on the console after boot: root is a
RAM overlay, the squashfs was copied to RAM (`toram`), the journal is volatile, the
firewall is loaded, `rd-helper` is active, no failed units. `rd-doctor` is also in the
release image (`/usr/local/sbin/rd-doctor`) and will become the support tool.

This validates firmware → GRUB → kernel → live-boot → systemd, not the GPU or the
Thunderbolt link: those need the real hardware.

## Known unknowns

- Not booted on an iMac yet (default-boot behaviour, firmware USB read speed).
- The QEMU smoke test cannot exercise the GPU (Mesa/LLVM stack), `thunderbolt0`, or
  the receiver itself — only the boot chain, RAM loading, firewall and services.
- Latency must be re-measured: the 20–30 ms figure was obtained on Pop!_OS with its
  own kernel and Mesa, Debian's versions differ.
- `receiver_app` is built `PORTABLE=ON` (no `-march=native`); the gain of a native
  build is still to be measured.
