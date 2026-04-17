#!/usr/bin/env bash
# zfs-fs-purge - Purge ZFS snapshots older than a specified date
set -euo pipefail

SCRIPT_NAME=$(basename "$0")
DRY_RUN=false
INPUT_FILE=""
VERBOSE=false
ONLY_SHIPPED=true

usage() {
    echo "Usage: $SCRIPT_NAME [options] [dataset] [date]"
    echo "  dataset: ZFS dataset name (optional)"
    echo "  date: Cutoff (YYYY, YYYY-MM, or YYYY-MM-DD). Snapshots <= this will be purged."
    echo "  -in file: Read snapshot list from a text file instead of live ZFS"
    echo "  -v, --verbose: Show full snapshot lists (default: truncate long lists)"
    echo "  --all: Delete all snapshots regardless of 'zfs-send:shipped' status"
    echo "  --dry-run: Preview deletions without executing"
    echo "  -h, --help: Show this help"
    exit 1
}

display_list() {
    local arr=("$@")
    local len=${#arr[@]}
    if [[ "$VERBOSE" == true || "$len" -le 11 ]]; then
        printf '    %s\n' "${arr[@]}"
    else
        printf '    %s\n' "${arr[@]:0:5}"
        echo "    ...."
        printf '    %s\n' "${arr[@]:len-5:5}"
    fi
}

# Parse args
TEMP_ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run) DRY_RUN=true; shift ;;
        -in)       INPUT_FILE="$2"; shift 2 ;;
        -v|--verbose) VERBOSE=true; shift ;;
        --all)     ONLY_SHIPPED=false; shift ;;
        -h|--help) usage ;;
        -*)        echo "Unknown option: $1"; usage ;;
        *)         TEMP_ARGS+=("$1"); shift ;;
    esac
done
set -- "${TEMP_ARGS[@]}"

