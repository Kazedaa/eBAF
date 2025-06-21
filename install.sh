#!/bin/bash
# install.sh
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

# Real progress tracking functions with spinner
show_real_progress() {
    local pid=$1
    local message=$2
    local spinner_chars="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
    local spinner_length=${#spinner_chars}
    local i=0
    
    printf "${CYAN}${message} : ${NC}"
    
    while kill -0 $pid 2>/dev/null; do
        local char=${spinner_chars:$((i % spinner_length)):1}
        printf "\r${CYAN}${message} : ${NC}${GREEN}${char}${NC}"
        i=$((i + 1))
        sleep 0.1
    done
    
    printf "\r${CYAN}${message} : ${NC}${GREEN}✓${NC} ${GREEN}DONE${NC}\n"
    return 0
}

# Progress with step counting
show_step_progress() {
    local total_steps=$1
    local current_step=$2
    local message=$3
    
    local percent=$((current_step * 100 / total_steps))
    local filled=$((percent * 40 / 100))  # 40-char progress bar
    
    printf "\r${CYAN}${message} ${NC}["
    
    for ((i=0; i<40; i++)); do
        if [ $i -lt $filled ]; then
            printf "${GREEN}█${NC}"
        else
            printf "${WHITE}░${NC}"
        fi
    done
    
    printf "] ${GREEN}${percent}%%${NC} (${current_step}/${total_steps})"
    
    if [ $current_step -eq $total_steps ]; then
        printf " ${GREEN}COMPLETE${NC}\n"
    fi
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
    printf "${PURPLE}════════════════════════════════════════════════════════════════════════════════${NC}\n"
    printf "${CYAN}          eBPF Based Ad Firewall - Automated Installation Script${NC}\n"
    printf "${PURPLE}════════════════════════════════════════════════════════════════════════════════${NC}\n\n"
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
        echo ""
        print_info "Cleaning up temporary directory..."
        rm -rf "$TEMP_DIR"
    fi
}

ask_spotify_integration() {
    print_section "SPOTIFY INTEGRATION OPTION"
    printf "${BLUE}${BOLD}Spotify Auto-Start Integration${NC}\n"
    printf "${GREEN}This feature will:${NC}\n"
    printf "  • Automatically start eBAF when Spotify opens\n"
    printf "  • Stop eBAF when Spotify closes\n"
    printf "  • Enable web dashboard at http://localhost:8080\n"
    printf "  • Wait for eBAF to initialize before Spotify starts\n\n"
    
    printf "${YELLOW}${BOLD}Note:${NC} This requires sudo permissions for eBAF to run automatically.\n"
    printf "A sudoers rule will be created to allow passwordless eBAF execution.\n\n"
    
    # Check if stdin is connected to a terminal
    if [ ! -t 0 ]; then
        printf "${YELLOW}${BOLD}Running in non-interactive mode (piped from curl/wget).${NC}\n"
        printf "${CYAN}Spotify integration will be ${WHITE}DISABLED${CYAN} by default.${NC}\n"
        printf "${CYAN}You can re-run the installer interactively to enable it later.${NC}\n\n"
        return 1  # Skip integration
    fi
    
    while true; do
        printf "${CYAN}${BOLD}Do you want to enable Spotify integration? [y/N]: ${NC}"
        read -r response < /dev/tty  # Force reading from terminal
        
        case $response in
            [Yy]|[Yy][Ee][Ss])
                return 0  # Yes, enable integration
                ;;
            [Nn]|[Nn][Oo]|"")
                return 1  # No, skip integration
                ;;
            *)
                printf "${RED}Please answer yes (y) or no (n).${NC}\n"
                ;;
        esac
    done
}

