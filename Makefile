BUILD_DIR := build
OUTPUT := $(BUILD_DIR)/zep
IOMON := $(BUILD_DIR)/iomon
LIBS := src/zfs-common.lib.sh src/zfs-status.lib.sh src/zfs-alerts.lib.sh src/zfs-retention.lib.sh src/zfs-transfer.lib.sh
MAIN := src/zeplicator

.PHONY: all clean

all: $(IOMON) $(OUTPUT)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(IOMON): src/iomon.c | $(BUILD_DIR)
	@echo "Compiling iomon.c..."
	gcc -O3 $< -o $@

$(OUTPUT): $(LIBS) $(MAIN) | $(BUILD_DIR)
	@echo "Building $@"
	@echo "#!/bin/bash" > $@
	@echo "# zep - Compiled ZFS Replication Manager" >> $@
	@echo "# Built on: $$(date)" >> $@
	@echo "" >> $@
	@for lib in $(LIBS); do \
		echo "# --- BEGIN $$(basename $$lib) ---" >> $@; \
		grep -v "^#!" $$lib >> $@; \
		echo "# --- END $$(basename $$lib) ---" >> $@; \
		echo "" >> $@; \
	done
	@echo "# --- BEGIN zeplicator orchestrator ---" >> $@
	@grep -v "^#!" $(MAIN) | grep -v "^source " >> $@
	@echo "# --- END zeplicator orchestrator ---" >> $@
	@chmod +x $@
	@echo "Done! Generated $@"
	@echo "Artifacts available in $(BUILD_DIR)/"

clean:
	rm -rf $(BUILD_DIR)
