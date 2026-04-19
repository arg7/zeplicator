# Zeplicator: Docker Test Bench & Debugging Notes

This document describes the simulated multi-node environment used to verify Zeplicator's cascading replication and master promotion logic.

---

## 1. Test Bench Configuration
We simulate a three-node production chain using Docker on a single ZFS-capable host.

### Infrastructure
*   **Containers:** 3 nodes (`node1`, `node2`, `node3`) running Ubuntu 22.04.
*   **Storage:** 
    *   3 distinct ZFS pools: `node1-pool`, `node2-pool`, `node3-pool`.
    *   Backed by 8GB sparse image files on the host (`/root/zfs-dev/node[x].img`).
*   **Mounting:** The host directory `/root/zfs-dev` is bind-mounted to `/scripts` on all containers.
*   **Networking:**
    *   `node1`: 172.17.0.2 (Master)
    *   `node2`: 172.17.0.3 (Middle)
    *   `node3`: 172.17.0.4 (Sink)
    *   **SSH:** Full mesh connectivity enabled; `StrictHostKeyChecking` disabled for seamless automation.

### Dataset Topology
Each node uses a uniquely named dataset to test path-mapping robustness:
*   `node1-pool/data1` -> `node2-pool/data2` -> `node3-pool/data3`

### Data Load (IO Simulation)
A background process on `node1` provides constant incremental changes:
```bash
while true; do date >> /node1-pool/data1/test.txt; sleep 1; done
```

---

## 2. Major Gotchas Encountered

### A. ZFS "Ghost" Visibility (Shared Kernel Trap)
*   **The Problem:** Since Docker containers share the host kernel, every container could "see" all three ZFS pools in `zpool list`. The script's original snapshot discovery used global `grep` commands, causing `node1` to accidentally find and attempt to process snapshots belonging to `node2`.
*   **The Fix:** Updated all discovery logic to use explicit recursive scoping (`zfs list -r <dataset>`) to ensure nodes only see their own intended data.

### B. Bash "local" Syntax Errors
*   **The Problem:** The script used the `local` keyword for variable declarations in the main execution body (global scope). This is illegal in Bash and caused variable assignments to fail or scripts to crash.
*   **The Fix:** Stripped `local` from the main orchestrator flow and ensured it is only used inside function definitions.

### C. False-Positive GUID Matching
*   **The Problem:** When a downstream node had an empty dataset, the GUID check compared two empty strings (or two `-` characters). Bash evaluated `"" == ""` as true, leading the script to believe a common snapshot existed and attempt a rollback/incremental send to a non-existent target.
*   **The Fix:** Implemented a sanity check to explicitly ignore empty or null GUIDs during the comparison loop.

### D. Recursive Path Appending
*   **The Problem:** The script originally forced a "parent/child" relationship by appending the source leaf name to the target pool (e.g., `target-pool/source-data`).
*   **The Fix:** Modified logic to treat `repl:node:<alias>:fs` as a **full literal path** if it contains a `/`, allowing for heterogeneous dataset naming across the chain.

### E. Restrictive PATH Environment
*   **The Problem:** The inherited `zfsbud` logic reset `PATH` to a minimal set (`/usr/bin:/sbin:/bin`), which broke standard utilities like `date`, `grep`, and `readlink` inside the Ubuntu containers.
*   **The Fix:** Expanded `zbud_PATH` in `zfs-transfer.lib.sh` to include `/usr/local/bin` and `/usr/local/sbin`.

---

## 3. Tomorrow's Focus: Resilience Testing

1.  **Divergence Recovery:** Manually creating "rogue" snapshots on downstream nodes to verify the `--promote --auto` healing mechanism.
2.  **Split-Brain Prevention:** Implementing a "Master Election" check to prevent two nodes from acting as Master simultaneously if the `repl:chain` is updated inconsistently.
3.  **Promotion Dry-Runs:** Adding a safety flag to show planned rollbacks before they are executed.
