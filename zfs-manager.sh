#!/bin/bash

dir=$(dirname "$0")

# Helper functions
die() {
    echo "$@"
    exit 1
}

get_zfs_prop() {
    local prop=$1
    local ds=$2
    zfs get -H -o value "$prop" "$ds" 2>/dev/null | grep -v "^-$" | head -n 1
}

send_smtp_alert() {
    local msg=$1
    local host=$(get_zfs_prop "repl:SMTP_HOST" "$dataset")
    local port=$(get_zfs_prop "repl:SMTP_PORT" "$dataset")
    local user=$(get_zfs_prop "repl:SMTP_USER" "$dataset")
    local pass=$(get_zfs_prop "repl:SMTP_PASSWORD" "$dataset")
    local from=$(get_zfs_prop "repl:SMTP_FROM" "$dataset")
    local to=$(get_zfs_prop "repl:SMTP_TO" "$dataset")
    local proto=$(get_zfs_prop "repl:SMTP_PROTOCOL" "$dataset")
    
    [[ -z "$host" || -z "$to" ]] && return

    echo "Sending alert email to $to..."
    curl -s --url "${proto:-smtps}://${host}:${port:-465}" \
         --user "${user}:${pass}" \
         --mail-from "$from" \
         --mail-rcpt "$to" \
         --upload-file - <<EOF
From: $from
To: $to
Subject: ZFS Replication Alert: $dataset on $(hostname)
Date: $(date -R)

$msg
EOF
}

