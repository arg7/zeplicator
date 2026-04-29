╔══════════════════════════════════════════════════════════════════╗
║            Zeplicator Test Console (tzepcon)                     ║
╚══════════════════════════════════════════════════════════════════╝

Welcome! This tmux session runs the Zeplicator replication test
suite in a live, observable environment.

  PANE LAYOUT
  ──────────
  pane 0 (main, left top)   — test suite output
  pane 1 (left bottom)      — SMTP debug server (alerts)
  pane 2 (right top)        — zep --status watcher
  pane 3 (right bottom)     — simulator shell (you are here)

  TEST CONTROLS (pane 3)
  ──────────────────────
  test start                 run all 14 tests
  test start --test 13 14    run only resilience tests
  test start --test 2 12     run only tests 2 and 12
  test start --skip 11 13    skip resume and resilience tests
  test stop                  abort running test suite (Ctrl-C + kill)

  SIMULATOR CHEATSHEET (pane 3)
  ──────────────────────────────
  # Isolate a node (makes it unreachable)
  sed -i '/zep-node-2.local/d' /etc/hosts

  # Restore a node
  echo '127.0.0.1 zep-node-2.local' >> /etc/hosts

  # Generate disk traffic on node1
  dd if=/dev/urandom of=/zep-node-1/test-1/junk.bin bs=1M count=10

  # Watch a specific node's snapshots
  watch -n 5 'zfs list -t snap -r zep-node-2/test-2'

  # Send keystrokes to pane 2 (status watcher)
  keystroke 'watch -n 5 zfs list -t snap -r zep-node-1/test-1'

  TEST OVERVIEW
  ─────────────
   1  INIT_CLEAN       — initial replication, clean dest
   2  INCREMENTAL       — normal incremental run
   3  FOREIGN_DATASET   — node3 has alien snapshots
   4  MISSING_PERMS     — revoked ZFS permissions
   5  DIVERGENCE        — split-brain divergence detected
   6  DIVERGENCE_OVERRIDE — -y forces through divergence
   7  NON_MASTER_SKIP   — non-master skips snapshot creation
   8  MISSING_POOL      — target pool exported
   9  STATUS            — status command works
  10  ROTATE            — retention keeps count
  11  RESUME            — interrupted transfer resumes
  12  RESUME_FAILED     — mid-transfer snapshot loss
  13  RESILIENCE_NODE2_OFFLINE — offline node, partial success
  14  RESILIENCE_NODE2_RECOVERY — restored node, full success

  TO QUIT
  ───────
  exit the tmux session with: Ctrl-B d  (detach)
  or kill everything:           tmux kill-session -t zep-test
