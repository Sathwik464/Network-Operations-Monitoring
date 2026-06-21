#!/usr/bin/env bash
#
# monitor.sh
#
# Main orchestrator for net-ops-monitor. Runs all 4 check scripts in
# sequence, then classify.sh to triage the results, and prints a single
# consolidated run summary.
#
# Designed to run once and exit (not a daemon loop) - intended usage is
# via cron or `watch -n 30 ./monitor.sh` for continuous polling, rather
# than building a sleep-loop into the script itself.
#
# Usage:
#   ./monitor.sh            run all checks (routes.sh needs sudo separately)
#   sudo ./monitor.sh        run all checks including routes.sh (recommended)
#
# Exit codes:
#   0 = all checks ran, no P1/P2 incidents found
#   1 = all checks ran, but P1 and/or P2 incidents were found
#   2 = one or more check scripts failed to run at all

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKS_DIR="$SCRIPT_DIR/checks"
TRIAGE_DIR="$SCRIPT_DIR/triage"
LOGS_DIR="$SCRIPT_DIR/logs"

mkdir -p "$LOGS_DIR"

RUN_TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
CHECK_FAILURES=0

log() {
    echo ">>> $*"
}

run_check() {
    local script_name="$1"
    local script_path="$CHECKS_DIR/$script_name"

    if [[ ! -f "$script_path" ]]; then
        log "SKIPPED: $script_name not found at $script_path"
        CHECK_FAILURES=$((CHECK_FAILURES + 1))
        return
    fi

    log "Running $script_name..."

    # routes.sh needs root (vtysh against namespace sockets). The others
    # don't strictly need it, but running monitor.sh itself with sudo
    # covers all four uniformly - simpler than mixing privilege levels
    # mid-script.
    if bash "$script_path" > /tmp/monitor_last_check_output.txt 2>&1; then
        : # success, output already captured for the summary below
    else
        log "WARNING: $script_name exited with a non-zero status"
        CHECK_FAILURES=$((CHECK_FAILURES + 1))
    fi

    # Show a condensed view (first line = header) so monitor.sh's own
    # output stays scannable rather than dumping all 4 scripts' full text
    head -1 /tmp/monitor_last_check_output.txt
}

echo "=========================================="
echo " net-ops-monitor run: $RUN_TIMESTAMP"
echo "=========================================="
echo

run_check "connectivity.sh"
run_check "routes.sh"
run_check "interfaces.sh"
run_check "dns.sh"

echo
log "Running triage/classify.sh..."
echo

if [[ -f "$TRIAGE_DIR/classify.sh" ]]; then
    bash "$TRIAGE_DIR/classify.sh"
    classify_exit=$?
else
    log "SKIPPED: triage/classify.sh not found"
    classify_exit=2
fi

echo
echo "=========================================="

if (( CHECK_FAILURES > 0 )); then
    log "Run completed with ${CHECK_FAILURES} check script failure(s)."
    exit 2
fi

# Re-check incidents.log for anything logged in THIS run (matching our
# timestamp) to decide the script's own exit code - lets cron/CI treat
# "incidents found" differently from "everything's fine".
if grep -q "$RUN_TIMESTAMP" "$LOGS_DIR/incidents.log" 2>/dev/null; then
    log "Run completed. Incidents were found - see logs/incidents.log"
    exit 1
else
    log "Run completed. No incidents."
    exit 0
fi