setup_spotify_integration() {
    print_section "SPOTIFY INTEGRATION SETUP"
    print_info "Setting up automatic Spotify integration..."
    
    # Get the script directory
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    
    # Install the monitor script
    print_info "Installing Spotify monitor service..."
    sudo cp "$SCRIPT_DIR/src/scripts/ebaf-spotify-monitor.sh" /usr/local/bin/ebaf-spotify-monitor
    sudo chmod +x /usr/local/bin/ebaf-spotify-monitor
    
    # Install systemd user service
    print_info "Creating systemd user service..."
    sudo cp "$SCRIPT_DIR/src/systemd/ebaf-spotify.service" /etc/systemd/user/ebaf-spotify.service
    
    # Install sudoers configuration
    print_info "Configuring sudo permissions..."
    sudo cp "$SCRIPT_DIR/src/sudoers/ebaf-spotify" /etc/sudoers.d/ebaf-spotify
    sudo chmod 440 /etc/sudoers.d/ebaf-spotify
    
    # Validate sudoers file
    if ! sudo visudo -c -f /etc/sudoers.d/ebaf-spotify; then
        print_error "Invalid sudoers configuration! Removing file..."
        sudo rm -f /etc/sudoers.d/ebaf-spotify
        return 1
    fi
    
    # Enable the service for the current user
    print_info "Enabling service for current user..."
    
    # Get the actual user (not root)
    ACTUAL_USER="${SUDO_USER:-$USER}"
    
    if [ "$ACTUAL_USER" != "root" ]; then
        # Only reload user daemon, not system daemon
        print_info "Reloading user systemd daemon (this won't affect system services)..."
        sudo -u "$ACTUAL_USER" XDG_RUNTIME_DIR="/run/user/$(id -u $ACTUAL_USER)" systemctl --user daemon-reload
        
        # Enable and start the service
        sudo -u "$ACTUAL_USER" XDG_RUNTIME_DIR="/run/user/$(id -u $ACTUAL_USER)" systemctl --user enable ebaf-spotify.service
        
        # Start the service
        print_info "Starting Spotify integration service..."
        if sudo -u "$ACTUAL_USER" XDG_RUNTIME_DIR="/run/user/$(id -u $ACTUAL_USER)" systemctl --user start ebaf-spotify.service; then
            print_status "Spotify integration enabled for user: $ACTUAL_USER"
            print_info "eBAF will now automatically start when Spotify is opened"
            print_info "Web dashboard available at: http://localhost:8080"
            
            # Check service status
            sleep 2
            if sudo -u "$ACTUAL_USER" XDG_RUNTIME_DIR="/run/user/$(id -u $ACTUAL_USER)" systemctl --user is-active --quiet ebaf-spotify.service; then
                print_status "Service is running successfully"
            else
                print_warning "Service may not have started correctly. Check with:"
                print_info "  systemctl --user status ebaf-spotify.service"
            fi
        else
            print_error "Failed to start Spotify integration service"
            print_info "You can try starting it manually with:"
            print_info "  systemctl --user start ebaf-spotify.service"
        fi
    else
        print_warning "Running as root - please enable the service manually after installation:"
        print_info "  systemctl --user daemon-reload"
        print_info "  systemctl --user enable ebaf-spotify.service"
        print_info "  systemctl --user start ebaf-spotify.service"
    fi
}

# Set up cleanup trap
trap cleanup EXIT

print_header

print_section "REPOSITORY SETUP"
print_info "Cloning eBAF repository..."
TEMP_DIR=$(mktemp -d)

# Clone in background and show real progress
git clone "$REPO_URL" "$TEMP_DIR" >/dev/null 2>&1 &
clone_pid=$!

if show_real_progress $clone_pid "Cloning repository"; then
    wait $clone_pid
    if [ $? -eq 0 ]; then
        print_status "Repository cloned successfully"
    else
        print_error "Failed to clone repository"
        exit 1
    fi
else
    print_error "Repository clone failed"
    kill $clone_pid 2>/dev/null
    exit 1
fi

cd "$TEMP_DIR"

