#!/usr/bin/env bash
#
# checks/connectivity.sh
#
# Pings each host listed in config/hosts.conf, extracts packet loss and
# average latency, and classifies each host as REACHABLE / SLOW / DEGRADED /
# UNREACHABLE. Results are written pipe-delimited to logs/connectivity_status.tmp
# for classify.sh to consume later, and a human-readable summary is printed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
HOSTS_FILE="$PROJECT_ROOT/config/hosts.conf"
RESULTS_FILE="$PROJECT_ROOT/logs/connectivity_status.tmp"

PING_COUNT=5         # packets per host
PING_TIMEOUT=2        # seconds to wait per packet

LOSS_CRITICAL=50      # % loss at/above this -> UNREACHABLE
LOSS_WARNING=10       # % loss at/above this -> DEGRADED
LATENCY_WARNING=200   # ms avg latency at/above this -> SLOW

mkdir -p "$(dirname "$RESULTS_FILE")"
> "$RESULTS_FILE"     # clear previous results

check_host() {
    local ip="$1"
    local name="$2"

    local ping_output
    ping_output=$(ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$ip" 2>&1)

    # Host/network completely unreachable at the OS level (no route, etc)
    if echo "$ping_output" | grep -qi "network is unreachable\|connect: No route\|unknown host"; then
        echo "${name}|${ip}|UNREACHABLE|100|0|NO_ROUTE" >> "$RESULTS_FILE"
        return
    fi

    # Extract packet loss percentage, e.g. "40% packet loss" -> 40
    local loss
    loss=$(echo "$ping_output" | grep -oP '\d+(?=% packet loss)')

    # No loss figure at all means ping never got a reply to parse
    if [[ -z "$loss" ]]; then
        echo "${name}|${ip}|UNREACHABLE|100|0|TIMEOUT" >> "$RESULTS_FILE"
        return
    fi

    # Extract average latency from "rtt min/avg/max/mdev = a/b/c/d ms"
    local avg_latency
    avg_latency=$(echo "$ping_output" | grep -oP 'rtt.*=\s*[\d.]+/\K[\d.]+')
    avg_latency="${avg_latency:-0}"

    local status
    if [[ "$loss" -ge "$LOSS_CRITICAL" ]]; then
        status="UNREACHABLE"
    elif [[ "$loss" -ge "$LOSS_WARNING" ]]; then
        status="DEGRADED"
    elif (( $(echo "$avg_latency >= $LATENCY_WARNING" | bc -l) )); then
        status="SLOW"
    else
        status="REACHABLE"
    fi

    echo "${name}|${ip}|${status}|${loss}|${avg_latency}|OK" >> "$RESULTS_FILE"
}

# Read hosts file, skipping comments and blank lines
while IFS= read -r line; do
    [[ "$line" =~ ^#.*$ || -z "${line// }" ]] && continue
    ip=$(echo "$line" | awk '{print $1}')
    name=$(echo "$line" | awk '{print $2}')
    [[ -z "$ip" || -z "$name" ]] && continue
    check_host "$ip" "$name"
done < "$HOSTS_FILE"

# Human-readable summary
echo "=== CONNECTIVITY CHECK === $(date '+%Y-%m-%d %H:%M:%S')"
echo

while IFS='|' read -r name ip status loss latency reason; do
    printf "%-18s %-16s %-13s loss=%-5s%% latency=%-8sms  %s\n" \
        "$name" "$ip" "$status" "$loss" "$latency" "$reason"
done < "$RESULTS_FILE"
