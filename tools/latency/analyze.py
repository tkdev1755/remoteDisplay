#!/usr/bin/env python3
"""Decode two binary time counters from a slow-motion video and report the lag between them.

Both screens display tools/latency/counter.html. In every video frame we read the
16-bit millisecond value shown on each screen; lag = left - right (ms), where
left is the reference screen (the Mac) and right is the iMac. Pure Python + ffmpeg.

  analyze.py --preview video.mov out.png        # grab a frame to pick the regions
  analyze.py video.mov --left X,Y,W,H --right X,Y,W,H [--json out.json]
  analyze.py --selftest                         # synthetic video, checks the pipeline
"""
import argparse, json, math, statistics, subprocess, sys, tempfile, os

NB = 18  # cells: white ref, black ref, 16 data bits


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, **kw)


def probe(video):
    out = run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
               "stream=r_frame_rate,avg_frame_rate,nb_frames,width,height",
               "-of", "json", video]).stdout
    s = json.loads(out)["streams"][0]
    num, den = (s["avg_frame_rate"] if s["avg_frame_rate"] != "0/0" else s["r_frame_rate"]).split("/")
    return float(num) / float(den), s


def read_cells(video, roi, limit=None):
    """Return per-frame cell values (NB bytes each).

    The camera sees the bar at an angle, so cells are not equally wide in the video. We read the
    region as one row of pixels per frame, find the real cell boundaries from the edges seen across
    all frames (fit x_k = a + b*k + c*k^2 on the NB+1 boundaries) and sample each cell at its centre.
    """
    x, y, w, h = roi
    vf = f"crop={w}:{h}:{x}:{y},scale={w}:1:flags=area,format=gray"
    cmd = ["ffmpeg", "-v", "error", "-i", video, "-vf", vf]
    if limit:
        cmd += ["-frames:v", str(limit)]
    data = run(cmd + ["-f", "rawvideo", "-"]).stdout
    rows = [data[i:i + w] for i in range(0, len(data) - w + 1, w)]
    if len(rows) < 10:
        return []
    bounds = find_boundaries(rows, w)
    out = []
    for r in rows:
        cells = []
        for k in range(NB):
            lo, hi = bounds[k], bounds[k + 1]
            c, half = (lo + hi) / 2, (hi - lo) * 0.25
            a, b = max(0, int(c - half)), min(w, int(c + half) + 1)
            seg = r[a:b] or r[int(c):int(c) + 1]
            cells.append(sum(seg) // len(seg))
        out.append(bytes(cells))
    return out


def find_boundaries(rows, w):
    """Fit the NB+1 cell boundaries from the per-frame horizontal edge strength."""
    m, d = len(rows), 3
    e = [0.0] * w
    step = max(1, m // 400)  # a few hundred frames are plenty
    sel = rows[::step]
    for r in sel:
        for xx in range(d, w - d):
            e[xx] += abs(r[xx + d] - r[xx - d])
    # max-pool by +-2 px so a slightly misplaced boundary still scores
    ep = [max(e[max(0, i - 2):i + 3]) for i in range(w)]
    best, best_s = None, -1
    for a in range(0, int(0.18 * w), max(1, w // 200)):
        for rt in range(int(0.82 * w), w + 1, max(1, w // 200)):
            width = rt - a
            if width < NB * 8:
                continue
            for c in (-0.5, -0.25, 0.0, 0.25, 0.5):
                cell = width / NB
                curv = c * cell / NB  # total drift of +-0.5 cell over the bar
                xs = [a + width * k / NB + curv * k * (k - NB) for k in range(NB + 1)]
                if xs[0] < 0 or xs[-1] > w - 1:
                    continue
                sc = sum(ep[int(round(v))] for v in xs)
                if sc > best_s:
                    best_s, best = sc, xs
    return best


def decode(frame, min_contrast=60):
    white, black = frame[0], frame[1]
    if white - black < min_contrast:
        return None
    thr = (white + black) / 2
    v = 0
    for b in frame[2:]:
        v = (v << 1) | (1 if b > thr else 0)
    return v


def signed_diff(a, b):
    d = (a - b) % 65536
    return d - 65536 if d >= 32768 else d


def pct(sorted_vals, p):
    k = (len(sorted_vals) - 1) * p / 100
    f, c = math.floor(k), math.ceil(k)
    return sorted_vals[f] if f == c else sorted_vals[f] + (sorted_vals[c] - sorted_vals[f]) * (k - f)


def clean(seq, win=7, tol=24):
    """Flag decoded values that disagree with the median of their temporal neighbours.

    The counter only moves forward, so a value far from its neighbours' median is a bad
    read (camera exposure straddling a refresh, rolling shutter). Returns a list of bools.
    """
    u, prev, wraps = [], None, 0
    for v in seq:
        if v is None:
            u.append(None)
            continue
        if prev is not None and prev - v > 32768:
            wraps += 1
        prev = v
        u.append(v + 65536 * wraps)
    ok = []
    half = win // 2
    for i, v in enumerate(u):
        if v is None:
            ok.append(False)
            continue
        near = [x for x in u[max(0, i - half):i + half + 1] if x is not None]
        med = statistics.median(near)
        ok.append(abs(v - med) <= tol)
    return ok


def analyze(video, left, right, outlier=300):
    fps, _ = probe(video)
    L, R = read_cells(video, left), read_cells(video, right)
    n = min(len(L), len(R))
    A = [decode(L[i]) for i in range(n)]
    B = [decode(R[i]) for i in range(n)]
    okA, okB = clean(A), clean(B)
    lags, invalid = [], 0
    per_sec = {}
    for i in range(n):
        if not (okA[i] and okB[i]):
            invalid += 1
            continue
        d = signed_diff(A[i], B[i])
        if abs(d) > outlier:
            invalid += 1
            continue
        lags.append(d)
        per_sec.setdefault(int(i / fps), []).append(d)
    if not lags:
        raise SystemExit("no valid frame decoded: check the --left/--right regions (use --preview)")
    s = sorted(lags)
    hist = {}
    for d in lags:
        k = int(round(d / 8.0)) * 8
        hist[k] = hist.get(k, 0) + 1
    res = {
        "video": os.path.basename(video), "camera_fps": round(fps, 2), "frames": n,
        "valid": len(lags), "invalid": invalid,
        "lag_ms": {"mean": round(statistics.fmean(lags), 2), "median": round(statistics.median(lags), 2),
                   "stdev": round(statistics.pstdev(lags), 2), "p5": round(pct(s, 5), 1),
                   "p25": round(pct(s, 25), 1), "p75": round(pct(s, 75), 1),
                   "p95": round(pct(s, 95), 1), "min": s[0], "max": s[-1]},
        "histogram_8ms": {str(k): hist[k] for k in sorted(hist) if hist[k] >= max(2, len(lags) // 100)},
        "per_second_mean": [round(statistics.fmean(v), 1) for _, v in sorted(per_sec.items())],
    }
    return res


def probe_rois(video, left, right, n=24):
    """Decode the first frames with both regions: tells whether the regions are well placed."""
    L, R = read_cells(video, left, n), read_cells(video, right, n)
    for name, cells in (("left ", L), ("right", R)):
        vals, bad = [], 0
        for c in cells:
            v = decode(c)
            bad += v is None
            vals.append(v)
        contrast = [c[0] - c[1] for c in cells]
        print(f"{name}: contrast min {min(contrast)} / max {max(contrast)} | undecodable {bad}/{len(cells)} | first values {vals[:6]}")
    ds = [signed_diff(decode(a), decode(b)) for a, b in zip(L, R) if decode(a) is not None and decode(b) is not None]
    if ds:
        print(f"quick lag estimate on {len(ds)} frames: median {statistics.median(ds)} ms (rough, use the full analysis)")


def show(res):
    l = res["lag_ms"]
    print(f"{res['video']}: {res['valid']}/{res['frames']} frames decoded ({res['invalid']} rejected), camera {res['camera_fps']} fps")
    print(f"lag (iMac behind Mac): mean {l['mean']} ms | median {l['median']} | stdev {l['stdev']} | "
          f"p5 {l['p5']} | p95 {l['p95']} | range {l['min']}..{l['max']}")
    print("histogram (8 ms bins):", res["histogram_8ms"])
    print("per-second mean:", res["per_second_mean"][:40])


def selftest():
    W, H, FPS, LAG = 720, 120, 240, 33.0
    cell = (W // 2) // NB
    tmp = tempfile.mkdtemp()
    out = os.environ.get("SELFTEST_VIDEO") or os.path.join(tmp, "synthetic.mp4")
    ff = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "gray",
                           "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-", "-c:v", "libx264",
                           "-crf", "18", "-pix_fmt", "yuv420p", out], stdin=subprocess.PIPE)

    def bar(ms):
        v = int(ms) % 65536
        cells = [255, 0] + [255 if (v >> (15 - b)) & 1 else 0 for b in range(16)]
        row = bytearray()
        for c in cells:
            row += bytes([c]) * cell
        row += bytes([32]) * (W // 2 - len(row))
        return bytes(row)

    base_delay = 25.0  # the reference screen's own pipeline delay
    period = 1000 / 60
    for i in range(FPS * 6):
        t = i * 1000 / FPS
        shown_left = math.floor((t - base_delay) / period) * period       # 60 Hz ticks
        shown_right = math.floor((t - base_delay - LAG) / period) * period
        line = bar(shown_left) + bar(shown_right)
        ff.stdin.write(line * H)
    ff.stdin.close(); ff.wait()
    w2 = W // 2
    res = analyze(out, (0, 0, w2, H), (w2, 0, w2, H))
    show(res)
    ok = abs(res["lag_ms"]["mean"] - LAG) < 4
    print("SELFTEST", "OK" if ok else f"FAILED (expected ~{LAG} ms)")
    sys.exit(0 if ok else 1)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("video", nargs="?")
    ap.add_argument("out_png", nargs="?")
    ap.add_argument("--left"); ap.add_argument("--right")
    ap.add_argument("--json"); ap.add_argument("--preview", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--probe", action="store_true", help="decode the first frames only, to check the regions")
    ap.add_argument("--at", default="2", help="preview: timestamp in seconds")
    a = ap.parse_args()
    if a.selftest:
        selftest()
    if not a.video:
        ap.error("video required")
    if a.preview:
        if not a.out_png:
            ap.error("preview needs an output PNG path")
        run(["ffmpeg", "-v", "error", "-y", "-ss", a.at, "-i", a.video, "-frames:v", "1", a.out_png])
        fps, s = probe(a.video)
        print(f"wrote {a.out_png}: {s['width']}x{s['height']} @ {fps:.1f} fps")
        return
    if not (a.left and a.right):
        ap.error("--left and --right regions are required (X,Y,W,H of each bar)")
    roi = lambda t: tuple(int(v) for v in t.split(","))
    if a.probe:
        probe_rois(a.video, roi(a.left), roi(a.right))
        return
    res = analyze(a.video, roi(a.left), roi(a.right))
    show(res)
    if a.json:
        json.dump(res, open(a.json, "w"), indent=2)


if __name__ == "__main__":
    main()