fix_asm_headers() {
    print_section "ASM HEADER VERIFICATION"
    print_info "Checking . header symlinks..."
    
    # Check if /usr/include/asm exists and is valid
    if [ -L /usr/include/asm ] && [ -e /usr/include/asm ]; then
        print_status "asm symlink exists and is valid"
        
        # Check for both types.h and byteorder.h specifically
        missing_headers=()
        if [ ! -f /usr/include/asm/types.h ]; then
            missing_headers+=("types.h")
        fi
        if [ ! -f /usr/include/asm/byteorder.h ]; then
            missing_headers+=("byteorder.h")
        fi
        
        if [ ${#missing_headers[@]} -eq 0 ]; then
            print_status "All required asm headers found"
            return 0
        else
            print_warning "Missing headers: ${missing_headers[*]}"
        fi
    fi
    
    print_info "Fixing asm header symlinks..."
    
    # Find the correct asm directory based on architecture
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            ASM_ARCH="x86_64"
            ;;
        aarch64|arm64)
            ASM_ARCH="aarch64"
            ;;
        armv7l|armhf)
            ASM_ARCH="arm"
            ;;
        i386|i686)
            ASM_ARCH="x86"
            ;;
        *)
            ASM_ARCH=$ARCH
            ;;
    esac
    
    # Look for the correct asm directory
    ASM_DIR=""
    for possible_dir in \
        "/usr/include/asm-generic" \
        "/usr/include/$ASM_ARCH-linux-gnu/asm" \
        "/usr/include/linux/asm-$ASM_ARCH" \
        "/usr/include/asm-$ASM_ARCH"; do
        
        if [ -d "$possible_dir" ] && [ -f "$possible_dir/types.h" ]; then
            ASM_DIR="$possible_dir"
            break
        fi
    done
    
    # If we couldn't find it automatically, search for it
    if [ -z "$ASM_DIR" ]; then
        print_info "Searching for asm/types.h..."
        TYPES_H_PATH=$(find /usr/include -name "types.h" 2>/dev/null | grep asm | head -1)
        if [ -n "$TYPES_H_PATH" ]; then
            ASM_DIR=$(dirname "$TYPES_H_PATH")
        fi
    fi
    
    if [ -n "$ASM_DIR" ]; then
        print_status "Found asm headers at: $ASM_DIR"
        # Remove existing symlink if it exists
        [ -L /usr/include/asm ] && sudo rm /usr/include/asm
        [ -d /usr/include/asm ] && sudo rm -rf /usr/include/asm
        
        # Create new symlink
        sudo ln -sf "$ASM_DIR" /usr/include/asm
        print_status "Created symlink: /usr/include/asm -> $ASM_DIR"
        
        # Verify types.h
        if [ -f /usr/include/asm/types.h ]; then
            print_status "asm/types.h is now accessible"
        else
            print_warning "asm/types.h still not found"
        fi
        
        # Handle byteorder.h specifically - it's often in a different location
        if [ ! -f /usr/include/asm/byteorder.h ]; then
            print_info "Searching for byteorder.h..."
            
            # Common locations for byteorder.h on Arch
            BYTEORDER_PATHS=(
                "/usr/include/asm-generic/byteorder.h"
                "/usr/include/$ASM_ARCH-linux-gnu/asm/byteorder.h"
                "/usr/include/linux/byteorder/little_endian.h"
                "/usr/include/linux/byteorder/big_endian.h"
            )
            
            # Try to find byteorder.h
            BYTEORDER_FOUND=""
            for path in "${BYTEORDER_PATHS[@]}"; do
                if [ -f "$path" ]; then
                    BYTEORDER_FOUND="$path"
                    break
                fi
            done
            
            # If not found in common locations, search for it
            if [ -z "$BYTEORDER_FOUND" ]; then
                BYTEORDER_FOUND=$(find /usr/include -name "byteorder.h" 2>/dev/null | head -1)
            fi
            
            if [ -n "$BYTEORDER_FOUND" ]; then
                print_status "Found byteorder.h at: $BYTEORDER_FOUND"
                sudo ln -sf "$BYTEORDER_FOUND" /usr/include/asm/byteorder.h
                print_status "Created symlink: /usr/include/asm/byteorder.h -> $BYTEORDER_FOUND"
                print_status "asm/byteorder.h is now accessible"
            else
                print_warning "byteorder.h not found"
                print_info "Creating fallback byteorder.h..."
                
                # Create a minimal byteorder.h that includes the generic one
                sudo tee /usr/include/asm/byteorder.h > /dev/null << 'EOF'
#ifndef _ASM_BYTEORDER_H
#define _ASM_BYTEORDER_H

#include <asm-generic/byteorder.h>

