# Net-Ops-Monitor

A Bash-based NOC (Network Operations Center) monitoring toolkit, paired with a
real multi-router OSPF/BGP lab built with FRRouting and Linux network
namespaces. The toolkit performs automated health checks across connectivity,
routing protocols, interfaces, and DNS, triages findings into severity
levels, recommends response actions, and generates incident reports, the
same workflow a NOC/NIE engineer follows when monitoring dashboards and alerting
systems.

## Why this exists

Most "network monitoring" portfolio projects check static things - ping a
host, read a config file. This one monitors **live, dynamically converging
routing protocol state**: real OSPF adjacencies between independent FRR
processes, a real eBGP session crossing an autonomous system boundary, and
real route redistribution between them. The lab isn't a mock - it's
production-grade routing software (FRR's zebra/ospfd/bgpd, the same daemons
used by real ISPs and data centers) running in isolated Linux namespaces on
a single machine.

## Architecture

```
monitor.sh                          (orchestrator, run-once)
  ├─ checks/connectivity.sh         (ICMP reachability + latency)
  ├─ checks/routes.sh               (OSPF adjacency, BGP session, redistribution)
  ├─ checks/interfaces.sh           (RX/TX error & drop deltas between runs)
  ├─ checks/dns.sh                  (resolution success + query time)
  └─ triage/classify.sh             (maps check results -> P1/P2/P3 incidents)
       └─ logs/incidents.log

triage/playbook.sh                  (reads incidents.log, recommends action
                                      + escalation per incident — does NOT
                                      execute remediation automatically)
       └─ logs/playbook_actions.log

triage/report.sh                    (generates grouped RCA-style summary
                                      from incidents.log + playbook_actions.log)

lab/setup_lab.sh                    (builds the 4-router OSPF/BGP topology
                                      that routes.sh monitors)
```

Each check script writes pipe-delimited results to `logs/*_status.tmp`.
`classify.sh` reads all four `.tmp` files and writes structured findings to
`logs/incidents.log`. `playbook.sh` and `report.sh` both key off the run
timestamp in `incidents.log`, so re-running them doesn't reprocess old
history.

## The lab topology

```
        AS 65001                          AS 65002
   ┌─────────────────┐              ┌─────────────────┐
   │     R1 ─ R2     │              │        R4       │
   │  (OSPF area 0)  │──── eBGP ────│    (BGP only)   │
   │        R3       │              │                 │
   └─────────────────┘              └─────────────────┘
```

- **R1, R2, R3**: Linux network namespaces running FRR's `zebra` + `ospfd`,
  forming a full OSPF mesh in Area 0.
- **R2**: also runs `bgpd`, peers with R4 over eBGP, and redistributes
  OSPF-learned routes into BGP (`redistribute ospf`).
- **R4**: a separate namespace/AS with no OSPF — simulates an external
  peer network or ISP that only learns what R2 chooses to advertise.

Addressing (all links are `/30`, usable hosts are `.1` and `.2` only):

| Link        | Subnet          | Host A      | Host B      |
|-------------|-----------------|-------------|-------------|
| R1 – R2     | 10.0.12.0/30    | R1 = .1     | R2 = .2     |
| R2 – R3     | 10.0.23.0/30    | R2 = .2     | R3 = .1     |
| R1 – R3     | 10.0.13.0/30    | R1 = .1     | R3 = .2     |
| R2 – R4     | 10.0.24.0/30    | R2 = .1     | R4 = .2     |

Loopbacks (router IDs): R1 = `1.1.1.1/32`, R2 = `2.2.2.2/32`,
R3 = `3.3.3.3/32`, R4 = `4.4.4.4/32`.

## Running it

```bash
# 1. Build the lab (idempotent - safe to re-run any time)
sudo ./lab/setup_lab.sh

# 2. Run the full monitoring pipeline once
sudo ./monitor.sh

# 3. If incidents were found, see recommended actions and an RCA report
bash triage/playbook.sh
bash triage/report.sh
```

`monitor.sh` exits `0` if no incidents were found, `1` if P1/P2 incidents
were logged, `2` if a check script itself failed to run. This makes it
usable in cron or CI without extra wrapping.

## What each check actually does

**`connectivity.sh`** — pings a configurable list of hosts (`config/hosts.conf`),
extracts packet loss and average latency from `ping` output, and classifies
each host as `REACHABLE` / `SLOW` / `DEGRADED` / `UNREACHABLE` against
configurable thresholds.

