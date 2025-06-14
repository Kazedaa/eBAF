CC := gcc
CLANG := clang
CFLAGS := -O2 -g -Wall -Wextra
BPF_CFLAGS := -O2 -g -target bpf -D__TARGET_ARCH_x86

LIBBPF_DIR := /usr/lib/x86_64-linux-gnu
LIBBPF_HEADERS := /usr/include

LDFLAGS := -L$(LIBBPF_DIR) -lbpf -lelf -lz

SRC_DIR := src
OBJ_DIR := obj
BIN_DIR := bin

SOURCES := $(SRC_DIR)/adblocker.c
BPF_SOURCES := $(SRC_DIR)/adblocker.bpf.c
OBJECTS := $(BPF_SOURCES:$(SRC_DIR)/%.bpf.c=$(OBJ_DIR)/%.bpf.o)

TARGET := $(BIN_DIR)/adblocker

.PHONY: all clean install find-interface test

all: $(BIN_DIR) $(OBJ_DIR) $(TARGET) $(OBJECTS)

$(BIN_DIR):
	mkdir -p $(BIN_DIR)

$(OBJ_DIR):
	mkdir -p $(OBJ_DIR)

$(OBJ_DIR)/%.bpf.o: $(SRC_DIR)/%.bpf.c
	$(CLANG) $(BPF_CFLAGS) -I$(LIBBPF_HEADERS) -c $< -o $@

$(TARGET): $(SOURCES) $(SRC_DIR)/adblocker.h $(OBJECTS)
	$(CC) $(CFLAGS) -I$(LIBBPF_HEADERS) $(SOURCES) $(LDFLAGS) -o $@
	cp $(OBJ_DIR)/adblocker.bpf.o $(BIN_DIR)/

clean:
	rm -rf $(OBJ_DIR) $(BIN_DIR)

install: all
	sudo cp $(TARGET) /usr/local/bin/
	sudo cp $(BIN_DIR)/*.bpf.o /usr/local/bin/

find-interface:
	@ip -o link show | grep -v "lo:" | cut -d':' -f2 | tr -d ' ' | sed 's/^/  /'
	@echo "Use the interface name as parameter, e.g.: sudo ./bin/adblocker wlan0 blacklist.txt"

test: all
	@echo "Creating test blacklist..."
	@echo "1.1.1.1" > /tmp/test-ip-blacklist.txt
	@echo "google.com" >> /tmp/test-ip-blacklist.txt
	@echo "facebook.com" >> /tmp/test-ip-blacklist.txt
	@echo "Run the test with: sudo ./bin/adblocker <interface> /tmp/test-ip-blacklist.txt"
