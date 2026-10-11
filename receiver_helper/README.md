# receiver_helper — headless receiver daemon

Supervises [`receiver_app`](../receiver_code) (start, stop, automatic restart)
and drives the receiving machine's panel. It is the only supported helper,
designed from the start for **KMS/DRM without an X/Wayland server** (no
GTK/Flutter dependency — a Dart CLI compiled to a single native binary).

## What it does

| Feature | Implementation |
|---|---|
| Starts / stops / suspends / resumes the `receiver_app` process | ✅ + automatic restart on crash |
| Listens on UDP `:5002`: `SLP_DETECTED`, `CONN_OK`, `BRIGHTNESS:<n>` | ✅ |
| Panel off | stops the receiver + `echo 4 > fbN/blank` (real DPMS off) |
| Panel on | `echo 0 > fbN/blank` + restarts the receiver + reapplies brightness |
| Brightness | `brightnessctl`, falling back to `/sys/class/backlight` |
| Visual overlay (status / brightness bar) | ❌ *(not done — would require rendering inside the SDL receiver)* |

## Build

This folder (the helper) needs the Dart SDK to compile, but **not** on the
target machine: compile on a development machine and deploy only the
resulting binary (see "Installing as a service" below).

```bash
./build.sh          # -> ./rd_helper (standalone native binary)
```

[`../receiver_code`](../receiver_code) (the display program itself) is built
separately, in C++ — see its own README.

## Usage

```bash
sudo SDL_VIDEODRIVER=kmsdrm ./rd_helper --receiver /path/to/receiver_app
```

Options: `--receiver <path>`, `--port <n>` (default 5002), `--no-debug`,
`-- <args>` passed as-is to the receiver (e.g. `-- --width 3840 --height 2160`).

If `--receiver` is omitted, the receiver binary is looked up in this order:
`$RD_RECEIVER_BIN`, next to `rd_helper`, then `/opt/remotedisplay/`, `/usr/local/bin/`.

## Installing as a service (appliance)

```bash
sudo install -Dm755 rd_helper                     /opt/remotedisplay/rd_helper
sudo install -Dm755 ../receiver_code/build/receiver_app /opt/remotedisplay/receiver_app
sudo setcap 'cap_sys_nice=eip'          /opt/remotedisplay/receiver_app
sudo install -Dm644 systemd/rd-helper.service /etc/systemd/system/rd-helper.service
# edit the paths in the .service file if needed
sudo systemctl disable --now gdm        # frees the console / DRM master
sudo systemctl daemon-reload
sudo systemctl enable --now rd-helper
```

Logs: `journalctl -u rd-helper -f` (includes the `[recv]` output of the C++ process).

## Notes / known limitations

- **Panel off = real DPMS off** through `drm_fb_helper`: `bl_power` is ignored by
  `amdgpu` on this iMac and the panel has a minimum backlight level, so
  `brightness 0` does not turn it off. Only `echo 4 > /sys/class/graphics/fbN/blank`
  (once `amdgpudrmfb` is master and the receiver is stopped) truly cuts the panel
  and its backlight. As a result, waking up performs a mode-set (~1–2 s), like
  any monitor coming out of standby.
- `/sys/class/drm/*/dpms` is read-only on this kernel — not usable.
- `rd_helper` must run as **root**: the child receiver needs to be DRM master
  without a logind session, and writing to `fbX/blank` / `backlight` requires
  privileges.
