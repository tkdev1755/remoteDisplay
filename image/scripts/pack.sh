#!/usr/bin/env bash
# Turns the mkosi root tree into the final disk image:
#
#   GPT, one FAT32 partition "RDISPLAY" (EFI System type) holding
#     EFI/BOOT/BOOTX64.EFI   standalone GRUB (the path Apple firmware boots)
#     vmlinuz, initrd.img    Debian kernel + initramfs (with live-boot)
#     live/filesystem.squashfs  the whole system; "toram" copies it to RAM at boot,
#                               so the USB drive is only needed until boot completes.
#
# Needs no loop devices or root privileges beyond reading the tree.
set -euo pipefail

cd "$(dirname "$0")/.."

ROOT_TREE="${ROOT_TREE:?ROOT_TREE must point at the mkosi root tree}"
PROFILE="${PROFILE:-release}"
VERSION="${VERSION:-unknown}"
SDE="${SOURCE_DATE_EPOCH:-0}"
NAME="remotedisplay-${VERSION}-${PROFILE}${NAME_SUFFIX:-}"

OUT=out
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

# --- kernel and initramfs ------------------------------------------------------
kernel="$(ls -1 "$ROOT_TREE"/boot/vmlinuz-* | sort -V | tail -1)"
initrd="$(ls -1 "$ROOT_TREE"/boot/initrd.img-* | sort -V | tail -1)"
echo "kernel: $(basename "$kernel")   initrd: $(basename "$initrd")"

stage="$WORK/stage"
mkdir -p "$stage/live" "$stage/EFI/BOOT"
cp "$kernel" "$stage/vmlinuz"
cp "$initrd" "$stage/initrd.img"

# --- system image --------------------------------------------------------------
echo "==> squashfs"
mksquashfs "$ROOT_TREE" "$stage/live/filesystem.squashfs" \
    -comp zstd -Xcompression-level 19 -b 256K -noappend -no-xattrs \
    -all-root \
    -wildcards -e 'boot/*' 'var/cache/*' 'var/lib/apt/lists/*' >/dev/null

# --- bootloader ----------------------------------------------------------------
# No live-media= / live-media-timeout=: in live-boot the timeout is a fixed delay *before*
# autodetection starts (measured: +20 s of pure waiting), and without live-media= it scans
# removable drives first. LIVE_MEDIA_ARGS exists only to compare variants.
cmdline="boot=live toram live-media-path=/live ${LIVE_MEDIA_ARGS-}"
grub_extra=""
if [ "$PROFILE" = dev ]; then
    cmdline="$cmdline systemd.show_status=1 loglevel=4 console=tty0 console=ttyS0,115200"
    grub_extra=$'serial --speed=115200\nterminal_input console serial\nterminal_output console serial'
else
    cmdline="$cmdline quiet loglevel=3"
fi

# Panel mode: the 21.5" 4K iMacs (iMac18,2 and iMac19,2) have a 4096x2304 panel, but their EDID only
# advertises 3840x2160. The `video=` parameter adds the native mode, exactly as the Pop!_OS install
# did. Only for those models: on a different panel it could give a black screen. The model name comes
# from SMBIOS, and `rd-extra.cfg` on the stick can set `rd_video` or `rd_extra` without rewriting the image.
# Syntax is <w>x<h>[M][R][@<hz>]: `R` (reduced blanking) must come BEFORE `@`, otherwise the kernel ignores
# it and uses the full CVT timing (813 MHz pixel clock, more than the eDP link carries -> corrupt picture).
cat > "$WORK/grub.cfg" <<EOF
set timeout=0
set default=0
$grub_extra
smbios --type 1 --get-string 5 --set rd_product
set rd_video=""
if [ "\$rd_product" = "iMac18,2" -o "\$rd_product" = "iMac19,2" ]; then
    set rd_video="video=eDP-1:4096x2304MR@60"
fi
set rd_extra=""
menuentry "remoteDisplay" {
    search --no-floppy --label RDISPLAY --set=root
    if [ -f (\$root)/rd-extra.cfg ]; then source (\$root)/rd-extra.cfg; fi
    linux /vmlinuz $cmdline rd_product="\$rd_product" \$rd_video \$rd_extra
    initrd /initrd.img
}
EOF

grub-mkstandalone -O x86_64-efi -d /opt/grub-amd64/usr/lib/grub/x86_64-efi -o "$stage/EFI/BOOT/BOOTX64.EFI" \
    --modules="part_gpt fat normal linux search search_label echo serial terminal all_video efi_gop smbios test regexp configfile" \
    "boot/grub/grub.cfg=$WORK/grub.cfg"

find "$stage" -exec touch -h -d "@$SDE" {} +

# --- disk image ----------------------------------------------------------------
used_kib="$(du -sk "$stage" | cut -f1)"
part_mib=$(( used_kib / 1024 + 96 ))          # 96 MiB of slack
total_mib=$(( part_mib + 2 ))                 # 1 MiB GPT head + 1 MiB backup GPT
img="$OUT/$NAME.img"
echo "==> $img (${total_mib} MiB)"

rm -f "$img"
truncate -s "${total_mib}M" "$img"
sfdisk "$img" >/dev/null <<EOF
label: gpt
label-id: 5244b150-0000-4000-8000-000000000001
unit: sectors

start=2048, size=$(( part_mib * 2048 )), type=U, name="RDISPLAY", uuid=5244b150-0000-4000-8000-000000000002
EOF

fat="$WORK/rdisplay.fat"
truncate -s "${part_mib}M" "$fat"
mkfs.vfat -F 32 -n RDISPLAY -i 52440001 "$fat" >/dev/null
MTOOLS_SKIP_CHECK=1 mcopy -i "$fat" -s -m "$stage"/* ::/
dd if="$fat" of="$img" bs=1M seek=1 conv=notrunc status=none

# --- artifacts -----------------------------------------------------------------
zstd -q -19 -T0 --force "$img" -o "$img.zst"
img_sha="$(sha256sum "$img" | cut -d' ' -f1)"
zst_sha="$(sha256sum "$img.zst" | cut -d' ' -f1)"

cat > "$OUT/$NAME.manifest.json" <<EOF
{
  "name": "remotedisplay",
  "version": "$VERSION",
  "profile": "$PROFILE",
  "source_date_epoch": $SDE,
  "image": "$(basename "$img")",
  "image_bytes": $(stat -c %s "$img"),
  "image_sha256": "$img_sha",
  "compressed": "$(basename "$img.zst")",
  "compressed_bytes": $(stat -c %s "$img.zst"),
  "compressed_sha256": "$zst_sha",
  "kernel": "$(basename "$kernel")",
  "squashfs_bytes": $(stat -c %s "$stage/live/filesystem.squashfs"),
  "initrd_bytes": $(stat -c %s "$stage/initrd.img")
}
EOF

echo "squashfs: $(( $(stat -c %s "$stage/live/filesystem.squashfs") / 1048576 )) MiB, initrd: $(( $(stat -c %s "$stage/initrd.img") / 1048576 )) MiB"
