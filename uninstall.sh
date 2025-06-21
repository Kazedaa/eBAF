#!/bin/bash
# uninstall.sh
set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m' # No Color

INSTALL_BIN="/usr/local/bin"
INSTALL_SHARE="/usr/local/share/ebaf"

WHITELIST="whitelist.txt"
BLACKLIST="blacklist.txt"

# Progress bar function
show_progress() {
    local duration=$1
    local message=$2
    printf "${CYAN}${message}${NC}"
    
    for ((i=0; i<=20; i++)); do
        printf "${RED}█${NC}"
        sleep $(echo "scale=2; $duration/20" | bc -l 2>/dev/null || echo "0.1")
    done
    printf " ${GREEN}DONE${NC}\n"
}


print_header() {
    printf "${NC}"
    printf "${NC}"
    printf "${GREEN}${BOLD}"
    cat << 'EOF'
                   ███████╗  ██████╗    █████╗   ███████╗
                   ██╔════╝  ██╔══██╗  ██╔══██╗  ██╔════╝
                   █████╗    ██████╔╝  ███████║  █████╗  
                   ██╔══╝    ██╔══██╗  ██╔══██║  ██╔══╝  
                   ███████╗  ██████╔╝  ██║  ██║  ██║     
                   ╚══════╝  ╚═════╝   ╚═╝  ╚═╝  ╚═╝     
EOF
    printf "${NC}"
    printf "${PURPLE}══════════════════════════════════════════════════════════════════════════════════${NC}\n"
    printf "${CYAN}  eBPF Based Ad Firewall - Automated Removal Script${NC}\n"
    printf "${PURPLE}══════════════════════════════════════════════════════════════════════════════════${NC}\n\n"
}

# Print section header
print_section() {
    printf "\n${BLUE}${BOLD}▶ $1${NC}\n"
    printf "${BLUE}────────────────────────────────────────────────────────────────────────────────${NC}\n"
}

# Print status messages
print_status() {
    printf "${GREEN}  ✓ ${NC}$1\n"
}

print_warning() {
    printf "${YELLOW}  ⚠ ${NC}$1\n"
}

print_error() {
    printf "${RED}  ✗ ${NC}$1\n"
}

print_info() {
    printf "${CYAN}  ➤ ${NC}$1\n"
}

cleanup() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        print_info "Cleaning up temporary directory..."
        rm -rf "$TEMP_DIR"
    fi
}

remove_spotify_integration() {
    print_section "REMOVING SPOTIFY INTEGRATION"
    
    # Check if Spotify integration was installed
    if [ ! -f "/etc/systemd/user/ebaf-spotify.service" ] && [ ! -f "/usr/local/bin/ebaf-spotify-monitor" ]; then
        print_info "Spotify integration was not installed, skipping removal."
        return 0
    fi
    
    print_info "Cleaning up Spotify integration components..."
    
    # Get the actual user
    ACTUAL_USER="${SUDO_USER:-$USER}"
    
    # Stop and disable the user service
    if [ "$ACTUAL_USER" != "root" ]; then
        print_info "Stopping Spotify integration service..."
        
        # Stop the service first
        sudo -u "$ACTUAL_USER" XDG_RUNTIME_DIR="/run/user/$(id -u $ACTUAL_USER)" systemctl --user stop ebaf-spotify.service 2>/dev/null || true
        
        # Disable the service
        sudo -u "$ACTUAL_USER" XDG_RUNTIME_DIR="/run/user/$(id -u $ACTUAL_USER)" systemctl --user disable ebaf-spotify.service 2>/dev/null || true
        
        # Wait a moment for the service to fully stop
        sleep 2
    fi
    
    # Remove systemd service files
    print_info "Removing service files..."
    sudo rm -f /etc/systemd/user/ebaf-spotify.service
    sudo rm -f /usr/local/bin/ebaf-spotify-monitor
    
    # Remove sudoers configuration
    print_info "Removing sudo configuration..."
    sudo rm -f /etc/sudoers.d/ebaf-spotify
    
    # Only reload user daemon if we have a valid user
    if [ "$ACTUAL_USER" != "root" ]; then
        print_info "Reloading user systemd daemon (this won't affect system services)..."
        sudo -u "$ACTUAL_USER" XDG_RUNTIME_DIR="/run/user/$(id -u $ACTUAL_USER)" systemctl --user daemon-reload 2>/dev/null || true
    fi
    
    # Note: We deliberately avoid system daemon-reload unless absolutely necessary
    # Only reload if there were system-level changes (there shouldn't be any)
    
    print_status "Spotify integration removed successfully"
}

# Set up cleanup trap
trap cleanup EXIT

print_header

remove_spotify_integration

print_section "UNINSTALLATION PROCESS"

show_progress 5 "Removing eBAF files and directories... "
print_info "Removing Binaries"
sudo rm -f $INSTALL_BIN/adblocker $INSTALL_BIN/ebaf
print_info "Removing Data Files"
sudo rm -f $INSTALL_SHARE/adblocker.bpf.o
sudo rm -f $INSTALL_SHARE/ebaf_dash.py
sudo rm -f $INSTALL_BIN/ebaf-*
print_info "Removing Configuration files"
sudo rm -rf $INSTALL_BIN/$WHITELIST
sudo rm -rf $INSTALL_BIN/$BLACKLIST
print_info "Removing Directories"
sudo rm -rf $INSTALL_SHARE
print_info "Removing Temproary files"
sudo rm -f /tmp/ebaf-*

printf "\n${GREEN}${BOLD}══════════════════════════════════════════════════════════════════════════════════${NC}\n"
printf "${WHITE}${BOLD}                      UNINSTALLATION COMPLETED!                               ${NC}\n"
printf "${GREEN}${BOLD}══════════════════════════════════════════════════════════════════════════════════${NC}\n"
printf "${CYAN}  eBAF has been successfully removed from your system${NC}\n"
printf "${GREEN}${BOLD}══════════════════════════════════════════════════════════════════════════════════${NC}\n\n"