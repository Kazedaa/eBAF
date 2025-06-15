CC = gcc
CLANG = clang
STRIP = strip

SRC_DIR = src
OBJ_DIR = obj
BIN_DIR = bin

TARGET = $(BIN_DIR)/adblocker
SOURCES = $(SRC_DIR)/adblocker.c $(SRC_DIR)/ip_blacklist.c $(SRC_DIR)/domain_store.c

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

all: directories $(TARGET) ebaf ebaf-health ebaf-dash ebaf-cleanup

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

clean:
	rm -rf $(OBJ_DIR) $(BIN_DIR)
	rm -f $(SRC_DIR)/ip_blacklist.h $(SRC_DIR)/ip_blacklist.c

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
	@cat $(SRC_DIR)/health_check.sh >> $(BIN_DIR)/ebaf-health
	@chmod +x $(BIN_DIR)/ebaf-health

# Create cleanup script
ebaf-cleanup: directories
	@echo '#!/bin/bash' > $(BIN_DIR)/ebaf-cleanup
	@echo '# eBAF Cleanup Utility' >> $(BIN_DIR)/ebaf-cleanup
	@echo '' >> $(BIN_DIR)/ebaf-cleanup
	@cat $(SRC_DIR)/ebaf_cleanup.sh >> $(BIN_DIR)/ebaf-cleanup
	@chmod +x $(BIN_DIR)/ebaf-cleanup

install: all
	@echo "Installing eBAF..."
	@sudo mkdir -p /usr/local/share/ebaf
	@sudo cp $(BIN_DIR)/adblocker /usr/local/bin/
	@sudo cp $(BIN_DIR)/adblocker.bpf.o /usr/local/share/ebaf/
	@sudo cp $(BIN_DIR)/ebaf /usr/local/bin/
	@sudo cp $(BIN_DIR)/ebaf-health /usr/local/bin/
	@sudo cp $(BIN_DIR)/ebaf-dash /usr/local/bin/
	@sudo cp $(BIN_DIR)/ebaf-cleanup /usr/local/bin/
	@sudo cp $(BIN_DIR)/ebaf_dash.py /usr/local/share/ebaf/
	@echo "eBAF has been installed successfully."

uninstall:
	@echo "Uninstalling eBAF..."
	@sudo rm -f /usr/local/bin/adblocker /usr/local/bin/ebaf /usr/local/bin/ebaf-health /usr/local/bin/ebaf-dash /usr/local/bin/ebaf-cleanup
	@sudo rm -rf /usr/local/share/ebaf
	@echo "eBAF has been uninstalled successfully."

find-interface:
	@echo "Available network interfaces:"
	@ip -o link show | grep -v "lo:" | cut -d':' -f2 | tr -d ' ' | sed 's/^/  /'

test-blacklist: directories
	@echo "Creating test blacklist..."
	@echo "# Test blacklist" > /tmp/test-ip-blacklist.txt
	@echo "1.1.1.1" >> /tmp/test-ip-blacklist.txt
	@echo "8.8.8.8" >> /tmp/test-ip-blacklist.txt
	@echo "google.com" >> /tmp/test-ip-blacklist.txt
	@make BLACKLIST=/tmp/test-ip-blacklist.txt
	@echo "Built with test blacklist"

help:
	@echo "eBPF Ad Blocker Firewall (eBAF)"
	@echo ""
	@echo "Build options:"
	@echo "  make                       - Build with default blacklist (spotify-stable)"
	@echo "  make BLACKLIST=file.txt    - Build with custom blacklist file"
	@echo "  make test-blacklist        - Build with a small test blacklist"
	@echo ""
	@echo "Installation:"
	@echo "  sudo make install          - Install eBAF system-wide"
	@echo "  sudo make uninstall        - Remove eBAF from system"
	@echo ""
	@echo "Usage:"
	@echo "  sudo ebaf                  - Run on default interface"
	@echo "  sudo ebaf -a               - Run on all interfaces"
	@echo "  sudo ebaf-health           - Run health check"
	@echo ""

.PHONY: all directories clean install uninstall find-interface test-blacklist help ebaf ebaf-health ebaf-dash