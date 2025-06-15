# eBAF - eBPF Ad Blocker Firewall
# Simple Makefile with essential targets only

# =============================================================================
# CONFIGURATION
# =============================================================================
CC = gcc
CLANG = clang
STRIP = strip

SRC_DIR = src
OBJ_DIR = obj
BIN_DIR = bin

TARGET = $(BIN_DIR)/adblocker
SOURCES = $(SRC_DIR)/adblocker.c $(SRC_DIR)/ip_blacklist.c $(SRC_DIR)/domain_store.c

INSTALL_BIN = /usr/local/bin
INSTALL_SHARE = /usr/local/share/ebaf

CFLAGS = -Wall -O2
BPF_CFLAGS = -O2 -g -target bpf -I$(LIBBPF_HEADERS) -c

# Find libbpf headers
LIBBPF_HEADERS := $(shell pkg-config --variable=includedir libbpf)
ifeq ($(LIBBPF_HEADERS),)
  LIBBPF_HEADERS := /usr/local/include
endif

# Set linker flags for libbpf
LDFLAGS := $(shell pkg-config --libs libbpf)
ifeq ($(LDFLAGS),)
  LDFLAGS := -l:libbpf.a -lelf -lz
endif

OBJECTS = $(OBJ_DIR)/adblocker.bpf.o

BLACKLIST ?= spotify-stable

# =============================================================================
# BUILD TARGETS
# =============================================================================

all: directories $(TARGET) ebaf ebaf-health ebaf-dash
directories:
	mkdir -p $(OBJ_DIR)
	mkdir -p $(BIN_DIR)

# Generate the IP blacklist C file and header from the specified blacklist file
$(SRC_DIR)/ip_blacklist.c $(SRC_DIR)/ip_blacklist.h: $(SRC_DIR)/generate_ip_blacklist.py $(BLACKLIST)
	@echo "Generating IP blacklist from $(BLACKLIST)..."
	python3 $(SRC_DIR)/generate_ip_blacklist.py $(BLACKLIST) $(SRC_DIR)/ip_blacklist.c

# Compile eBPF program (depends on the generated header)
$(OBJ_DIR)/%.bpf.o: $(SRC_DIR)/%.bpf.c $(SRC_DIR)/ip_blacklist.h
	$(CLANG) $(BPF_CFLAGS) -I$(LIBBPF_HEADERS) -c $< -o $@

$(TARGET): $(SOURCES) $(SRC_DIR)/adblocker.h $(OBJECTS) $(SRC_DIR)/ip_blacklist.h
	$(CC) $(CFLAGS) -I$(LIBBPF_HEADERS) $(SOURCES) $(LDFLAGS) -o $@
	cp $(OBJ_DIR)/adblocker.bpf.o $(BIN_DIR)/

# Create the main ebaf script
ebaf: directories
	@echo '#!/bin/bash' > $(BIN_DIR)/ebaf
	@echo '# eBPF Ad Blocker Firewall (eBAF) - Main Command' >> $(BIN_DIR)/ebaf
	@echo '' >> $(BIN_DIR)/ebaf
	@cat $(SRC_DIR)/ebaf.sh >> $(BIN_DIR)/ebaf
	@chmod +x $(BIN_DIR)/ebaf

# Create the health check script
ebaf-health: directories
	@echo '#!/bin/bash' > $(BIN_DIR)/ebaf-health
	@echo '# eBPF Ad Blocker Firewall (eBAF) - Health Check' >> $(BIN_DIR)/ebaf-health
	@echo '' >> $(BIN_DIR)/ebaf-health
	@cat $(SRC_DIR)/ebaf-health.sh >> $(BIN_DIR)/ebaf-health
	@chmod +x $(BIN_DIR)/ebaf-health

ebaf-dash: directories
	@cp $(SRC_DIR)/ebaf_dash.py $(BIN_DIR)/

# =============================================================================
# INSTALLATION TARGETS
# =============================================================================

