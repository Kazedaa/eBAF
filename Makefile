CC = gcc
CLANG = clang
STRIP = strip

SRC_DIR = src
OBJ_DIR = obj
BIN_DIR = bin

TARGET = $(BIN_DIR)/adblocker
SOURCES = $(SRC_DIR)/adblocker.c $(SRC_DIR)/ip_blacklist.c

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

all: directories $(TARGET)

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
	sudo cp $(TARGET) /usr/local/bin/
	sudo cp $(BIN_DIR)/*.bpf.o /usr/local/bin/

find-interface:
	@ip -o link show | grep -v "lo:" | cut -d':' -f2 | tr -d ' ' | sed 's/^/  /'
	@echo "Use the interface name as parameter, e.g.: sudo ./bin/adblocker wlan0"

test: all
	@echo "Creating test blacklist..."
	@echo "1.1.1.1" > /tmp/test-ip-blacklist.txt
	@echo "google.com" >> /tmp/test-ip-blacklist.txt
	@echo "facebook.com" >> /tmp/test-ip-blacklist.txt
	@echo "Run the test with: sudo ./bin/adblocker <interface>"

# Create a wrapper script that increases RLIMIT_MEMLOCK before running
wrapper:
	@echo '#!/bin/bash' > $(BIN_DIR)/run-adblocker.sh
	@echo 'if [ "$${EUID}" -ne 0 ]; then' >> $(BIN_DIR)/run-adblocker.sh
	@echo '  echo "This program requires root privileges. Please run with sudo."' >> $(BIN_DIR)/run-adblocker.sh
	@echo '  exit 1' >> $(BIN_DIR)/run-adblocker.sh
	@echo 'fi' >> $(BIN_DIR)/run-adblocker.sh
	@echo '' >> $(BIN_DIR)/run-adblocker.sh
	@echo '# Increase memory lock limit' >> $(BIN_DIR)/run-adblocker.sh
	@echo 'ulimit -l unlimited' >> $(BIN_DIR)/run-adblocker.sh
	@echo '' >> $(BIN_DIR)/run-adblocker.sh
	@echo '# Execute the adblocker with all passed arguments' >> $(BIN_DIR)/run-adblocker.sh
	@echo 'exec $(BIN_DIR)/adblocker "$$@"' >> $(BIN_DIR)/run-adblocker.sh
	@chmod +x $(BIN_DIR)/run-adblocker.sh
	@echo "Created wrapper script. Run with: sudo $(BIN_DIR)/run-adblocker.sh <interface>"

# Add a help target to explain usage
help:
	@echo "Build options:"
	@echo "  make              - Build with default blacklist (spotify-stable)"
	@echo "  make BLACKLIST=file.txt - Build with custom blacklist file"
	@echo "  make wrapper      - Create a wrapper script that handles memory limits"
	@echo ""
	@echo "Usage examples:"
	@echo "  make BLACKLIST=my-custom-blacklist.txt"
	@echo "  make clean"
	@echo "  make install"
	@echo ""
	@echo "After building, run with:"
	@echo "  sudo ./bin/adblocker <interface>     - Direct execution"
	@echo "  sudo ./bin/run-adblocker.sh <interface> - Using wrapper (recommended)"
	@echo ""
	@echo "To see available interfaces:"
	@echo "  make find-interface"

# Ensure wrapper is created by default
all: wrapper

.PHONY: all directories clean install find-interface test help wrapper