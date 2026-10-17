# latency — how much later does the iMac show a frame than the Mac?

A camera-based, machine-readable version of the original stopwatch measurement.

**What it measures:** the delay between a frame appearing on the **Mac's own screen** and
the same frame appearing on the **iMac** (capture + encode-free copy + network + receiver
+ display), read from a 240 fps video. It is a *relative* figure: the Mac's own display
pipeline is the reference, so it is not absolute photon latency.

## How it works

`counter.html` shows the current time (`Date.now() mod 65536`, ms) as 16 big black/white
cells, plus one white and one black reference cell. It runs full screen on both displays.
`analyze.py` decodes the two counters in every frame of the video and reports
`lag = Mac − iMac` over thousands of frames (about 7 000 per 30 s at 240 fps), instead
of a handful of readings by eye.

## Protocol (do it the same way every time)

**Mac**
1. On AC power. Quit every app you do not need; Do Not Disturb on; no screen recording,
   no builds. Note anything left running.
2. Virtual display set to **3840×2160 @ 60 Hz** (the panel's native mode, so the
   receiver logs `Flux 3840x2160 == dalle : 1:1`). Fixed brightness.
3. remoteDisplay running as usual (menu-bar app + sender).

**iMac**
4. Booted for at least 2 minutes, `rd-doctor` healthy. Nothing else running.

**Screens**
5. Open `counter.html` in one browser (same clock for both windows), **full screen on both
   displays**: the Mac's own display and the virtual display shown on the iMac. Neither
   window may be hidden or in the background (browsers stop animating those).

**Camera**
6. Phone on a tripod, **240 fps slow motion**, both screens in frame with the bars at about
   the same height, no glare, lock focus and exposure. Slight defocus avoids moiré.

**Runs**
7. Let the counters run 60 s (warm-up: CPU/GPU clocks settle). Then record **3 × 30 s**
   without touching anything. After each run:

```bash
./collect.sh run1 45        # snapshot of both machines + receiver-side breakdown
```

**Analysis**
8. Copy the videos to the Mac, pick the regions, decode:

```bash
./analyze.py --preview run1.mov preview.png            # then read the two bars' X,Y,W,H
./analyze.py run1.mov --left X,Y,W,H --right X,Y,W,H --json run1.json
```

`--left` is the reference (Mac) bar, `--right` the iMac bar. Put the crop just around the
18 cells, not the whole screen.

## Reading the results

- Use the **median** first, then mean, p95 and stdev. The counters tick at 60 Hz, so each
  frame has about ±8 ms of quantization noise; the median over thousands of frames is
  much tighter. The synthetic self-test (`./analyze.py --selftest`, injected lag 33 ms)
  returns median 33.0, mean 31.5: expect up to ~±2 ms of bias on the mean.
- Differences between runs smaller than **~3 ms are not significant**. If the three
  medians differ by more than ~5 ms, conditions were not stable: compare the
  `collect.sh` snapshots (Mac load, CPU/GPU clocks, other processes).
- `receiver_summary.txt` gives the receiver's own breakdown (network / mailbox / render /
  vblank) for the same window, to see *where* a change landed. Its journal timestamps are
  unreliable (stdout is buffered) but the averages are fine.

## Experiments (change ONE thing at a time, 3 runs each)

| Variable | How |
|---|---|
| Baseline | as above |
| CPU governor | `cpupower frequency-set -g performance` on the iMac |
| GPU clocks | `echo high > /sys/class/drm/card0/device/power_dpm_force_performance_level` |
| Late-latch off | `receiver_app --no-latelatch` |
| Triple buffering | `receiver_app --triple-buffer` |
| Mac load | the same run with a CPU-heavy app open, to quantify its effect |

## Limits

- Relative to the Mac's own display; a 120 Hz Mac panel and a 60 Hz virtual display do
  not scan out in lock-step, which adds noise but no systematic bias over many frames.
- Capture time inside ScreenCaptureKit is included but not separated out; measuring it
  needs timestamps inside `sender.mm` (not done yet).

## Receiver-side diagnostics (run on the iMac)

The camera test gives the end-to-end figure; these explain *where* it comes from.

```bash
scp arrivals.py cpuutil.py root@10.0.0.1:/tmp/
ssh root@10.0.0.1 'python3 /tmp/cpuutil.py 10 & python3 /tmp/arrivals.py 10; wait'
```

- `arrivals.py`: frames/s actually arriving, spread of the inter-arrival time, and how long
  each frame's packets take (burst). A burst close to the 16.7 ms frame period means frames
  overlap and the display thread will skip some.
- `cpuutil.py`: per-core split. On the reference iMac all receive processing lands on one
  core (`soft` 55–80 %): that core is the one to watch.
- The receiver's own `[RX] Affichées/Produites` lines (journal) give displayed vs produced
  frames per second; a healthy run has them equal.