# Detect if first positional arg is a date or dataset
if [[ $# -eq 1 ]]; then
    if [[ "$1" =~ ^[0-9]{4}(-[0-9]{2}){0,2}$ ]]; then
        DATE="$1"
        DATASET=""
    else
        DATASET="$1"
        DATE=""
    fi
elif [[ $# -ge 2 ]]; then
    DATASET="$1"
    DATE="$2"
else
    DATASET=""
    DATE=""
fi

[[ -z "$DATE" ]] && DATE=$(date +%Y-%m-%d)

if ! [[ "$DATE" =~ ^[0-9]{4}(-[0-9]{2}){0,2}$ ]]; then
    echo "Error: Date must be YYYY, YYYY-MM, or YYYY-MM-DD"
    exit 1
fi

# Safeguard months (keep all snapshots from these months)
CURRENT_MONTH=$(date +%Y-%m)
PREV_MONTH=$(date -d "1 month ago" +%Y-%m)

[[ "$DRY_RUN" == true ]] && echo "🔍 DRY RUN MODE"
echo "⏳ Cutoff: $DATE (snapshots with date <= cutoff will be purged)"

# Gather snapshots
if [[ -n "$INPUT_FILE" ]]; then
    if [[ ! -f "$INPUT_FILE" ]]; then
        echo "Error: Input file '$INPUT_FILE' not found."
        exit 1
    fi
    SNAPSHOTS=$(cat "$INPUT_FILE")
else
    # Fetch name and zfs-send:shipped property
    SNAPSHOTS=$(zfs list -t snap -o name,zfs-send:shipped -H) || true
fi

# Filter by dataset if specified
if [[ -n "$DATASET" ]]; then
    SNAPSHOTS=$(echo "$SNAPSHOTS" | grep -E "^${DATASET}@") || true
fi

[[ -z "$SNAPSHOTS" ]] && { echo "✅ No snapshots found."; exit 0; }

# Group by dataset
declare -A ds_snaps=()
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    ds="${line%@*}"
    ds_snaps["$ds"]+="$line"$'\n'
done <<< "$SNAPSHOTS"

# Process each dataset
for ds_name in "${!ds_snaps[@]}"; do
    echo "📦 Dataset: $ds_name"
    
    mapfile -t snaps < <(printf '%s' "${ds_snaps[$ds_name]}")
    # Sort snapshots by embedded timestamp (newest-first / back-chronological)
    # Optimized: single sed pass instead of loop avoids thousands of forks
    mapfile -t sorted_snaps < <(
        printf '%s\n' "${snaps[@]}" | \
        sed -E 's/.*([0-9]{4}-[0-9]{2}-[0-9]{2}).*([0-9]{4})$/\1-\2 &/ ; t; s/.*([0-9]{4}-[0-9]{2}-[0-9]{2}).*/\1-0000 &/ ; t; s/^/0000-00-00-0000 &/' | \
        sort -r | cut -d' ' -f2-
    )

    # Properly initialize for set -u & prevent cross-loop pollution
    unset keep_set latest_by_type latest_overall_by_type to_delete
    declare -A keep_set=() latest_by_type=() latest_overall_by_type=()
    to_delete=()

    for snap_line in "${sorted_snaps[@]}"; do
        [[ -z "$snap_line" ]] && continue
        
        # Parse name and potential shipped status
        read -r snap shipped_val <<< "$snap_line"

        # Determine if shipped
        is_shipped=false
        if [[ "$snap_line" == *"zfs-send:shipped"* ]]; then
            is_shipped=true
        elif [[ -n "$shipped_val" && "$shipped_val" != "-" ]]; then
            is_shipped=true
        fi

        # Extract YYYY-MM-DD and type safely using Bash built-in regex (no forking)
        if [[ "$snap" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
            snap_date="${BASH_REMATCH[1]}"
        else
            continue
        fi

        if [[ "$snap" =~ (min|hour|day|month) ]]; then
            snap_type="${BASH_REMATCH[1]}"
        else
            continue
        fi
        snap_month="${snap_date:0:7}"

        # 0. SAFEGUARD: Keep the single absolute latest snapshot of each type
        if [[ -z "${latest_overall_by_type[$snap_type]:-}" ]]; then
            latest_overall_by_type["$snap_type"]="$snap"
            keep_set["$snap"]=1
        fi

        # 0.5 SAFEGUARD: Only delete shipped snapshots unless --all is used
        if [[ "$ONLY_SHIPPED" == true && "$is_shipped" == false ]]; then
            keep_set["$snap"]=1
        fi

        # 1. CUTOFF: Mark for deletion if date <= specified threshold
        # (This rule respects safeguards but takes precedence over current/prev month)
        if [[ "$snap_date" == "$DATE"* || "$snap_date" < "$DATE" ]]; then
            # Only delete if not protected by safeguards
            if [[ -z "${keep_set[$snap]:-}" ]]; then
                to_delete+=("$snap")
                continue
            fi
        fi

        # 2. SAFEGUARD: Keep current & previous month entirely
        if [[ "$snap_month" == "$CURRENT_MONTH" || "$snap_month" == "$PREV_MONTH" ]]; then
            keep_set["$snap"]=1
            continue
        fi

        # 3. SAFEGUARD: Keep latest snapshot of each type per month
        # (Only for snapshots that survived the cutoff)
        key="${snap_type}_${snap_month}"
        if [[ -z "${latest_by_type[$key]:-}" ]]; then
            latest_by_type["$key"]="$snap"
            keep_set["$snap"]=1
        fi
    done

    # Identify kept snapshots
    declare -A delete_map=()
    for d in "${to_delete[@]}"; do delete_map["$d"]=1; done
    
    kept_snaps=()
    for s in "${snaps[@]}"; do
        [[ -z "$s" ]] && continue
        [[ -z "${delete_map[$s]:-}" ]] && kept_snaps+=("$s")
    done

    # Sort kept snapshots (Newest First)
    mapfile -t sorted_kept < <(
        printf '%s\n' "${kept_snaps[@]}" | \
        sed -E 's/.*([0-9]{4}-[0-9]{2}-[0-9]{2}).*([0-9]{4})$/\1-\2 &/ ; t; s/.*([0-9]{4}-[0-9]{2}-[0-9]{2}).*/\1-0000 &/ ; t; s/^/0000-00-00-0000 &/' | \
        sort -r | cut -d' ' -f2-
    )
    kept_snaps=("${sorted_kept[@]}")

    if [[ ${#kept_snaps[@]} -gt 0 ]]; then
        echo "  🛡️  Will keep ${#kept_snaps[@]} snapshot(s):"
        display_list "${kept_snaps[@]}"
    fi

    if [[ ${#to_delete[@]} -gt 0 ]]; then
        echo "  🗑️  Will delete ${#to_delete[@]} snapshot(s):"
        display_list "${to_delete[@]}"
        
        if [[ "$DRY_RUN" == false ]]; then
            echo "  ⏳ Executing deletion..."
            printf '%s\n' "${to_delete[@]}" | xargs -r -n1 zfs destroy
            echo "  ✅ Done."
        else
            echo "  🛑 DRY RUN: Skipped."
        fi
    else
        echo "  ✅ Nothing to delete."
    fi
    echo ""
done

[[ "$DRY_RUN" == true ]] && echo "🔍 DRY RUN COMPLETE" || echo "✅ All operations finished."