# Install system-wide and clean project directory
install: all
	@echo "Installing eBAF system-wide..."
	@sudo mkdir -p $(INSTALL_BIN) $(INSTALL_SHARE)
	@sudo cp $(BIN_DIR)/adblocker $(INSTALL_BIN)/
	@sudo cp $(BIN_DIR)/adblocker.bpf.o $(INSTALL_SHARE)/
	@sudo cp $(BIN_DIR)/ebaf $(INSTALL_BIN)/
	@sudo cp src/ebaf_dash.py $(INSTALL_SHARE)/
	@sudo cp $(BIN_DIR)/ebaf-health $(INSTALL_BIN)/
	@sudo cp $(BIN_DIR)/ebaf_dash.py $(INSTALL_SHARE)/
	@$(MAKE) clean
	@echo ""
	@echo "Installation complete!"
	@echo "Usage: ebaf [OPTIONS] [INTERFACE...]"
	@echo "OPTIONS:"
	@echo "  -a, --all               Run on all active interfaces"
	@echo "  -d, --default           Run only on the default interface (with internet access)"
	@echo "  -i, --interface IFACE   Specify an interface to use"
	@echo "  -D, --dash              Start the web dashboard (http://localhost:8080)"
	@echo "  -q, --quiet             Suppress output (quiet mode)"
	@echo "  -h, --help              Show this help message"
	@echo "Health check: sudo ebaf-health"

# Remove installed files
uninstall:
	@echo "Uninstalling eBAF..."
	sudo rm -f $(INSTALL_BIN)/adblocker $(INSTALL_BIN)/ebaf $(INSTALL_BIN)/ebaf-health
	sudo rm -f $(INSTALL_SHARE)/adblocker.bpf.o
	sudo rm -f $(INSTALL_SHARE)/ebaf_dash.py
	sudo rm -rf $(INSTALL_SHARE)
	sudo rm -f /tmp/ebaf-*
	@echo "Uninstall complete. You can go ahead and delete the project directory if you wish."

# =============================================================================
# CLEANUP TARGETS
# =============================================================================

# Remove all build artifacts
clean:
	@echo "Cleaning build artifacts..."
	rm -rf $(OBJ_DIR) $(BIN_DIR)
	rm -f src/ip_blacklist.c src/ip_blacklist.h
	sudo rm -f /tmp/ebaf-*
	@echo "Clean complete."

# =============================================================================
# UTILITY TARGETS
# =============================================================================

# Show help information
help:
	@echo "eBAF - eBPF Ad Blocker Firewall"
	@echo ""
	@echo "BUILD OPTIONS:"
	@echo "  make                             Build with default blacklist ($(BLACKLIST))"
	@echo "  make BLACKLIST=file.txt          Build with custom blacklist file"
	@echo "  make clean                       Remove all build artifacts"
	@echo ""
	@echo "INSTALLATION:"
	@echo "  make install                     Build and install system-wide, then clean project"
	@echo "  make install BLACKLIST=file.txt  Build with custom blacklist, install, then clean"
	@echo "  make uninstall                   Remove all installed files"
	@echo ""
	@echo "UTILITIES:"
	@echo "  make help                        Show this help"
	@echo "  make find-interface              Find available network interfaces"
	@echo ""

# Find available network interfaces
find-interface:
	@echo "AVAILABLE NETWORK INTERFACES:"
	@ip -o route get 1.1.1.1 2>/dev/null | awk '{print "-Default Interface: " $$5}' || echo "  Unable to determine default interface"
	@echo "-All Interfaces"
	@ip -o link show | sed 's/^[0-9]*: /  /' | cut -d: -f1 | while read iface; do \
		status=$$(ip link show $$iface | grep -q "state UP" && echo "(UP)" || echo "(DOWN)"); \
		echo "  $$iface $$status"; \
	done

# =============================================================================
# PHONY TARGETS
# =============================================================================

.PHONY: all install uninstall clean help find-interface