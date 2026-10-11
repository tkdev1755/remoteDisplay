# receiver_code

The display program (`receiver_app`): SDL2, KMS/DRM, two threads
(network + display). **Standalone** build, no Flutter/GTK dependency.

## Dependencies

```bash
sudo apt-get install -y build-essential cmake pkg-config libsdl2-dev
```

## Build

With CMake (recommended — also used to package releases):

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
./build/receiver_app --debug
```

Reproducible build, to deploy the binary on a different machine from the one
that compiles it (disables `-march=native`):

```bash
cmake -S . -B build -DPORTABLE=ON
```

Or as a one-liner, to iterate quickly during development:

```bash
g++ -o receiver_app receiver.cpp -lSDL2 -O3 -march=native -pthread
```

## Running

```bash
sudo SDL_VIDEODRIVER=kmsdrm ./receiver_app --debug
```

Requires `root`, or `sudo setcap 'cap_sys_nice=eip' receiver_app` to get
real-time priority (`SCHED_FIFO`) without running as root.

Options: `--debug`, `--width <px> --height <px>` (forces a specific display
mode; without it, the receiver automatically follows the stream's resolution).

## Latency: flags and measurements

| Flag | Effect |
|---|---|
| *(default)* | KMS double buffering + late-latching (see below) |
| `--no-latelatch` | disables late-latch pacing (back to "present as soon as ready") |
| `--triple-buffer` | back to SDL's default triple buffering (+1 frame of latency) |

- **Double buffering**: `SDL_VIDEO_DOUBLE_BUFFER=1` — SDL waits for the vblank
  right after posting the flip, instead of leaving a third frame in the queue.
- **Late-latching**: the display thread sleeps until *(next vblank − budget)*,
  then takes the freshest frame, renders it and presents it just in time. The
  budget (render time + margin) adjusts itself; if `RenderPresent` does not block
  on the vblank, the mechanism disables itself (logged with `⚠️`).
- **`MSG_WAITFORONE`** on `recvmmsg`: without it, the end of a frame stayed
  stuck in the socket until the next frame arrived.

With `--debug`, one line per second breaks down where the time goes (in ms,
average and max in parentheses). The log labels are in French:

```
[LAT ms moy(max)] réseau 8.9(9.4) | boîte 3.1(7.9) | rendu 2.6(3.0) | vblank 2.1(2.4) | TOTAL 16.7(21.0) | budget 4.7
```

- **réseau** (network): first chunk received → frame complete (transmission + reassembly)
- **boîte** (mailbox): frame complete → picked up by the display thread
- **rendu** (render): texture upload + CPU rendering
- **vblank**: waiting for the flip (≈ the margin left by late-latching)
- **TOTAL**: first chunk received → flip done. This is the receiver-side latency,
  excluding capture and the panel's scan-out (~16 ms from top to bottom, unavoidable).

## Normal use

In practice this binary is not started by hand:
[`../receiver_helper`](../receiver_helper) (the headless `rd_helper` daemon)
supervises it — start, stop, sleep/wake, automatic restart.
