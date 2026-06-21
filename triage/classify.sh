#!/usr/bin/env bash
#
# triage/classify.sh
#
# Reads the .tmp result files produced by checks/connectivity.sh, routes.sh,
# interfaces.sh, and dns.sh, and assigns each finding a severity:
#
#   P1 (Critical) - full outage / no path to recovery without intervention
#   P2 (High)     - degraded but operational, or a single redundant path lost
#   P3 (Low)      - early warning signal, not yet impacting service
#
# Output: appends one line per finding to logs/incidents.log in the format:
#   TIMESTAMP | SEVERITY | CHECK | DETAIL
#
# This script does not take any action - it only classifies. playbook.sh
# (not yet built) will read incidents.log and decide what to do about each
# severity level.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LOGS_DIR="$PROJECT_ROOT/logs"
INCIDENTS_LOG="$LOGS_DIR/incidents.log"

CONNECTIVITY_FILE="$LOGS_DIR/connectivity_status.tmp"
ROUTES_FILE="$LOGS_DIR/routes_status.tmp"
INTERFACES_FILE="$LOGS_DIR/interfaces_status.tmp"
DNS_FILE="$LOGS_DIR/dns_status.tmp"

mkdir -p "$LOGS_DIR"
touch "$INCIDENTS_LOG"

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Collects findings in memory first so we can print a clean summary,
# then writes them all to incidents.log at the end.
declare -a FINDINGS=()

log_finding() {
    local severity="$1"
    local check="$2"
    local detail="$3"
    FINDINGS+=("${severity}|${check}|${detail}")
    echo "${TIMESTAMP} | ${severity} | ${check} | ${detail}" >> "$INCIDENTS_LOG"
}

# ---------------------------------------------------------------------------
# Classify connectivity.sh results
#   Format: name|ip|status|loss|latency|reason
# ---------------------------------------------------------------------------
classify_connectivity() {
    [[ -f "$CONNECTIVITY_FILE" ]] || return

    while IFS='|' read -r name ip status loss latency reason; do
        [[ -z "$name" ]] && continue
        case "$status" in
            UNREACHABLE)
                log_finding "P1" "CONNECTIVITY" "${name} (${ip}) unreachable - ${loss}% loss - ${reason}"
                ;;
            DEGRADED)
                log_finding "P2" "CONNECTIVITY" "${name} (${ip}) degraded - ${loss}% loss, ${latency}ms avg"
                ;;
            SLOW)
                log_finding "P3" "CONNECTIVITY" "${name} (${ip}) slow - ${latency}ms avg latency"
                ;;
            REACHABLE)
                : # healthy, no incident
                ;;
        esac
    done < "$CONNECTIVITY_FILE"
}

# ---------------------------------------------------------------------------
# Classify routes.sh results
#   Format varies by row type:
#     OSPF_<ns>|status|full_count|expected|reason
#     BGP_SESSION|status|uptime|reason
#     REDISTRIBUTION|status|found|expected|reason
# ---------------------------------------------------------------------------
classify_routes() {
    [[ -f "$ROUTES_FILE" ]] || return

    while IFS='|' read -r name status val1 val2 val3; do
        [[ -z "$name" ]] && continue
        case "$name" in
            OSPF_*)
                # Format: OSPF_<ns>|status|full_count|expected|reason
                local reason="$val3"
                case "$status" in
                    DOWN)
                        log_finding "P1" "OSPF" "${name} has zero Full neighbors (expected ${val2})"
                        ;;
                    DEGRADED)
                        log_finding "P2" "OSPF" "${name} has ${val1}/${val2} neighbors Full - partial mesh"
                        ;;
                    UNREACHABLE)
                        log_finding "P1" "OSPF" "${name} daemon unreachable - ${reason}"
                        ;;
                esac
                ;;
            BGP_SESSION)
                # Format: BGP_SESSION|status|uptime|reason  (only 4 fields - no "expected" column)
                local reason="$val2"
                case "$status" in
                    DOWN)
                        log_finding "P1" "BGP" "eBGP session down - ${reason}"
                        ;;
                    UNREACHABLE)
                        log_finding "P1" "BGP" "Local bgpd unreachable - ${reason}"
                        ;;
                esac
                ;;
            REDISTRIBUTION)
                # Format: REDISTRIBUTION|status|found|expected|reason
                local reason="$val3"
                case "$status" in
                    DOWN)
                        log_finding "P2" "REDISTRIBUTION" "0/${val2} OSPF routes visible cross-AS - ${reason}"
                        ;;
                    DEGRADED)
                        log_finding "P2" "REDISTRIBUTION" "${val1}/${val2} expected routes visible - ${reason}"
                        ;;
                    UNREACHABLE)
                        log_finding "P1" "REDISTRIBUTION" "Cannot query peer AS - ${reason}"
                        ;;
                esac
                ;;
        esac
    done < "$ROUTES_FILE"
}

# ---------------------------------------------------------------------------
# Classify interfaces.sh results
#   Format: iface|status|rx_err_delta|tx_err_delta|rx_drop_delta|tx_drop_delta|reason
# ---------------------------------------------------------------------------
classify_interfaces() {
    [[ -f "$INTERFACES_FILE" ]] || return

    while IFS='|' read -r iface status v1 v2 v3 v4 reason; do
        [[ -z "$iface" ]] && continue
        case "$status" in
            CRITICAL)
                log_finding "P1" "INTERFACE" "${iface} - ${reason} (rx_err+${v1} tx_err+${v2} rx_drop+${v3} tx_drop+${v4})"
                ;;
            WARNING)
                log_finding "P3" "INTERFACE" "${iface} - new errors detected (rx_err+${v1} tx_err+${v2} rx_drop+${v3} tx_drop+${v4})"
                ;;
            MISSING)
                log_finding "P2" "INTERFACE" "${iface} - ${reason}"
                ;;
        esac
    done < "$INTERFACES_FILE"
}

# ---------------------------------------------------------------------------
# Classify dns.sh results
#   Format: name|hostname|status|ip|querytime|nameserver
# ---------------------------------------------------------------------------
classify_dns() {
    [[ -f "$DNS_FILE" ]] || return

    while IFS='|' read -r name hostname status ip qtime ns; do
        [[ -z "$name" ]] && continue
        case "$status" in
            FAILED)
                log_finding "P2" "DNS" "${name} (${hostname}) failed to resolve - ${ns}"
                ;;
            SLOW)
                log_finding "P3" "DNS" "${name} (${hostname}) slow resolution - ${qtime}ms via ${ns}"
                ;;
        esac
    done < "$DNS_FILE"
}

# ---------------------------------------------------------------------------
# Run all classifiers
# ---------------------------------------------------------------------------
classify_connectivity
classify_routes
classify_interfaces
classify_dns

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "=== TRIAGE SUMMARY === ${TIMESTAMP}"
echo

if [[ ${#FINDINGS[@]} -eq 0 ]]; then
    echo "No incidents. All checked systems healthy."
    exit 0
fi

p1_count=0
p2_count=0
p3_count=0

for finding in "${FINDINGS[@]}"; do
    IFS='|' read -r sev check detail <<< "$finding"
    case "$sev" in
        P1) p1_count=$((p1_count + 1)) ;;
        P2) p2_count=$((p2_count + 1)) ;;
        P3) p3_count=$((p3_count + 1)) ;;
    esac
    printf "[%s] %-14s %s\n" "$sev" "$check" "$detail"
done

echo
echo "Totals: P1=${p1_count}  P2=${p2_count}  P3=${p3_count}"
echo "Logged to: ${INCIDENTS_LOG}"
