#!/usr/bin/env bash
#
# triage/playbook.sh
#
# Reads logs/incidents.log (written by classify.sh) and, for each incident,
# determines a recommended response action based on severity and incident
# type - the same way a real NOC playbook maps an alert to a documented
# response procedure.
#
# IMPORTANT: this script does NOT execute any remediation. It only
# determines and logs what *should* happen (restart daemon X, escalate to
# on-call, etc). Actually running remediation commands automatically is a
# deliberate non-goal here - a monitoring tool that can take destructive
# action on its own is a much bigger blast radius than one that tells a
# human exactly what to do next.
#
# Only processes incidents from the most recent monitor.sh run (matched by
# timestamp), so re-running playbook.sh doesn't reprocess old history.
#
# Output: logs/playbook_actions.log

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LOGS_DIR="$PROJECT_ROOT/logs"
INCIDENTS_LOG="$LOGS_DIR/incidents.log"
ACTIONS_LOG="$LOGS_DIR/playbook_actions.log"

mkdir -p "$LOGS_DIR"
touch "$ACTIONS_LOG"

if [[ ! -s "$INCIDENTS_LOG" ]]; then
    echo "No incidents.log found or it's empty - nothing to action."
    exit 0
fi

# Only act on incidents from the most recent run, identified by the
# latest timestamp present in the file. classify.sh writes one timestamp
# per run across all findings in that run, so this is a reliable boundary.
LATEST_TIMESTAMP=$(tail -1 "$INCIDENTS_LOG" | awk -F' \\| ' '{print $1}')

if [[ -z "$LATEST_TIMESTAMP" ]]; then
    echo "Could not determine latest run timestamp from incidents.log."
    exit 1
fi

recommend_action() {
    local severity="$1"
    local check="$2"
    local detail="$3"

    local action=""
    local escalation=""

    case "$check" in
        CONNECTIVITY)
            action="Verify upstream path: traceroute to target, check default gateway, confirm no recent network changes (CRs) in this segment."
            ;;
        OSPF)
            action="Check adjacency state on both ends of the link (show ip ospf neighbor), verify interface is up, check for MTU mismatch or Hello/Dead timer misconfiguration."
            ;;
        BGP)
            action="Check session state and last-reset reason (show ip bgp neighbors), verify TCP reachability to peer, confirm peer AS/config hasn't changed."
            ;;
        REDISTRIBUTION)
            action="Confirm OSPF is healthy first (redistribution depends on it), then verify 'redistribute ospf' and route-map policy are still present in BGP config."
            ;;
        INTERFACE)
            action="Check physical/virtual link state, review recent RX/TX error trend (not just this snapshot), inspect for duplex mismatch or cabling issue."
            ;;
        DNS)
            action="Test resolution against a second nameserver to isolate whether the issue is the resolver or the authoritative path; check for recent DNS config changes."
            ;;
        *)
            action="No documented playbook step for this check type - escalate for manual triage."
            ;;
    esac

    case "$severity" in
        P1)
            escalation="Immediate escalation - page on-call, treat as active outage until confirmed otherwise."
            ;;
        P2)
            escalation="Escalate within shift - investigate before end of shift, monitor for escalation to P1 if it worsens."
            ;;
        P3)
            escalation="Log and monitor - no immediate escalation, revisit if it recurs or trends upward."
            ;;
        *)
            escalation="Severity unrecognized - default to manual review."
            ;;
    esac

    echo "${severity}|${check}|${detail}|${action}|${escalation}"
}

echo "=== PLAYBOOK ACTIONS === Processing run: ${LATEST_TIMESTAMP}"
echo

incident_count=0

while IFS='|' read -r ts severity check detail; do
    # Trim leading/trailing whitespace left over from the " | " delimiter format
    ts="${ts% }"
    severity="${severity# }"; severity="${severity% }"
    check="${check# }"; check="${check% }"
    detail="${detail# }"

    [[ "$ts" != "$LATEST_TIMESTAMP" ]] && continue

    incident_count=$((incident_count + 1))

    result=$(recommend_action "$severity" "$check" "$detail")
    IFS='|' read -r out_sev out_check out_detail out_action out_escalation <<< "$result"

    echo "${LATEST_TIMESTAMP} | ${out_sev} | ${out_check} | ACTION: ${out_action} | ESCALATION: ${out_escalation}" >> "$ACTIONS_LOG"

    printf "[%s] %s\n" "$out_sev" "$out_check"
    printf "  Incident:   %s\n" "$out_detail"
    printf "  Action:     %s\n" "$out_action"
    printf "  Escalation: %s\n\n" "$out_escalation"

done < "$INCIDENTS_LOG"

if (( incident_count == 0 )); then
    echo "No incidents found for run ${LATEST_TIMESTAMP} - nothing to action."
else
    echo "Processed ${incident_count} incident(s). Recommended actions logged to: ${ACTIONS_LOG}"
fi