**`routes.sh`** — queries the live FRR lab directly via `vtysh`:
- OSPF adjacency state on R1/R2/R3 (`show ip ospf neighbor`) — expects 2 Full
  neighbors on each.
- The eBGP session state between R2 and R4 (`show ip bgp summary`) —
  distinguishes "peer session down" from "can't even reach my own daemon."
- Redistribution proof: checks whether R4 (no OSPF, no direct link to R1/R3)
  still sees the 3 routes it can only learn via OSPF→BGP redistribution. This
  is the check that proves the full chain — not just individual pieces — is
  working end to end.

**`interfaces.sh`** — reads `ip -s link` for configured interfaces
(`config/interfaces.conf`) and tracks RX/TX error and drop counters
*between runs* via a saved baseline file, so it reports new errors since
the last check rather than misleadingly-permanent cumulative totals.

**`dns.sh`** — resolves the hostnames in `hosts.conf` against specific
nameservers via `dig`, measuring query time and flagging failures or slow
resolution.

## Real bugs hit while building this

These aren't hypothetical edge cases — they're things that actually broke
during development, and fixing them is most of what I can speak to in an
interview about this project.

1. **`/30` subnet addressing mistake.** Early on I assigned host `.3` on
   several `/30` links — which is the broadcast address, not a usable host,
   for a 2-bit host space (`.0` = network, `.1`/`.2` = hosts, `.3` =
   broadcast). `ping` correctly refused with "Do you want to ping
   broadcast?" Fixed by re-deriving the addressing scheme from the actual
   `/30` math instead of assuming a pattern.

2. **FRR namespace permission failures.** Launching `zebra` inside a
   namespace failed with "Can't create pid lock file... Permission denied,"
   because FRR drops privileges internally to the `frr` user, but the
   run/config directories I'd created were owned by `root`. Fixed with
   `chown -R frr:frr` on both the config and run directories — matching how
   the real system-wide FRR service is normally provisioned.

3. **BGP's default-deny policy.** After the eBGP session established
   (`show ip bgp summary` showed `Established`), R4 still showed zero
   prefixes. The actual cause, buried in `show ip bgp neighbors` output:
   *"Inbound/Outbound updates discarded due to missing policy."* Modern FRR
   (8.x) requires an explicit route-map on a peer before it will exchange
   any prefixes, even with the address-family activated. Fixed by attaching
   an empty permit-all route-map (`route-map ALLOW-ALL permit 10`, no match
   conditions = match everything) to both inbound and outbound on the peer.

4. **Namespace process-kill scoping.** Running `pkill bgpd` after
   `ip netns exec r4 ...` killed *every* `bgpd` process on the machine, not
   just the one in `r4`'s namespace — because `ip netns exec` only changes
   the *network* namespace context for the launched command; it doesn't
   scope process-name matching for tools like `pkill` that scan `/proc`
   system-wide. Fixed by finding the specific PID first (`ps aux | grep
   bgpd`) and killing by PID instead of by name.

5. **OSPF convergence race condition in the automated setup script.** The
   first version of `setup_lab.sh` used a fixed 10-second sleep before
   verifying adjacencies, which sometimes caught OSPF mid-negotiation
   (`2-Way` instead of `Full`) since DBD exchange hadn't completed yet.
   Fixed by polling every 5 seconds up to 40 seconds and checking actual
   neighbor state, instead of guessing a fixed delay.

## What this deliberately doesn't do

`playbook.sh` recommends remediation steps and escalation paths — it does
not execute any remediation automatically (no daemon restarts, no interface
flaps). This was a deliberate choice: a monitoring tool that can take
destructive action on its own machine is a much larger blast radius than
one that tells a human exactly what to check and do next, and real NOC
environments are similarly cautious about unattended automated changes to
live infrastructure.

## Project structure

```
net-ops-monitor/
├── monitor.sh                  # main orchestrator
├── checks/
│   ├── connectivity.sh
│   ├── routes.sh
│   ├── interfaces.sh
│   └── dns.sh
├── triage/
│   ├── classify.sh
│   ├── playbook.sh
│   └── report.sh
├── lab/
│   └── setup_lab.sh
├── config/
│   ├── hosts.conf
│   └── interfaces.conf
└── logs/                       # generated at runtime, not committed
    ├── incidents.log
    ├── playbook_actions.log
    └── *_status.tmp
```
