#!/usr/bin/env python3
"""Run ON the iMac (root): sniff the remoteDisplay stream on thunderbolt0 and report the
frame cadence (frames/s, inter-arrival jitter, burst duration first->last packet).
  python3 arrivals.py [seconds]"""
import socket, struct, sys, time, statistics
IFACE = "thunderbolt0"; SECS = float(sys.argv[1]) if len(sys.argv) > 1 else 10
s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(3))
s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 256 * 1024 * 1024)
s.bind((IFACE, 0)); s.settimeout(1.0)
HDR = struct.Struct("<IHHHHI")
first, last, tot = {}, {}, {}
meta = None
end = time.monotonic() + SECS
while time.monotonic() < end:
    try: pkt = s.recv(70000)
    except socket.timeout: continue
    t = time.monotonic()
    if len(pkt) < 14 + 20 + 8 + HDR.size or pkt[12:14] != b"\x08\x00" or pkt[23] != 17: continue
    ihl = (pkt[14] & 0x0F) * 4
    if struct.unpack("!H", pkt[14 + ihl + 2:14 + ihl + 4])[0] != 5000: continue
    fid, cid, tc, w, h, size = HDR.unpack_from(pkt, 14 + ihl + 8)
    first.setdefault(fid, t); last[fid] = t; tot[fid] = tc; meta = (w, h, size, tc)
ids = sorted(first)
if len(ids) < 10: print("too few frames", len(ids)); sys.exit()
gaps = [b - a for a, b in zip(ids, ids[1:]) if b - a > 1]
iv = [(first[b] - first[a]) * 1000 for a, b in zip(ids, ids[1:]) if b - a == 1]
span = first[ids[-1]] - first[ids[0]]
print(f"stream: {meta[0]}x{meta[1]}  frame {meta[2]/1e6:.1f} MB  {meta[3]} packets/frame")
print(f"frames seen {len(ids)} over {span:.1f}s -> {len(ids)/span:.1f} frames/s | frameId jumps (missing ids): {sum(g-1 for g in gaps)}")
iv.sort(); n = len(iv)
p = lambda q: iv[int(q * (n - 1))]
print(f"inter-arrival ms: p5 {p(.05):.1f} p25 {p(.25):.1f} median {p(.5):.1f} p75 {p(.75):.1f} p95 {p(.95):.1f} min {iv[0]:.1f} max {iv[-1]:.1f}")
hist = {}
for v in iv: hist[int(v)] = hist.get(int(v), 0) + 1
print("histogram (ms bucket: count):", " ".join(f"{k}:{hist[k]}" for k in sorted(hist) if hist[k] >= max(2, n // 100)))
bd = sorted((last[i] - first[i]) * 1000 for i in ids)
print(f"burst (first->last packet) ms: median {bd[len(bd)//2]:.1f} p95 {bd[int(len(bd)*.95)]:.1f} max {bd[-1]:.1f}")
