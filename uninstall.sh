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

print_header() {
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

print_section() {
    printf "\n${BLUE}${BOLD}▶ $1${NC}\n"
    printf "${BLUE}────────────────────────────────────────────────────────────────────────────────${NC}\n"
}

print_status() { printf "${GREEN}  ✓ ${NC}$1\n"; }
print_info() { printf "${CYAN}  ➤ ${NC}$1\n"; }

remove_spotify_integration() {
    print_section "REMOVING SPOTIFY INTEGRATION"
    
    if [ ! -f "/etc/systemd/system/ebaf-spotify.service" ] && [ ! -f "/usr/local/bin/ebaf-spotify-monitor" ] && [ ! -f "/etc/systemd/system/ebaf.service" ]; then
        print_info "Spotify integration was not installed, skipping removal."
        return 0
    fi
    
    print_info "Cleaning up Spotify integration components..."
    
    # Safely stop and disable the system service
    print_info "Stopping Spotify integration service..."
    sudo systemctl stop ebaf.service 2>/dev/null || true
    sudo systemctl disable ebaf.service 2>/dev/null || true
    
    print_info "Removing service files..."
    sudo rm -f /etc/systemd/system/ebaf.service
    
    # Remove old legacy sudoers file just in case it exists
    sudo rm -f /etc/sudoers.d/ebaf-spotify 2>/dev/null || true
    
    print_info "Reloading systemd daemon..."
    sudo systemctl daemon-reload
    
    print_status "Spotify integration removed successfully"
}

print_header

remove_spotify_integration

print_section "UNINSTALLATION PROCESS"

print_info "Removing Binaries..."
sudo rm -f $INSTALL_BIN/ebaf-core $INSTALL_BIN/ebaf $INSTALL_BIN/ebaf_dash.py

print_info "Removing Application Data & Lists..."
sudo rm -rf $INSTALL_SHARE

print_info "Removing Temporary Tracking Files..."
sudo rm -f /tmp/ebaf-*

printf "\n${GREEN}${BOLD}══════════════════════════════════════════════════════════════════════════════════${NC}\n"
printf "${WHITE}${BOLD}                      UNINSTALLATION COMPLETED!                               ${NC}\n"
printf "${GREEN}${BOLD}══════════════════════════════════════════════════════════════════════════════════${NC}\n"
printf "${CYAN}  eBAF has been successfully removed from your system${NC}\n"
printf "${GREEN}${BOLD}══════════════════════════════════════════════════════════════════════════════════${NC}\n\n"