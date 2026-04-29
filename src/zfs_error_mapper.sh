#!/bin/bash

# zfs_error_mapper.sh
# A utility to map monolithic ZFS send/recv errors into specific exit codes.
#
# Usage:
#   ./zfs_error_mapper.sh "zfs receive target/fs < stream"
#   ./zfs_error_mapper.sh "zfs send pool/fs@snap | ssh host zfs receive target/fs"

# Define Custom Exit Codes
readonly ERR_TARGET_MODIFIED=101
readonly ERR_NO_COMMON_SNAP=102
readonly ERR_OUT_OF_SPACE=103
readonly ERR_PERMISSION_DENIED=104
readonly ERR_DATASET_BUSY=105
readonly ERR_DATASET_NOT_FOUND=106
readonly ERR_BAD_STREAM=107
readonly ERR_RESUME_FAILED=108
readonly ERR_UNKNOWN_ZFS=199

# The command to execute
COMMAND="$1"

if [ -z "$COMMAND" ]; then
    echo "Usage: $0 \"<zfs command pipeline>\"" >&2
    exit 1
fi

TMP_ERR="/tmp/zfs_err_mapper.$$.tmp"

# Ensure temp file is cleaned up on exit
trap 'rm -f "$TMP_ERR"' EXIT

# Execute the command in a subshell, redirecting stderr to our temp file while preserving stdout.
# We use eval to handle pipelines correctly.
(eval "$COMMAND") 2> "$TMP_ERR"
EXIT_CODE=$?

# If the command succeeded, exit cleanly.
if [ $EXIT_CODE -eq 0 ]; then
    exit 0
fi

# Read the stderr output
ERR_OUTPUT=$(cat "$TMP_ERR")

# Print the original stderr back to the user's stderr so they still see it
echo "$ERR_OUTPUT" >&2

# Pattern Matching to map to specific exit codes
if echo "$ERR_OUTPUT" | grep -Eiq "destination .* has been modified"; then
    exit $ERR_TARGET_MODIFIED

elif echo "$ERR_OUTPUT" | grep -Eiq "does not match incremental source"; then
    exit $ERR_NO_COMMON_SNAP

elif echo "$ERR_OUTPUT" | grep -Eiq "out of space"; then
    exit $ERR_OUT_OF_SPACE

elif echo "$ERR_OUTPUT" | grep -Eiq "permission denied|insufficient privileges"; then
    exit $ERR_PERMISSION_DENIED

elif echo "$ERR_OUTPUT" | grep -Eiq "dataset is busy"; then
    exit $ERR_DATASET_BUSY

elif echo "$ERR_OUTPUT" | grep -Eiq "does not exist"; then
    exit $ERR_DATASET_NOT_FOUND

elif echo "$ERR_OUTPUT" | grep -Eiq "bad magic number|invalid stream|checksum mismatch"; then
    exit $ERR_BAD_STREAM

elif echo "$ERR_OUTPUT" | grep -Eiq "cannot resume send|corrupt resume token"; then
    exit $ERR_RESUME_FAILED

else
    # Fallback for unmapped ZFS errors
    exit $ERR_UNKNOWN_ZFS
fi
