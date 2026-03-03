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
SOURCES = $(SRC_DIR)/adblocker.c $(SRC_DIR)/resolver.c

INSTALL_BIN = /usr/local/bin
INSTALL_SHARE = /usr/local/share/ebaf

CFLAGS = -Wall -O2
BPF_CFLAGS = -O2 -g -target bpf -I$(LIBBPF_HEADERS) -c

# Find libbpf headers
LIBBPF_HEADERS := $(shell pkg-config --variable=includedir libbpf)
ifeq ($(LIBBPF_HEADERS),)
  LIBBPF_HEADERS := /usr/local/include
endif

# Set linker flags for libbpf and add pthread for IPv6 threaded resolver
LDFLAGS := $(shell pkg-config --libs libbpf)
ifeq ($(LDFLAGS),)
  LDFLAGS := -l:libbpf.a -lelf -lz
endif
LDFLAGS += -lpthread

OBJECTS = $(OBJ_DIR)/adblocker.bpf.o

BLACKLIST ?= spotify-blacklist.txt
WHITELIST ?= spotify-whitelist.txt

# Color definitions for output
RED = \033[0;31m
GREEN = \033[0;32m
YELLOW = \033[1;33m
BLUE = \033[0;34m
PURPLE = \033[0;35m
CYAN = \033[0;36m
WHITE = \033[1;37m
BOLD = \033[1m
NC = \033[0m

# =============================================================================
# BUILD TARGETS
# =============================================================================

all: directories $(OBJECTS) $(TARGET) ebaf ebaf-dash

directories:
	@printf "$(CYAN)Creating build directories...$(NC)\n"
	@mkdir -p $(OBJ_DIR)
	@mkdir -p $(BIN_DIR)
	@printf "$(GREEN)  ✓ Build directories created$(NC)\n"

# Compile eBPF program
$(OBJ_DIR)/%.bpf.o: $(SRC_DIR)/%.bpf.c
	@printf "$(BLUE)Compiling eBPF program...$(NC)\n"
	@$(CLANG) $(BPF_CFLAGS) -I$(LIBBPF_HEADERS) -c $< -o $@
	@printf "$(GREEN)  ✓ eBPF program compiled$(NC)\n"

# Compile main application
$(TARGET): $(SOURCES) $(SRC_DIR)/adblocker.h $(OBJECTS) $(SRC_DIR)/resolver.h
	@printf "$(BLUE)Compiling main application...$(NC)\n"
	@$(CC) $(CFLAGS) -I$(LIBBPF_HEADERS) $(SOURCES) $(LDFLAGS) -o $@
	@cp $(OBJ_DIR)/adblocker.bpf.o $(BIN_DIR)/
	@printf "$(GREEN)  ✓ Main application compiled$(NC)\n"

# Create the main ebaf script
ebaf: directories
	@printf "$(BLUE)Creating eBAF launcher script...$(NC)\n"
	@printf '#!/bin/bash\n' > $(BIN_DIR)/ebaf
	@printf '# eBPF Ad Blocker Firewall (eBAF) - Main Command\n' >> $(BIN_DIR)/ebaf
	@printf '' >> $(BIN_DIR)/ebaf
	@cat $(SRC_DIR)/ebaf.sh >> $(BIN_DIR)/ebaf
	@chmod +x $(BIN_DIR)/ebaf
	@printf "$(GREEN)  ✓ eBAF launcher script created$(NC)\n"

ebaf-dash: directories
	@printf "$(BLUE)Preparing dashboard component...$(NC)\n"
	@cp $(SRC_DIR)/ebaf_dash.py $(BIN_DIR)/
	@chmod +x $(BIN_DIR)/ebaf_dash.py
	@printf "$(GREEN)  ✓ Dashboard component ready$(NC)\n"

# =============================================================================
# INSTALLATION TARGETS
# =============================================================================

# Install system-wide and clean project directory
install: all
	@printf "\n$(PURPLE)════════════════════════════════════════════════════════════════════════════════$(NC)\n"
	@printf "$(WHITE)$(BOLD)                        INSTALLING eBAF SYSTEM-WIDE                           $(NC)\n"
	@printf "$(PURPLE)════════════════════════════════════════════════════════════════════════════════$(NC)\n"
	@printf "$(CYAN)  Installing eBAF to system directories...$(NC)\n"
	@printf "$(PURPLE)════════════════════════════════════════════════════════════════════════════════$(NC)\n\n"
	
	@printf "$(BLUE)▶ CREATING DIRECTORIES$(NC)\n"
	@printf "$(BLUE)────────────────────────────────────────────────────────────────────────────────$(NC)\n"
	@sudo mkdir -p $(INSTALL_BIN) $(INSTALL_SHARE)
	@printf "$(GREEN)  ✓ System directories created$(NC)\n\n"
	
	@printf "$(BLUE)▶ INSTALLING BINARIES$(NC)\n"
	@printf "$(BLUE)────────────────────────────────────────────────────────────────────────────────$(NC)\n"
	@sudo cp $(BIN_DIR)/adblocker $(INSTALL_BIN)/ebaf-core
	@sudo chmod +x $(INSTALL_BIN)/ebaf-core
	@printf "$(GREEN)  ✓ adblocker binary installed as ebaf-core$(NC)\n"
	@sudo cp $(BIN_DIR)/adblocker.bpf.o $(INSTALL_SHARE)/
	@printf "$(GREEN)  ✓ eBPF object file installed$(NC)\n"
	@sudo cp $(BIN_DIR)/ebaf $(INSTALL_BIN)/
	@sudo chmod +x $(INSTALL_BIN)/ebaf
	@printf "$(GREEN)  ✓ eBAF launcher installed$(NC)\n\n"
	
	@printf "$(BLUE)▶ INSTALLING COMPONENTS$(NC)\n"
	@printf "$(BLUE)────────────────────────────────────────────────────────────────────────────────$(NC)\n"
	@sudo cp $(BIN_DIR)/ebaf_dash.py $(INSTALL_BIN)/
	@sudo chmod +x $(INSTALL_BIN)/ebaf_dash.py
	@printf "$(GREEN)  ✓ Dashboard components installed$(NC)\n"
	@sudo cp "$(WHITELIST)" $(INSTALL_SHARE)/ 2>/dev/null || true
	@printf "$(GREEN)  ✓ Whitelist installed$(NC)\n"
	@sudo cp "$(BLACKLIST)" $(INSTALL_SHARE)/ 2>/dev/null || true
	@printf "$(GREEN)  ✓ Blacklist installed$(NC)\n\n"
	
	@printf "$(BLUE)▶ CLEANING BUILD ARTIFACTS$(NC)\n"
	@printf "$(BLUE)────────────────────────────────────────────────────────────────────────────────$(NC)\n"
	@$(MAKE) clean --no-print-directory
	@printf "$(GREEN)  ✓ Build artifacts cleaned$(NC)\n\n"
	
	@printf "$(GREEN)$(BOLD)════════════════════════════════════════════════════════════════════════════════$(NC)\n"
	@printf "$(WHITE)$(BOLD)                          INSTALLATION COMPLETE!                             $(NC)\n"
	@printf "$(GREEN)$(BOLD)════════════════════════════════════════════════════════════════════════════════$(NC)\n\n"
	
	@printf "$(BLUE)$(BOLD)USAGE:$(NC)\n"
	@printf "$(WHITE)  ebaf [OPTIONS] [INTERFACE...]$(NC)\n\n"
	@printf "$(BLUE)$(BOLD)OPTIONS:$(NC)\n"
	@printf "$(CYAN)  -a, --all               $(NC)Run on all active interfaces\n"
	@printf "$(CYAN)  -d, --default           $(NC)Run only on the default interface (with internet access)\n"
	@printf "$(CYAN)  -i, --interface IFACE   $(NC)Specify an interface to use\n"
	@printf "$(CYAN)  -D, --dash              $(NC)Start the web dashboard (http://localhost:8080)\n"
	@printf "$(CYAN)  -q, --quiet             $(NC)Suppress output (quiet mode)\n"
	@printf "$(CYAN)  -h, --help              $(NC)Show this help message\n\n"

# Remove installed files
uninstall:
	@printf "\n$(PURPLE)════════════════════════════════════════════════════════════════════════════════$(NC)\n"
	@printf "$(WHITE)$(BOLD)                        UNINSTALLING eBAF                                    $(NC)\n"
	@printf "$(PURPLE)════════════════════════════════════════════════════════════════════════════════$(NC)\n"
	@printf "$(CYAN)  Removing eBAF from system directories...$(NC)\n"
	@printf "$(PURPLE)════════════════════════════════════════════════════════════════════════════════$(NC)\n\n"
	
	@printf "$(BLUE)▶ REMOVING BINARIES$(NC)\n"
	@printf "$(BLUE)────────────────────────────────────────────────────────────────────────────────$(NC)\n"
	@sudo rm -f $(INSTALL_BIN)/ebaf-core $(INSTALL_BIN)/ebaf $(INSTALL_BIN)/ebaf_dash.py
	@printf "$(GREEN)  ✓ eBAF binaries removed$(NC)\n\n"
	
	@printf "$(BLUE)▶ REMOVING DATA FILES$(NC)\n"
	@printf "$(BLUE)────────────────────────────────────────────────────────────────────────────────$(NC)\n"
	@sudo rm -rf $(INSTALL_SHARE)
	@printf "$(GREEN)  ✓ Application data & Lists removed$(NC)\n\n"
	
	@printf "$(BLUE)▶ CLEANING TEMPORARY FILES$(NC)\n"
	@printf "$(BLUE)────────────────────────────────────────────────────────────────────────────────$(NC)\n"
	@sudo rm -f /tmp/ebaf-*
	@printf "$(GREEN)  ✓ Temporary files cleaned$(NC)\n\n"
	
	@printf "$(GREEN)$(BOLD)════════════════════════════════════════════════════════════════════════════════$(NC)\n"
	@printf "$(WHITE)$(BOLD)                        UNINSTALLATION COMPLETE!                             $(NC)\n"
	@printf "$(GREEN)$(BOLD)════════════════════════════════════════════════════════════════════════════════$(NC)\n"
	@printf "$(CYAN)  You can now safely delete the project directory if desired$(NC)\n"
	@printf "$(GREEN)$(BOLD)════════════════════════════════════════════════════════════════════════════════$(NC)\n\n"

# =============================================================================
# CLEANUP TARGETS
# =============================================================================

# Remove all build artifacts
clean:
	@printf "$(BLUE)Cleaning build artifacts...$(NC)\n"
	@rm -rf $(OBJ_DIR) $(BIN_DIR)
	@sudo rm -f /tmp/ebaf-* 2>/dev/null || true
	@printf "$(GREEN)  ✓ Clean complete$(NC)\n"

# =============================================================================
# UTILITY TARGETS
# =============================================================================

# Show help information
help:
	@printf "$(PURPLE)════════════════════════════════════════════════════════════════════════════════$(NC)\n"
	@printf "$(WHITE)$(BOLD)                            eBAF BUILD SYSTEM                                 $(NC)\n"
	@printf "$(PURPLE)════════════════════════════════════════════════════════════════════════════════$(NC)\n"
	@printf "$(CYAN)  eBPF Based Ad Firewall - Build and Installation Help$(NC)\n"
	@printf "$(PURPLE)════════════════════════════════════════════════════════════════════════════════$(NC)\n\n"
	
	@printf "$(BLUE)$(BOLD)BUILD OPTIONS:$(NC)\n"
	@printf "$(CYAN)  make                                                        $(NC)Build with default blacklist ($(BLACKLIST)) and whitelist ($(WHITELIST))\n"
	@printf "$(CYAN)  make clean                                                  $(NC)Remove all build artifacts\n\n"
	
	@printf "$(BLUE)$(BOLD)INSTALLATION:$(NC)\n"
	@printf "$(CYAN)  make install                                                $(NC)Build and install system-wide, then clean project\n"
	@printf "$(CYAN)  make uninstall                                              $(NC)Remove all installed files\n\n"
	
	@printf "$(BLUE)$(BOLD)UTILITIES:$(NC)\n"
	@printf "$(CYAN)  make help                                                   $(NC)Show this help\n"
	@printf "$(CYAN)  make find-interface                                         $(NC)Find available network interfaces\n\n"

# Find available network interfaces
find-interface:
	@printf "$(BLUE)$(BOLD)AVAILABLE NETWORK INTERFACES:$(NC)\n"
	@printf "$(BLUE)────────────────────────────────────────────────────────────────────────────────$(NC)\n"
	@ip -o route get 1.1.1.1 2>/dev/null | awk '{printf "$(GREEN)  ✓ Default Interface: $(WHITE)%s$(NC)\n", $$5}' || printf "$(YELLOW)  ⚠ Unable to determine default interface$(NC)\n"
	@printf "$(CYAN)$(BOLD)All Interfaces:$(NC)\n"
	@ip -o link show | sed 's/^[0-9]*: /  /' | cut -d: -f1 | while read iface; do \
		status=$$(ip link show $$iface | grep -q "state UP" && echo "$(GREEN)(UP)$(NC)" || echo "$(RED)(DOWN)$(NC)"); \
		printf "$(CYAN)  ➤ $(WHITE)$$iface $(NC)$$status\n"; \
	done

# =============================================================================
# PHONY TARGETS
# =============================================================================

.PHONY: all directories install uninstall clean help find-interface