#!/bin/bash

# build.sh - Compile Zeplicator modules into a single distributable script

OUTPUT="zeplicator-standalone.sh"

echo "Compiling iomon.c..."
gcc -O3 iomon.c -o iomon || exit 1

echo "Building ${OUTPUT}..."

cat <<EOF > "${OUTPUT}"
#!/bin/bash
# zeplicator-standalone.sh - Compiled ZFS Replication Manager
# Built on: $(date)

EOF

# 1. Append libraries (stripping shebangs)
for lib in zfs-common.lib.sh zfs-alerts.lib.sh zfs-retention.lib.sh zfs-transfer.lib.sh; do
    echo "# --- BEGIN ${lib} ---" >> "${OUTPUT}"
    grep -v "^#!" "${lib}" >> "${OUTPUT}"
    echo "# --- END ${lib} ---" >> "${OUTPUT}"
    echo "" >> "${OUTPUT}"
done

# 2. Append main orchestrator (stripping shebangs and source commands)
echo "# --- BEGIN zeplicator orchestrator ---" >> "${OUTPUT}"
grep -v "^#!" zeplicator | grep -v "^source " >> "${OUTPUT}"
echo "# --- END zeplicator orchestrator ---" >> "${OUTPUT}"

chmod +x "${OUTPUT}"
echo "Done! Generated ${OUTPUT}"
