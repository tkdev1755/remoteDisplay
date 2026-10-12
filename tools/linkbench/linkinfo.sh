#!/usr/bin/env bash
# Prints what this machine knows about its Thunderbolt link and network limits.
# Run it on both machines; it detects macOS or Linux by itself.

section() { printf '\n===== %s =====\n' "$1"; }

if [ "$(uname)" = "Darwin" ]; then
    section "machine"
    sw_vers
    sysctl -n hw.model machdep.cpu.brand_string
    section "thunderbolt"
    system_profiler SPThunderboltDataType
    section "interface (bridge0)"
    ifconfig bridge0
    section "udp / socket limits"
    sysctl net.inet.udp.maxdgram net.inet.udp.recvspace kern.ipc.maxsockbuf
else
    section "machine"
    uname -a
    grep -m1 'model name' /proc/cpuinfo
    section "cpu frequency governor"
    cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort | uniq -c
    section "thunderbolt devices"
    for d in /sys/bus/thunderbolt/devices/*; do
        [ -e "$d/device_name" ] || continue
        echo "-- $(basename "$d")"
        for f in vendor_name device_name generation rx_speed tx_speed rx_lanes tx_lanes; do
            [ -r "$d/$f" ] && printf '   %-12s %s\n' "$f" "$(cat "$d/$f")"
        done
    done
    command -v boltctl >/dev/null && { section "boltctl"; boltctl list; }
    section "network interfaces (thunderbolt)"
    for i in /sys/class/net/*; do
        n=$(basename "$i")
        case "$(readlink -f "$i/device/driver" 2>/dev/null)" in
            *thunderbolt*) ip -d link show "$n"; ip -4 addr show "$n" | grep inet ;;
        esac
    done
    section "socket limits"
    sysctl net.core.rmem_max net.core.wmem_max net.core.rmem_default net.core.netdev_max_backlog
fi
