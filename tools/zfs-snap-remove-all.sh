#!/bin/bash

# zfs-snap-purge.sh - Safely remove all snapshots for a given ZFS filesystem.

# Safety: Check if dataset argument is provided
if [[ -z "$1" ]]; then
    echo "Usage: $0 <dataset>"
    exit 1
fi

dataset="$1"

# Verify dataset exists
if ! zfs list "$dataset" >/dev/null 2>&1; then
    echo "Error: Dataset '$dataset' not found."
    exit 1
fi

# List all snapshots
snaps=$(zfs list -t snapshot -H -o name -r "$dataset")

if [[ -z "$snaps" ]]; then
    echo "No snapshots found for $dataset."
    exit 0
fi

echo "The following snapshots will be destroyed:"
echo "$snaps"
echo ""

# Ask for confirmation
read -p "Are you sure you want to destroy all these snapshots? [y/N]: " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Operation aborted."
    exit 0
fi

# Destroy snapshots
echo "Destroying snapshots..."
for snap in $snaps; do
    echo "Destroying $snap..."
    zfs destroy "$snap"
    if [[ $? -ne 0 ]]; then
        echo "Failed to destroy $snap"
    fi
done

echo "Purge complete."
