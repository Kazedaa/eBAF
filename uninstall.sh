#!/bin/bash
# uninstall.sh
set -e

REPO_URL="https://github.com/Kazedaa/eBAF.git"  # Replace with your actual repo URL
TEMP_DIR=""

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

print_section "DEPENDENCY CHECK"
# Check if git is available
if ! command -v git &> /dev/null; then
    print_warning "Git is required for uninstallation. Installing git..."
    if command -v apt-get &> /dev/null; then
        sudo apt-get update && sudo apt-get install -y git >/dev/null 2>&1
    elif command -v pacman &> /dev/null; then
        sudo pacman -S --needed git >/dev/null 2>&1
    elif command -v dnf &> /dev/null; then
        sudo dnf install -y git >/dev/null 2>&1
    else
        print_error "Please install git manually and run this script again"
        exit 1
    fi
    print_status "Git installed successfully"
else
    print_status "Git is available"
fi

print_section "REPOSITORY SETUP"

# Clone repository to temporary directory
print_info "Cloning eBAF repository for uninstallation..."
TEMP_DIR=$(mktemp -d)
if git clone "$REPO_URL" "$TEMP_DIR" >/dev/null 2>&1; then
    print_status "Repository cloned successfully"
else
    print_error "Failed to clone repository"
    exit 1
fi
cd "$TEMP_DIR"

print_section "UNINSTALLATION PROCESS"

# Run make uninstall
if [ -f "Makefile" ]; then
    print_info "Executing uninstallation process..."
    show_progress 5 "Removing eBAF files and directories... "
    make uninstall >/dev/null 2>&1
    
    printf "\n${GREEN}${BOLD}══════════════════════════════════════════════════════════════════════════════════${NC}\n"
    printf "${WHITE}${BOLD}                      UNINSTALLATION COMPLETED!                               ${NC}\n"
    printf "${GREEN}${BOLD}══════════════════════════════════════════════════════════════════════════════════${NC}\n"
    printf "${CYAN}  eBAF has been successfully removed from your system${NC}\n"
    printf "${GREEN}${BOLD}══════════════════════════════════════════════════════════════════════════════════${NC}\n\n"
    
    printf "${BLUE}${BOLD}REMOVED COMPONENTS:${NC}\n"
    printf "${CYAN}  ✓ ${NC}eBAF binary files\n"
    printf "${CYAN}  ✓ ${NC}eBPF object files\n"
    printf "${CYAN}  ✓ ${NC}Configuration files\n"
    printf "${CYAN}  ✓ ${NC}Dashboard components\n"
    printf "${CYAN}  ✓ ${NC}Temporary files\n\n"
    
    printf "${GREEN}${BOLD}eBAF has been completely removed from your system!${NC}\n"
else
    print_error "Makefile not found in repository"
    exit 1
fi