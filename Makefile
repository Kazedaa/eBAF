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

# Default blacklist file (can be overridden with BLACKLIST=path/to/file make option)
BLACKLIST ?= spotify-stable

all: directories $(TARGET) wrapper health-check

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

install: all
	sudo mkdir -p /usr/local/bin
	sudo mkdir -p /usr/local/share/ebaf
	sudo cp $(TARGET) /usr/local/bin/
	sudo cp $(BIN_DIR)/*.bpf.o /usr/local/share/ebaf/
	sudo cp $(BIN_DIR)/run-adblocker.sh /usr/local/bin/ebaf
	sudo cp $(BIN_DIR)/health-check.sh /usr/local/bin/ebaf-check
	@echo "Installed to /usr/local/bin/ebaf"
	@echo "Run with: sudo ebaf <interface>"
	@echo "Health check: sudo ebaf-check"

# Add uninstall target to remove all installed components
uninstall:
	@echo "Uninstalling eBAF..."
	@if [ -f /usr/local/bin/adblocker ]; then \
		sudo rm -f /usr/local/bin/adblocker; \
		echo "Removed /usr/local/bin/adblocker"; \
	fi
	@if [ -f /usr/local/bin/ebaf ]; then \
		sudo rm -f /usr/local/bin/ebaf; \
		echo "Removed /usr/local/bin/ebaf"; \
	fi
	@if [ -f /usr/local/bin/ebaf-check ]; then \
		sudo rm -f /usr/local/bin/ebaf-check; \
		echo "Removed /usr/local/bin/ebaf-check"; \
	fi
	@if [ -d /usr/local/share/ebaf ]; then \
		sudo rm -rf /usr/local/share/ebaf; \
		echo "Removed /usr/local/share/ebaf"; \
	fi
	@echo "eBAF has been uninstalled successfully."

find-interface:
	@ip -o link show | grep -v "lo:" | cut -d':' -f2 | tr -d ' ' | sed 's/^/  /'
	@echo "Use the interface name as parameter, e.g.: sudo ./bin/run-adblocker.sh wlan0"

test-blacklist: directories
	@echo "Creating test blacklist..."
	@echo "# Test blacklist" > /tmp/test-ip-blacklist.txt
	@echo "1.1.1.1" >> /tmp/test-ip-blacklist.txt
	@echo "8.8.8.8" >> /tmp/test-ip-blacklist.txt
	@echo "google.com" >> /tmp/test-ip-blacklist.txt
	@make BLACKLIST=/tmp/test-ip-blacklist.txt
	@echo "Built with test blacklist"

# Create a health check script
health-check:
	@cp $(SRC_DIR)/health_check.sh $(BIN_DIR)/health-check.sh
	@chmod +x $(BIN_DIR)/health-check.sh
	@echo "Created health check script at $(BIN_DIR)/health-check.sh"
	@echo "Run with: sudo ./bin/health-check.sh"

# Create a wrapper script that increases RLIMIT_MEMLOCK before running
wrapper:
	@echo '#!/bin/bash' > $(BIN_DIR)/run-adblocker.sh
	@echo '# eBPF Ad Blocker Firewall (eBAF)' >> $(BIN_DIR)/run-adblocker.sh
	@echo '' >> $(BIN_DIR)/run-adblocker.sh
	@echo 'if [ "$${EUID}" -ne 0 ]; then' >> $(BIN_DIR)/run-adblocker.sh
	@echo '  echo "This program requires root privileges. Please run with sudo."' >> $(BIN_DIR)/run-adblocker.sh
	@echo '  exit 1' >> $(BIN_DIR)/run-adblocker.sh
	@echo 'fi' >> $(BIN_DIR)/run-adblocker.sh
	@echo '' >> $(BIN_DIR)/run-adblocker.sh
	@echo '# Increase memory lock limit for eBPF maps' >> $(BIN_DIR)/run-adblocker.sh
	@echo 'ulimit -l unlimited' >> $(BIN_DIR)/run-adblocker.sh
	@echo '' >> $(BIN_DIR)/run-adblocker.sh
	@echo '# Find the adblocker binary' >> $(BIN_DIR)/run-adblocker.sh
	@echo 'SCRIPT_DIR="$$(cd "$$(dirname "$${BASH_SOURCE[0]}")" && pwd)"' >> $(BIN_DIR)/run-adblocker.sh
	@echo 'if [ -f "$${SCRIPT_DIR}/adblocker" ]; then' >> $(BIN_DIR)/run-adblocker.sh
	@echo '  ADBLOCKER="$${SCRIPT_DIR}/adblocker"' >> $(BIN_DIR)/run-adblocker.sh
	@echo 'elif [ -f "/usr/local/bin/adblocker" ]; then' >> $(BIN_DIR)/run-adblocker.sh
	@echo '  ADBLOCKER="/usr/local/bin/adblocker"' >> $(BIN_DIR)/run-adblocker.sh
	@echo 'else' >> $(BIN_DIR)/run-adblocker.sh
	@echo '  echo "Error: Could not find adblocker binary"' >> $(BIN_DIR)/run-adblocker.sh
	@echo '  exit 1' >> $(BIN_DIR)/run-adblocker.sh
	@echo 'fi' >> $(BIN_DIR)/run-adblocker.sh
	@echo '' >> $(BIN_DIR)/run-adblocker.sh
	@echo '# Execute the adblocker with all passed arguments' >> $(BIN_DIR)/run-adblocker.sh
	@echo 'exec "$${ADBLOCKER}" "$$@"' >> $(BIN_DIR)/run-adblocker.sh
	@chmod +x $(BIN_DIR)/run-adblocker.sh

# Add a help target to explain usage
help:
	@echo "eBPF Ad Blocker Firewall (eBAF)"
	@echo ""
	@echo "Build options:"
	@echo "  make                       - Build with default blacklist (spotify-stable)"
	@echo "  make BLACKLIST=file.txt    - Build with custom blacklist file"
	@echo "  make test-blacklist        - Build with a small test blacklist"
	@echo "  make dynamic-blacklist     - Build with dynamic domain resolution"
	@echo ""
	@echo "Usage commands:"
	@echo "  make install               - Install to system"
	@echo "  make uninstall             - Remove from system"
	@echo "  make clean                 - Clean build files"
	@echo "  make find-interface        - Show available network interfaces"
	@echo "  make help                  - Show this help message"
	@echo ""
	@echo "After building, run with:"
	@echo "  sudo ./bin/adblocker       - Run using default network interface"
	@echo "  sudo ./bin/adblocker eth0  - Run on specific interface"
	@echo "  sudo ./bin/run-adblocker.sh      - Run on ALL active interfaces"
	@echo "  sudo ./bin/run-adblocker.sh -d   - Run only on default interface"
	@echo "  ./bin/health-check.sh            - Run health check"
	@echo ""
	@echo "After installing, run with:"
	@echo "  sudo adblocker            - Run using default interface"
	@echo "  sudo ebaf                 - Run on ALL active interfaces"
	@echo "  sudo ebaf -d              - Run only on default interface"
	@echo "  sudo ebaf-check           - Run health check"

.PHONY: all directories clean install uninstall find-interface test-blacklist wrapper help health-check dynamic-blacklist