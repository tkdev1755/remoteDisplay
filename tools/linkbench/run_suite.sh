#!/usr/bin/env bash
# Runs the whole link test battery from the sender (the Mac) against the receiver.
# On the receiver, first start:   iperf3 -s      and      ./framebench recv
#
# usage: ./run_suite.sh <receiver-ip> [seconds-per-test]
set -u
IP=${1:?usage: ./run_suite.sh <receiver-ip> [seconds-per-test]}
SECS=${2:-10}
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/results/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
cd "$HERE" || exit 1

# --- preflight -------------------------------------------------------------
cc -O2 -o framebench framebench.c -lm || exit 1
if [ "$(uname)" = "Darwin" ]; then
    maxdgram=$(sysctl -n net.inet.udp.maxdgram)
    if [ "$maxdgram" -lt 65535 ]; then
        echo "net.inet.udp.maxdgram is $maxdgram: 65 KB datagrams will be refused."
        echo "Run:  sudo sysctl -w net.inet.udp.maxdgram=65535   (reset at reboot), then retry."
        exit 1
    fi
fi
command -v iperf3 >/dev/null || { echo "iperf3 is missing (brew install iperf3)"; exit 1; }
./linkinfo.sh > "$OUT/linkinfo_sender.txt" 2>&1
echo "Results go to $OUT"

run_iperf() { # name, then iperf3 arguments
    local name=$1; shift
    echo "iperf3 $name"
    iperf3 -c "$IP" -t "$SECS" -J "$@" > "$OUT/iperf_$name.json" 2>&1
    sleep 1
}

# --- 1. raw throughput (iperf3) -----------------------------------------
run_iperf tcp_1stream
run_iperf tcp_4streams -P 4
run_iperf tcp_1stream_reverse -R
for rate in 2 4 6 8 10 12 15 20 25; do
    run_iperf "udp_${rate}G" -u -b "${rate}G" -l 65000
done

# --- 2. remoteDisplay-like traffic (framebench) ---------------------------
FB="$OUT/framebench.txt"
bench() { # label, frame bytes, fps, chunk
    echo "framebench $1"
    ./framebench send "$IP" --label "$1" --frame-bytes "$2" --fps "$3" --chunk "$4" --seconds "$SECS" >> "$FB"
    sleep 1
}
NV12_4K=$((4096 * 2304 * 3 / 2))   # today's frames
BC7_4K=$((4096 * 2304))            # 1 byte per pixel
BC7_5K=$((5120 * 2880))
NV12_5K=$((5120 * 2880 * 3 / 2))

for f in "4k_nv12 $NV12_4K" "4k_bc7 $BC7_4K" "5k_bc7 $BC7_5K" "5k_nv12 $NV12_5K"; do
    set -- $f
    bench "${1}_60fps" "$2" 60 65000
    bench "${1}_max" "$2" 0 65000
done
# Effect of the datagram size on today's frames.
for c in 1400 8000 32000; do
    bench "4k_nv12_60fps_chunk$c" "$NV12_4K" 60 "$c"
done

# --- 3. summary -------------------------------------------------------------
python3 - "$OUT" <<'EOF'
import csv, glob, json, os, sys
out = sys.argv[1]

rows = []
for path in sorted(glob.glob(os.path.join(out, "iperf_*.json"))):
    name = os.path.basename(path)[6:-5]
    try:
        d = json.load(open(path))
    except Exception:
        rows.append({"test": name, "error": "unreadable (see json)"}); continue
    if "error" in d:
        rows.append({"test": name, "error": d["error"]}); continue
    end = d["end"]
    if "sum_received" in end:   # TCP
        rows.append({"test": name, "gbps": round(end["sum_received"]["bits_per_second"] / 1e9, 2)})
    else:                       # UDP
        s = end["sum"]
        rows.append({"test": name, "gbps": round(s["bits_per_second"] / 1e9, 2),
                     "lost_pct": round(s.get("lost_percent", 0), 3),
                     "jitter_ms": round(s.get("jitter_ms", 0), 3)})
with open(os.path.join(out, "summary_iperf.csv"), "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=["test", "gbps", "lost_pct", "jitter_ms", "error"])
    w.writeheader(); w.writerows(rows)

fb = []
fb_path = os.path.join(out, "framebench.txt")
if os.path.exists(fb_path):
    for line in open(fb_path):
        if line.startswith("label="):
            fb.append(dict(kv.split("=", 1) for kv in line.split()))
if fb:
    with open(os.path.join(out, "summary_framebench.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(fb[0].keys()))
        w.writeheader(); w.writerows(fb)

print("\n== iperf3 ==")
for r in rows:
    print(f"{r['test']:<24} {r.get('gbps', ''):>7} Gbit/s  loss {r.get('lost_pct', '-')}%  {r.get('error', '')}")
print("\n== framebench ==")
cols = ["label", "delivered_pct", "achieved_fps", "goodput_gbps", "lat_p50_ms", "lat_p99_ms", "burst_p50_ms"]
print("  ".join(f"{c:>14}" for c in cols))
for r in fb:
    print("  ".join(f"{r.get(c, ''):>14}" for c in cols))
EOF