#endif /* _ASM_BYTEORDER_H */
EOF
                print_status "Created fallback asm/byteorder.h"
            fi
        else
            print_status "asm/byteorder.h is accessible"
        fi
        
    else
        print_error "Could not find asm/types.h automatically"
        printf "${YELLOW}You may need to install kernel headers:${NC}\n"
        printf "${CYAN}  Ubuntu/Debian: ${WHITE}sudo apt install linux-headers-\$(uname -r)${NC}\n"
        printf "${CYAN}  Fedora: ${WHITE}sudo dnf install kernel-headers kernel-devel${NC}\n"
        printf "${CYAN}  Arch: ${WHITE}sudo pacman -S linux-headers linux-api-headers${NC}\n"
    fi
}

# Install system packages
install_system_deps() {
    print_section "SYSTEM DEPENDENCIES"
    print_info "Installing required system packages..."
    
    if command -v apt-get &> /dev/null; then
        print_info "Detected APT package manager (Ubuntu/Debian)"
        
        # Package installation with real progress
        deps=("git" "libbpf-dev" "clang" "llvm" "libelf-dev" "zlib1g-dev" "gcc" "make" "python3" "net-tools" "bc")
        total_deps=${#deps[@]}
        
        # Update package lists first
        print_info "Updating package lists..."
        sudo apt-get update >/dev/null 2>&1 &
        update_pid=$!
        show_real_progress $update_pid "Updating package database"
        wait $update_pid
        
        # Install kernel headers
        print_info "Installing kernel headers..."
        sudo apt-get install -y linux-headers-$(uname -r) >/dev/null 2>&1 &
        headers_pid=$!
        show_real_progress $headers_pid "Installing kernel headers"
        wait $headers_pid
        
        # Install dependencies with step progress
        for i in "${!deps[@]}"; do
            dep="${deps[$i]}"
            step=$((i + 1))
            
            show_step_progress $total_deps $step "Installing $dep"
            sudo apt-get install -y "$dep" >/dev/null 2>&1
        done
        
    elif command -v pacman &> /dev/null; then
        print_info "Detected Pacman package manager (Arch Linux)"
        
        # Update system
        print_info "Updating system packages..."
        sudo pacman -Syu --noconfirm >/dev/null 2>&1 &
        update_pid=$!
        show_real_progress $update_pid "Updating system"
        wait $update_pid
        
        # Install dependencies
        deps=("git" "libbpf" "clang" "llvm" "libelf" "zlib" "gcc" "make" "python" "net-tools" "bc" "linux-headers" "linux-api-headers")
        total_deps=${#deps[@]}
        
        for i in "${!deps[@]}"; do
            dep="${deps[$i]}"
            step=$((i + 1))
            
            show_step_progress $total_deps $step "Installing $dep"
            sudo pacman -S --needed --noconfirm "$dep" >/dev/null 2>&1
        done
        
    elif command -v dnf &> /dev/null; then
        print_info "Detected DNF package manager (Fedora/CentOS/RHEL)"
        
        # Update repositories
        print_info "Updating package repositories..."
        sudo dnf update >/dev/null 2>&1 &
        update_pid=$!
        show_real_progress $update_pid "Updating repositories"
        wait $update_pid
        
        # Install dependencies
        deps=("git" "libbpf-devel" "clang" "llvm" "elfutils-libelf-devel" "zlib-devel" "gcc" "make" "python3" "net-tools" "bc" "kernel-headers" "kernel-devel")
        total_deps=${#deps[@]}
        
        for i in "${!deps[@]}"; do
            dep="${deps[$i]}"
            step=$((i + 1))
            
            show_step_progress $total_deps $step "Installing $dep"
            sudo dnf install -y "$dep" >/dev/null 2>&1
        done
        
    else
        print_error "Unsupported package manager"
        print_info "Please install dependencies manually"
        exit 1
    fi
    
    print_status "System dependencies installed successfully"
}

install_system_deps
fix_asm_headers

# Verify eBPF compilation works
print_section "EBPF COMPILATION TEST"
print_info "Testing eBPF compilation environment..."

cat > /tmp/test_ebpf.c << 'EOF'
#include <linux/bpf.h>
#include <asm/types.h>

int main() {
    return 0;
}
EOF

if gcc -I/usr/include -c /tmp/test_ebpf.c -o /tmp/test_ebpf.o 2>/dev/null; then
    print_status "eBPF headers test passed"
    rm -f /tmp/test_ebpf.c /tmp/test_ebpf.o
else
    print_error "eBPF headers test failed"
    printf "${YELLOW}You may need to manually fix the asm symlink:${NC}\n"
    printf "${CYAN}  1. Find asm/types.h: ${WHITE}find /usr/include -name 'types.h' | grep asm${NC}\n"
    printf "${CYAN}  2. Remove bad symlink: ${WHITE}sudo rm /usr/include/asm${NC}\n"
    printf "${CYAN}  3. Create correct symlink: ${WHITE}sudo ln -s <correct_path> /usr/include/asm${NC}\n"
fi

print_section "BUILDING AND INSTALLING eBAF"
print_info "Building and installing eBAF components..."

# Simple make install with progress
make install >/dev/null 2>&1 &
install_pid=$!
show_real_progress $install_pid "Building and installing eBAF (grab a coffee and relax ☕)"
wait $install_pid

# Ask user about Spotify integration
ENABLE_SPOTIFY_INTEGRATION=false
if ask_spotify_integration; then
    ENABLE_SPOTIFY_INTEGRATION=true
    setup_spotify_integration
else
    print_info "Skipping Spotify integration setup."
    print_info "You can manually enable it later by re-running the installer."
fi


printf "\n${GREEN}${BOLD}════════════════════════════════════════════════════════════════════════════════${NC}\n"
printf "${WHITE}${BOLD}                        INSTALLATION COMPLETED!                                ${NC}\n"
printf "${GREEN}${BOLD}════════════════════════════════════════════════════════════════════════════════${NC}\n"
printf "${CYAN}  eBAF has been successfully installed to your system${NC}\n"
printf "${GREEN}${BOLD}════════════════════════════════════════════════════════════════════════════════${NC}\n\n"

printf "${BLUE}${BOLD}USAGE:${NC}\n"
printf "${WHITE}  ebaf [OPTIONS] [INTERFACE...]${NC}\n\n"

printf "${BLUE}${BOLD}OPTIONS:${NC}\n"
printf "${CYAN}  -a, --all               ${NC}Run on all active interfaces\n"
printf "${CYAN}  -d, --default           ${NC}Run only on the default interface (with internet access)\n"
printf "${CYAN}  -i, --interface IFACE   ${NC}Specify an interface to use\n"
printf "${CYAN}  -D, --dash              ${NC}Start the web dashboard (http://localhost:8080)\n"
printf "${CYAN}  -q, --quiet             ${NC}Suppress output (quiet mode)\n"
printf "${CYAN}  -h, --help              ${NC}Show help message\n\n"

printf "${BLUE}${BOLD}USAGE:${NC}\n"
printf "${GREEN}  ✓ ${NC}Manual run: sudo ebaf -d -D\n"
printf "${GREEN}  ✓ ${NC}Run on all interfaces: sudo ebaf -a -D\n"
printf "${GREEN}  ✓ ${NC}Web dashboard: http://localhost:8080\n\n"

if [ "$ENABLE_SPOTIFY_INTEGRATION" = true ]; then
    printf "${BLUE}${BOLD}SPOTIFY INTEGRATION:${NC}\n"
    printf "${GREEN}  ✓ ${NC}Automatic start/stop with Spotify\n"
    printf "${GREEN}  ✓ ${NC}Web dashboard available at http://localhost:8080\n"
    printf "${GREEN}  ✓ ${NC}Service enabled for current user\n"
    printf "${GREEN}  ✓ ${NC}Check service status: systemctl --user status ebaf-spotify.service\n\n"
else
    printf "${BLUE}${BOLD}SPOTIFY INTEGRATION:${NC}\n"
    printf "${YELLOW}  ! ${NC}Not enabled - you can re-run installer to enable it\n\n"
fi

printf "${BLUE}${BOLD}CONFIGURATION:${NC}\n"
printf "${GREEN}  ✓ ${NC}Blacklist: /usr/local/share/ebaf/spotify-blacklist.txt\n"
printf "${GREEN}  ✓ ${NC}Whitelist: /usr/local/share/ebaf/spotify-whitelist.txt\n\n"

printf "${GREEN}${BOLD}Ready to start blocking ads with eBPF!${NC}\n"