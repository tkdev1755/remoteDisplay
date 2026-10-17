#!/usr/bin/env python3
"""Run ON the iMac: per-core CPU split (user/sys/irq/softirq/idle) over N seconds.
  python3 cpuutil.py [seconds]"""
import sys, time
def snap():
    r = {}
    for l in open("/proc/stat"):
        if l.startswith("cpu") and l[3].isdigit():
            f = l.split(); r[int(f[0][3:])] = list(map(int, f[1:9]))
    return r
a = snap(); time.sleep(float(sys.argv[1])); b = snap()
out = []
for c in sorted(a):
    d = [y - x for x, y in zip(a[c], b[c])]; t = sum(d) or 1
    # user nice system idle iowait irq softirq steal
    out.append(f"cpu{c}: usr {100*(d[0]+d[1])/t:.0f}% sys {100*d[2]/t:.0f}% irq {100*d[5]/t:.0f}% soft {100*d[6]/t:.0f}% idle {100*d[3]/t:.0f}%")
print("   " + " | ".join(out))
