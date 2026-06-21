#!/usr/bin/env bash
#
# checks/routes.sh
#
# Queries the live FRR lab (lab/setup_lab.sh) for routing protocol health:
#   1. OSPF adjacency state on r1, r2, r3 (expect Full on every neighbor)
#   2. eBGP session state between r2 (AS 65001) and r4 (AS 65002)
#   3. Route redistribution proof - does r4 still see the 3 OSPF-originated
#      routes it has no other way to learn (1.1.1.1/32, 3.3.3.3/32, 10.0.13.0/30)
#
# This is intentionally hardcoded to the lab topology (r1-r4) rather than
# config-driven, since the lab itself is a fixed, known topology.
#
# Output format matches connectivity.sh: pipe-delimited results written to
# a .tmp file for classify.sh to consume, plus a human-readable summary
# printed to stdout.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RESULTS_FILE="$PROJECT_ROOT/logs/routes_status.tmp"

FRR_RUN_DIR="/var/run/frr-labs"

# Routes r4 should have learned purely via OSPF->BGP redistribution.
# If any of these disappear from r4's BGP table, redistribution broke
# somewhere upstream (OSPF adjacency down, or BGP session down, or the
# redistribute/route-map config got removed).
EXPECTED_REDISTRIBUTED_ROUTES=(
    "1.1.1.1/32"
    "3.3.3.3/32"
    "10.0.13.0/30"
)

> "$RESULTS_FILE"   # clear previous results

vty() {
    # Helper: run a vtysh command against a given namespace's FRR instance
    local ns="$1"
    shift
    vtysh --vty_socket "$FRR_RUN_DIR/$ns/" -c "$*" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Check 1: OSPF adjacency state on r1, r2, r3
# ---------------------------------------------------------------------------
check_ospf() {
    local ns="$1"
    local expected_neighbors="$2"  # how many neighbors this router should have

    local neighbor_output
    neighbor_output=$(vty "$ns" "show ip ospf neighbor")

    # If vtysh couldn't even connect, the daemon/namespace is down
    if [[ -z "$neighbor_output" ]]; then
        echo "OSPF_${ns}|UNREACHABLE|0|${expected_neighbors}|DAEMON_DOWN" >> "$RESULTS_FILE"
        return
    fi

    local full_count
    full_count=$(echo "$neighbor_output" | grep -c "Full" || true)

    local status
    if [[ "$full_count" -eq "$expected_neighbors" ]]; then
        status="HEALTHY"
    elif [[ "$full_count" -gt 0 ]]; then
        status="DEGRADED"
    else
        status="DOWN"
    fi

    echo "OSPF_${ns}|${status}|${full_count}|${expected_neighbors}|OK" >> "$RESULTS_FILE"
}

# ---------------------------------------------------------------------------
# Check 2: eBGP session state between r2 and r4
# ---------------------------------------------------------------------------
check_bgp_session() {
    local summary_output
    summary_output=$(vty r2 "show ip bgp summary")

    if [[ -z "$summary_output" ]]; then
        echo "BGP_SESSION|UNREACHABLE|N/A|DAEMON_DOWN" >> "$RESULTS_FILE"
        return
    fi

    # The neighbor line looks like:
    # 10.0.24.2   4   65002   25   35   0   0   0   00:17:17   0   3   N/A
    # Field 9 (Up/Down) is either a time (session up) or a state word like
    # "Active"/"Connect"/"Idle" (session down/negotiating).
    local neighbor_line
    neighbor_line=$(echo "$summary_output" | grep "10.0.24.2")

    if [[ -z "$neighbor_line" ]]; then
        echo "BGP_SESSION|DOWN|N/A|NEIGHBOR_NOT_FOUND" >> "$RESULTS_FILE"
        return
    fi

    local updown_field
    updown_field=$(echo "$neighbor_line" | awk '{print $9}')

    # A real uptime contains a colon (e.g. 00:17:17). A down/negotiating
    # session shows a word instead (Active, Connect, Idle, etc).
    if [[ "$updown_field" == *:* ]]; then
        echo "BGP_SESSION|ESTABLISHED|${updown_field}|OK" >> "$RESULTS_FILE"
    else
        echo "BGP_SESSION|DOWN|${updown_field}|SESSION_NOT_ESTABLISHED" >> "$RESULTS_FILE"
    fi
}

# ---------------------------------------------------------------------------
# Check 3: Redistribution proof - does r4 still see the expected routes?
# ---------------------------------------------------------------------------
check_redistribution() {
    local bgp_table
    bgp_table=$(vty r4 "show ip bgp")

    if [[ -z "$bgp_table" ]]; then
        echo "REDISTRIBUTION|UNREACHABLE|0|${#EXPECTED_REDISTRIBUTED_ROUTES[@]}|DAEMON_DOWN" >> "$RESULTS_FILE"
        return
    fi

    local found_count=0
    local missing_routes=()

    for route in "${EXPECTED_REDISTRIBUTED_ROUTES[@]}"; do
        if echo "$bgp_table" | grep -q "$route"; then
            found_count=$((found_count + 1))
        else
            missing_routes+=("$route")
        fi
    done

    local status
    if [[ "$found_count" -eq "${#EXPECTED_REDISTRIBUTED_ROUTES[@]}" ]]; then
        status="HEALTHY"
    elif [[ "$found_count" -gt 0 ]]; then
        status="DEGRADED"
    else
        status="DOWN"
    fi
    local reason="OK"
    if [[ "$found_count" -lt "${#EXPECTED_REDISTRIBUTED_ROUTES[@]}" ]]; then
        reason="MISSING:${missing_routes[*]}"
        reason="${reason// /,}"
    fi

    echo "REDISTRIBUTION|${status}|${found_count}|${#EXPECTED_REDISTRIBUTED_ROUTES[@]}|${reason}" >> "$RESULTS_FILE"
}

# ---------------------------------------------------------------------------
# Run all checks
# ---------------------------------------------------------------------------
check_ospf r1 2
check_ospf r2 2
check_ospf r3 2
check_bgp_session
check_redistribution

# ---------------------------------------------------------------------------
# Print human-readable summary
# ---------------------------------------------------------------------------
echo "=== ROUTING PROTOCOL CHECK === $(date '+%Y-%m-%d %H:%M:%S')"
echo

while IFS='|' read -r name status val1 val2 reason; do
    case "$name" in
        OSPF_*)
            printf "%-16s %-12s neighbors_full=%s/%s  %s\n" "$name" "$status" "$val1" "$val2" "$reason"
            ;;
        BGP_SESSION)
            printf "%-16s %-12s uptime=%-10s %s\n" "$name" "$status" "$val1" "$reason"
            ;;
        REDISTRIBUTION)
            printf "%-16s %-12s routes=%s/%s  %s\n" "$name" "$status" "$val1" "$val2" "$reason"
            ;;
    esac
done < "$RESULTS_FILE"
