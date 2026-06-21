#!/usr/bin/env bash
#
# checks/dns.sh
#
# Reuses config/hosts.conf (the same file connectivity.sh reads) and
# attempts DNS resolution for every entry that is an actual hostname
# (IP-address entries like 8.8.8.8 are skipped automatically, since
# there's nothing to resolve there).
#
# For each hostname, records: resolved successfully or not, which IP it
# resolved to, query time in ms, and which nameserver answered.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
HOSTS_FILE="$PROJECT_ROOT/config/hosts.conf"
RESULTS_FILE="$PROJECT_ROOT/logs/dns_status.tmp"

DIG_TIMEOUT=3          # seconds to wait for a response
QUERY_TIME_WARNING=500 # ms - at/above this, flag as SLOW even if resolved

# Nameservers to query directly (bypasses local resolver cache, so we see
# real upstream resolution time rather than a cached instant response)
NAMESERVERS=("8.8.8.8" "1.1.1.1")

mkdir -p "$(dirname "$RESULTS_FILE")"
> "$RESULTS_FILE"

is_ip_address() {
    # Returns true if the input looks like a bare IPv4 address (no resolution needed)
    local input="$1"
    [[ "$input" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

check_hostname() {
    local hostname="$1"
    local name="$2"

    local resolved_ok=false

    for ns in "${NAMESERVERS[@]}"; do
        local dig_output
        dig_output=$(dig +time="$DIG_TIMEOUT" +tries=1 "$hostname" @"$ns" 2>&1)

        # ANSWER SECTION present means we got at least one record back
        if echo "$dig_output" | grep -q "ANSWER SECTION"; then
            local resolved_ip
            resolved_ip=$(echo "$dig_output" | awk '/ANSWER SECTION/{found=1; next} found && $0!=""{print $5; exit}')

            local query_time
            query_time=$(echo "$dig_output" | grep -oP 'Query time:\s*\K[0-9]+')
            query_time="${query_time:-0}"

            local status
            if (( query_time >= QUERY_TIME_WARNING )); then
                status="SLOW"
            else
                status="RESOLVED"
            fi

            echo "${name}|${hostname}|${status}|${resolved_ip:-N/A}|${query_time}|${ns}" >> "$RESULTS_FILE"
            resolved_ok=true
            break
        fi
    done

    if [[ "$resolved_ok" == false ]]; then
        echo "${name}|${hostname}|FAILED|N/A|0|NO_RESPONSE" >> "$RESULTS_FILE"
    fi
}

# Read hosts.conf, but only act on entries that are hostnames, not raw IPs
while IFS= read -r line; do
    [[ "$line" =~ ^#.*$ || -z "${line// }" ]] && continue
    target=$(echo "$line" | awk '{print $1}')
    name=$(echo "$line" | awk '{print $2}')
    [[ -z "$target" || -z "$name" ]] && continue

    if is_ip_address "$target"; then
        continue   # nothing to resolve for a bare IP entry
    fi

    check_hostname "$target" "$name"
done < "$HOSTS_FILE"

# Human-readable summary
echo "=== DNS RESOLUTION CHECK === $(date '+%Y-%m-%d %H:%M:%S')"
echo

if [[ ! -s "$RESULTS_FILE" ]]; then
    echo "No hostnames found in config/hosts.conf to resolve (only IP entries present)."
    exit 0
fi

while IFS='|' read -r name hostname status ip qtime ns; do
    printf "%-18s %-20s %-10s -> %-16s %sms via %s\n" \
        "$name" "$hostname" "$status" "$ip" "$qtime" "$ns"
done < "$RESULTS_FILE"