purge_shipped_snapshots() {
    local ds=$1
    local lbl=$2
    local k_count=$3
    
    echo "Performing shipped-aware rotation for $ds (label: $lbl, keep: $k_count)..."
    
    # Get snapshots matching label, sorted by creation date (newest first)
    mapfile -t snaps < <(zfs list -t snap -H -o name,zfs-send:shipped -S creation -r "$ds" | grep "@.*$lbl")
    
    local count=${#snaps[@]}
    if [[ $count -le $k_count ]]; then
        echo "  ✅ Snapshot count ($count) is within limit ($k_count). Skipping purge."
        return
    fi
    
    # Process snapshots from index k_count (0-indexed)
    for (( i=k_count; i<count; i++ )); do
        local line="${snaps[i]}"
        read -r snap_name shipped_val <<< "$line"
        
        # Check if shipped
        local is_shipped=false
        if [[ "$line" == *"zfs-send:shipped"* ]]; then
            is_shipped=true
        elif [[ -n "$shipped_val" && "$shipped_val" != "-" ]]; then
            is_shipped=true
        fi

        if [[ "$is_shipped" == true ]]; then
            echo "  🗑️  Purging old shipped snapshot: $snap_name"
            zfs destroy "$snap_name"
        else
            echo "  🛡️  KEEPING old snapshot (NOT YET SHIPPED): $snap_name"
        fi
    done
}

check_stuck_job() {
    local lock_name="${dataset//\//-}-${label}.lock"
    LOCKFILE="/tmp/${lock_name}"
    
    local timeout_val=$(get_zfs_prop "repl:TIMEOUT" "$dataset")
    [[ -z "$timeout_val" ]] && timeout_val="3600"
    
    if [[ -f "$LOCKFILE" ]]; then
        local lock_pid=$(cat "$LOCKFILE" 2>/dev/null)
        local cur_time=$(date +%s)
        local m_time=$(stat -c %Y "$LOCKFILE" 2>/dev/null || echo "$cur_time")
        local age=$((cur_time - m_time))
        
        if [[ "$age" -gt "$timeout_val" ]]; then
            send_smtp_alert "CRITICAL: ZFS replication job for $dataset ($label) is stuck. Lock file age: $((age/60)) min. Timeout: $((timeout_val/60)) min. PID recorded: $lock_pid"
            die "ERR: Stuck job detected ($age seconds old). Alert sent."
        else
            die "ERR: Replication already running ($age seconds ago). PID: $lock_pid"
        fi
    fi

    echo "$$" > "$LOCKFILE"
    trap 'rm -f "$LOCKFILE"' EXIT
}

# Params
dataset=$1
label=${2:-"frequently"}
keep_fallback=${3:-"10"}
MARK_ONLY=false
if [[ "$4" == "--mark-only" ]]; then MARK_ONLY=true; fi

# Identity & Configuration Discovery
REPL_CHAIN=$(get_zfs_prop "repl:chain" "$dataset")
REPL_USER=$(get_zfs_prop "repl:user" "$dataset")
[[ -z "$REPL_USER" ]] && REPL_USER="root"

echo "Start: $(date); Dataset: $dataset; Label: $label"

[[ -n "$dataset" ]] || die "dataset not specified"

ME=$(hostname)
NEXT_HOP=""
IS_MASTER=false
ME_INDEX=-1
RESOLVED_KEEP=$keep_fallback

if [[ -n "$REPL_CHAIN" ]]; then
    IFS=',' read -r -a nodes <<< "$REPL_CHAIN"
    for i in "${!nodes[@]}"; do
        if [[ "${nodes[i]}" == "$ME" ]]; then
            ME_INDEX=$i
            if [[ $i -eq 0 ]]; then IS_MASTER=true; fi
            if (( i < ${#nodes[@]} - 1 )); then
                NEXT_HOP="${REPL_USER}@${nodes[i+1]}"
            fi
            break
        fi
    done
    [[ $ME_INDEX -eq -1 ]] && die "ERR: Host $ME is not part of the replication chain for $dataset"
    
    # Resolve Graduated Retention
    REPL_KEEP_PROP=$(get_zfs_prop "repl:$label" "$dataset")
    if [[ -n "$REPL_KEEP_PROP" ]]; then
        IFS=',' read -r -a k_values <<< "$REPL_KEEP_PROP"
        if [[ -n "${k_values[$ME_INDEX]}" ]]; then
            RESOLVED_KEEP=${k_values[$ME_INDEX]}
            echo "INFO: Using dynamic retention for $label: $RESOLVED_KEEP (Node Index: $ME_INDEX)"
        fi
    fi
fi

if [[ "$MARK_ONLY" == true ]]; then
    if [[ "$IS_MASTER" == true ]]; then
        purge_shipped_snapshots "$dataset" "$label" "$RESOLVED_KEEP"
    fi
    exit 0
fi

# Safety check
check_stuck_job

# 1. Snapshot creation (Master only)
if [[ "$IS_MASTER" == true ]]; then
    k_flag=$(cat /var/run/keep-$label.txt 2> /dev/null)
    [[ -z "$k_flag" ]] && k_flag=999
    
    echo "Creating snapshot for $dataset (label: $label)..."
    /usr/sbin/zfs-auto-snapshot --syslog --label=$label --keep=$k_flag "$dataset"
    [[ $? -eq 0 ]] || die "ERR: snapshot creation failed"
else
    echo "INFO: Not a master host ($ME), skipping snapshot creation."
fi

# Identify local "latest" snapshot for verification
LATEST_SNAP=$(zfs list -t snap -o name -H -S creation -r "$dataset" | grep "@.*$label" | head -n 1 | cut -d'@' -f2)

# 2. Replication & Audit
if [[ -n "$NEXT_HOP" ]]; then
    echo "Replicating $dataset to $NEXT_HOP..."
    "$dir/zfsbud.sh" -s "$dataset" -e "ssh $NEXT_HOP" -v "$dataset"
    
    if [[ $? -ne 0 ]]; then
        echo 9999 > /var/run/keep-$label.txt
        die "ERR: replication to $NEXT_HOP failed"
    else
        rm /var/run/keep-$label.txt 2>/dev/null
        
        # PROPAGATE & VERIFY
        echo "Cascading: triggering downstream chain for $dataset on $NEXT_HOP"
        DOWNSTREAM_OUT=$(ssh "$NEXT_HOP" "$dir/zfs-manager.sh $dataset $label $keep_fallback" 2>&1)
        SSH_STATUS=$?
        
        # Bubble up logs
        echo "$DOWNSTREAM_OUT" | grep -v "^SENT_LIST:"
        
        if [[ $SSH_STATUS -eq 0 ]]; then
            ARRIVED_LIST=$(echo "$DOWNSTREAM_OUT" | grep "^SENT_LIST:" | cut -d':' -f2)
            
            if [[ -n "$LATEST_SNAP" && ",$ARRIVED_LIST," == *",$LATEST_SNAP,"* ]]; then
                echo "VERIFICATION SUCCESS: Snapshot $LATEST_SNAP confirmed at the end of the chain."
                
                # HOUSEKEEPING
                echo "Marking local snapshots as shipped..."
                zfs list -t snap -o name -H -r "$dataset" | grep "@.*$label" | \
                while read s; do
                    zfs set zfs-send:shipped=true "$s"
                done
                purge_shipped_snapshots "$dataset" "$label" "$RESOLVED_KEEP"
                
                echo "SENT_LIST:$ARRIVED_LIST"
            else
                send_smtp_alert "CRITICAL: Verification FAILED for $dataset. Snapshot $LATEST_SNAP NOT found in arrival receipt from $NEXT_HOP."
                die "ERR: Audit failed for $LATEST_SNAP"
            fi
        else
            die "ERR: Downstream chain processing failed on $NEXT_HOP (Code: $SSH_STATUS)."
        fi
    fi
else
    echo "INFO: End of chain ($ME). Reporting state."
    /usr/sbin/zfs-auto-snapshot --syslog --label=$label --keep=$RESOLVED_KEEP "$dataset"
    SINK_LIST=$(zfs list -t snap -o name -H -S creation -r "$dataset" | grep "@.*$label" | cut -d'@' -f2 | xargs | tr ' ' ',')
    echo "SENT_LIST:$SINK_LIST"
fi

echo "Done: $(date)"
exit 0
