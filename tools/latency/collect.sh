#!/usr/bin/env bash
# Snapshot of the test conditions on both machines, plus the receiver's own latency
# breakdown over the recording window. Run it right AFTER a recording.
#
#   ./collect.sh <label> [window-seconds]      e.g. ./collect.sh run1 45
#
# Needs SSH access to the iMac (default root@10.0.0.1, dedicated known_hosts file);
# override with RD_SSH="ssh -o ... user@host".
set -uo pipefail   # no -e: head(1) in pipes would abort the snapshot

label="${1:?usage: collect.sh <label> [window-seconds]}"
win="${2:-45}"
here="$(cd "$(dirname "$0")" && pwd)"
out="$here/results/$(date +%Y%m%d-%H%M%S)-$label"
mkdir -p "$out"

RD_SSH="${RD_SSH:-ssh -o BatchMode=yes -o ConnectTimeout=8 -o UserKnownHostsFile=$HOME/.ssh/known_hosts_remotedisplay -o StrictHostKeyChecking=accept-new root@10.0.0.1}"

{
  echo "## Mac"; sw_vers; sysctl -n hw.model machdep.cpu.brand_string
  echo "## power"; pmset -g batt | head -2; pmset -g therm 2>&1 | head -5
  echo "## load"; uptime
  echo "## top CPU consumers"; ps -Ao pcpu,comm -r | head -8
  echo "## sender"; pgrep -fl "/sender" || echo "sender not running"
  echo "## bridge0"; ifconfig bridge0 | grep -E "inet |mtu"
  echo "## displays"; system_profiler SPDisplaysDataType 2>/dev/null | grep -E "Resolution|Display Type|Main Display|Mirror|Online" | head -12
} > "$out/mac.txt" 2>&1

$RD_SSH "
  echo '## iMac'; uname -r; cut -d' ' -f1-3 /proc/loadavg
  echo '## cpu'; echo governor=\$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor) epp=\$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference) cur=\$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq)kHz
  echo '## gpu'; echo dpm_level=\$(cat /sys/class/drm/card0/device/power_dpm_force_performance_level); grep '\*' /sys/class/drm/card0/device/pp_dpm_sclk /sys/class/drm/card0/device/pp_dpm_mclk
  echo '## link'; ip -s link show thunderbolt0 | sed -n 1,8p
  echo '## doctor'; /usr/local/sbin/rd-doctor 2>&1 | grep -E 'RESULT|FAIL|timeline'
  echo '## receiver'; tr '\\0' ' ' < /proc/\$(pgrep -n receiver_app)/cmdline; echo
  journalctl -u rd-helper -b --no-pager | grep -E 'Mode retenu|Flux ' | tail -2
" > "$out/imac.txt" 2>&1

$RD_SSH "journalctl -u rd-helper -b --no-pager --since '-${win}s'" 2>/dev/null \
  | grep "LAT ms" | sed 's/^.*\[recv\] //' > "$out/receiver_lat.txt" || true

# Mean of each component (first number of "x(y)") and mean of the maxima.
python3 -I - "$out/receiver_lat.txt" <<'PY' | tee "$out/receiver_summary.txt"
import re, statistics, sys
rows = [l for l in open(sys.argv[1]) if "TOTAL" in l]
if not rows:
    print("no receiver latency lines in the window"); sys.exit()
keys = ["réseau", "boîte", "rendu", "vblank", "TOTAL"]
vals = {k: [] for k in keys}; mx = []
for l in rows:
    for k in keys:
        m = re.search(k + r" ([\d.]+)\(([\d.]+)\)", l)
        if m:
            vals[k].append(float(m.group(1)))
            if k == "TOTAL": mx.append(float(m.group(2)))
print(f"receiver-side breakdown over {len(rows)} one-second samples (ms, mean of means):")
print("  " + " | ".join(f"{k} {statistics.fmean(v):.1f}" for k, v in vals.items()))
print(f"  TOTAL per-second max: mean {statistics.fmean(mx):.1f}, worst {max(mx):.1f}")
PY
echo "saved in $out"
