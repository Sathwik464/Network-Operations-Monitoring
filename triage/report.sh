#!/usr/bin/env bash
#
# triage/report.sh
#
# Generates a human-readable RCA-style report from logs/incidents.log and
# logs/playbook_actions.log. Groups incidents by check type (rather than
# replaying them as a flat list) so the report reads like a summary you'd
# actually hand to a shift lead, not a raw log dump.
#
# Defaults to summarizing the most recent run (by timestamp), or pass a
# specific timestamp to report on an older run:
#   ./report.sh                         # most recent run
#   ./report.sh "2026-06-21 17:47:07"   # specific run

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LOGS_DIR="$PROJECT_ROOT/logs"
INCIDENTS_LOG="$LOGS_DIR/incidents.log"
ACTIONS_LOG="$LOGS_DIR/playbook_actions.log"

if [[ ! -s "$INCIDENTS_LOG" ]]; then
    echo "No incidents.log found or it's empty - nothing to report on."
    exit 0
fi

TARGET_TIMESTAMP="$1"
if [[ -z "$TARGET_TIMESTAMP" ]]; then
    TARGET_TIMESTAMP=$(tail -1 "$INCIDENTS_LOG" | awk -F' \\| ' '{print $1}')
fi

if [[ -z "$TARGET_TIMESTAMP" ]]; then
    echo "Could not determine a run timestamp to report on."
    exit 1
fi

REPORT_GENERATED=$(date '+%Y-%m-%d %H:%M:%S')
INCIDENT_ID="INC-$(date -d "$TARGET_TIMESTAMP" '+%Y%m%d-%H%M%S' 2>/dev/null || echo "UNKNOWN")"

echo "INCIDENT REPORT - Generated ${REPORT_GENERATED}"
echo "================================================"
echo "Report ID    : ${INCIDENT_ID}"
echo "Run Time     : ${TARGET_TIMESTAMP}"
echo

# Pull all incidents matching this run's timestamp
declare -a MATCHED_LINES=()
trim() {
    # Safe whitespace trim using Bash parameter expansion only - avoids
    # xargs, which mishandles apostrophes and quote characters that can
    # legitimately appear in action/escalation text (e.g. "hasn't changed").
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    echo "$s"
}

while IFS= read -r line; do
    line_ts=$(echo "$line" | awk -F' \\| ' '{print $1}')
    [[ "$line_ts" == "$TARGET_TIMESTAMP" ]] && MATCHED_LINES+=("$line")
done < "$INCIDENTS_LOG"

if [[ ${#MATCHED_LINES[@]} -eq 0 ]]; then
    echo "No incidents found for run ${TARGET_TIMESTAMP}."
    exit 0
fi

# Count by severity for the headline summary
p1=0; p2=0; p3=0
for line in "${MATCHED_LINES[@]}"; do
    sev=$(trim "$(echo "$line" | awk -F' \\| ' '{print $2}')")
    case "$sev" in
        P1) p1=$((p1+1)) ;;
        P2) p2=$((p2+1)) ;;
        P3) p3=$((p3+1)) ;;
    esac
done

echo "Summary      : ${#MATCHED_LINES[@]} incident(s) - P1: ${p1}  P2: ${p2}  P3: ${p3}"

if (( p1 > 0 )); then
    echo "Overall Sev  : P1 (Critical) - highest severity in this run"
elif (( p2 > 0 )); then
    echo "Overall Sev  : P2 (High)"
else
    echo "Overall Sev  : P3 (Low)"
fi
echo

# Group findings by check type for the body of the report
declare -A GROUPED
for line in "${MATCHED_LINES[@]}"; do
    check=$(trim "$(echo "$line" | awk -F' \\| ' '{print $3}')")
    detail=$(echo "$line" | awk -F' \\| ' '{print $4}')
    sev=$(trim "$(echo "$line" | awk -F' \\| ' '{print $2}')")
    GROUPED["$check"]+="  [${sev}] ${detail}"$'\n'
done

echo "Findings by component:"
echo "-----------------------"
for check in "${!GROUPED[@]}"; do
    echo
    echo "${check}:"
    printf '%s' "${GROUPED[$check]}"
done

# Cross-reference recommended actions from playbook_actions.log, if present
if [[ -s "$ACTIONS_LOG" ]]; then
    echo
    echo "Recommended actions (from playbook):"
    echo "-------------------------------------"
    declare -A SEEN_ACTIONS
    while IFS= read -r line; do
        line_ts=$(echo "$line" | awk -F' \\| ' '{print $1}')
        [[ "$line_ts" != "$TARGET_TIMESTAMP" ]] && continue

        check=$(trim "$(echo "$line" | awk -F' \\| ' '{print $3}')")
        action=$(trim "$(echo "$line" | grep -oP 'ACTION: \K[^|]+')")

        # Each check type's action text is the same regardless of which
        # specific host/instance triggered it, so de-dupe per check type
        # rather than printing the same recommendation N times.
        key="${check}|${action}"
        [[ -n "${SEEN_ACTIONS[$key]:-}" ]] && continue
        SEEN_ACTIONS[$key]=1

        echo
        echo "${check}:"
        echo "  ${action}"
    done < "$ACTIONS_LOG"
else
    echo
    echo "(No playbook_actions.log found - run triage/playbook.sh to generate recommended actions.)"
fi

echo
echo "================================================"
echo "End of report. Raw data: ${INCIDENTS_LOG}"
