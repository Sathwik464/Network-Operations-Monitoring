#!/usr/bin/env bash
#
# checks/interfaces.sh
#
# Reads `ip -s link` for each interface listed in config/interfaces.conf,
# extracts RX/TX error and drop counters, and compares them against the
# previous run's baseline to detect NEW errors/drops since last check
# (rather than reporting cumulative totals, which would look "bad" forever
# after a single historical error).
#
# State is persisted in logs/interfaces_baseline.tmp between runs.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
IFACES_FILE="$PROJECT_ROOT/config/interfaces.conf"
BASELINE_FILE="$PROJECT_ROOT/logs/interfaces_baseline.tmp"
RESULTS_FILE="$PROJECT_ROOT/logs/interfaces_status.tmp"

# New errors/drops at or above this count since last check -> WARNING
ERROR_DELTA_WARNING=1
# New errors/drops at or above this count since last check -> CRITICAL
ERROR_DELTA_CRITICAL=10

mkdir -p "$(dirname "$RESULTS_FILE")"
> "$RESULTS_FILE"

# Load previous baseline into an associative array: baseline[iface]="rxerr,txerr,rxdrop,txdrop"
declare -A baseline
if [[ -f "$BASELINE_FILE" ]]; then
    while IFS='|' read -r iface rxerr txerr rxdrop txdrop; do
        [[ -z "$iface" ]] && continue
        baseline["$iface"]="${rxerr},${txerr},${rxdrop},${txdrop}"
    done < "$BASELINE_FILE"
fi

# This run's readings get written here, then become next run's baseline
> "$BASELINE_FILE.new"

check_interface() {
    local iface="$1"

    local link_output
    link_output=$(ip -s link show "$iface" 2>&1)

    if [[ -z "$link_output" ]] || echo "$link_output" | grep -qi "does not exist\|not found\|no such"; then
        echo "${iface}|MISSING|0|0|0|0|INTERFACE_NOT_FOUND" >> "$RESULTS_FILE"
        return
    fi

    local link_state
    if echo "$link_output" | head -1 | grep -q "UP"; then
        link_state="UP"
    else
        link_state="DOWN"
    fi

    # `ip -s link` output looks like:
    #   RX: bytes  packets  errors  dropped overrun mcast
    #   1234       10        0       0        0       0
    #   TX: bytes  packets  errors  dropped carrier collsns
    #   5678       12        0       0        0       0
    # We grab the numeric line right after each "RX:"/"TX:" header line.
    local rx_line tx_line
    rx_line=$(echo "$link_output" | grep -A1 "RX:" | tail -1)
    tx_line=$(echo "$link_output" | grep -A1 "TX:" | tail -1)

    local rx_errors rx_dropped tx_errors tx_dropped
    rx_errors=$(echo "$rx_line" | awk '{print $3}')
    rx_dropped=$(echo "$rx_line" | awk '{print $4}')
    tx_errors=$(echo "$tx_line" | awk '{print $3}')
    tx_dropped=$(echo "$tx_line" | awk '{print $4}')

    # Default to 0 if parsing failed for any reason (keeps arithmetic safe)
    rx_errors="${rx_errors:-0}"
    rx_dropped="${rx_dropped:-0}"
    tx_errors="${tx_errors:-0}"
    tx_dropped="${tx_dropped:-0}"

    # Save this run's raw counters as next run's baseline
    echo "${iface}|${rx_errors}|${tx_errors}|${rx_dropped}|${tx_dropped}" >> "$BASELINE_FILE.new"

    local status reason
    if [[ "$link_state" == "DOWN" ]]; then
        echo "${iface}|CRITICAL|0|0|0|0|INTERFACE_DOWN" >> "$RESULTS_FILE"
        return
    fi

    if [[ -z "${baseline[$iface]:-}" ]]; then
        # No prior data - first run for this interface, nothing to compare yet
        echo "${iface}|HEALTHY|${rx_errors}|${tx_errors}|${rx_dropped}|${tx_dropped}|NO_BASELINE_FIRST_RUN" >> "$RESULTS_FILE"
        return
    fi

    IFS=',' read -r base_rxerr base_txerr base_rxdrop base_txdrop <<< "${baseline[$iface]}"

    local delta_rxerr=$(( rx_errors - base_rxerr ))
    local delta_txerr=$(( tx_errors - base_txerr ))
    local delta_rxdrop=$(( rx_dropped - base_rxdrop ))
    local delta_txdrop=$(( tx_dropped - base_txdrop ))

    # Guard against negative deltas (counters reset on interface restart)
    (( delta_rxerr < 0 )) && delta_rxerr=0
    (( delta_txerr < 0 )) && delta_txerr=0
    (( delta_rxdrop < 0 )) && delta_rxdrop=0
    (( delta_txdrop < 0 )) && delta_txdrop=0

    local total_delta=$(( delta_rxerr + delta_txerr + delta_rxdrop + delta_txdrop ))

    if (( total_delta >= ERROR_DELTA_CRITICAL )); then
        status="CRITICAL"
    elif (( total_delta >= ERROR_DELTA_WARNING )); then
        status="WARNING"
    else
        status="HEALTHY"
    fi

    echo "${iface}|${status}|${delta_rxerr}|${delta_txerr}|${delta_rxdrop}|${delta_txdrop}|new_errors_since_last_check" >> "$RESULTS_FILE"
}

# Read configured interfaces, skip comments/blank lines
while IFS= read -r line; do
    [[ "$line" =~ ^#.*$ || -z "${line// }" ]] && continue
    check_interface "$line"
done < "$IFACES_FILE"

# Promote this run's readings to be next run's baseline
mv "$BASELINE_FILE.new" "$BASELINE_FILE"

# Human-readable summary
echo "=== INTERFACE HEALTH CHECK === $(date '+%Y-%m-%d %H:%M:%S')"
echo

while IFS='|' read -r iface status v1 v2 v3 v4 reason; do
    printf "%-10s %-10s rx_err=+%-4s tx_err=+%-4s rx_drop=+%-4s tx_drop=+%-4s  %s\n" \
        "$iface" "$status" "$v1" "$v2" "$v3" "$v4" "$reason"
done < "$RESULTS_FILE"
