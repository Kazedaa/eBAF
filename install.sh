#!/bin/bash
# install.sh
set -e

echo "Installing eBAF..."

# Check dependencies
check_deps() {
    for cmd in libbpf-dev clang llvm libelf-dev zlib1g-dev gcc make python3; do
        if ! command -v $cmd &> /dev/null; then
            echo "Missing dependency: $cmd"
            exit 1
        fi
    done
}

fix_asm_headers() {
    echo "Checking asm header symlinks..."
    
    # Check if /usr/include/asm exists and is valid
    if [ -L /usr/include/asm ] && [ -e /usr/include/asm ]; then
        echo "asm symlink exists and is valid"
        return 0
    fi
    
    echo "Fixing asm header symlinks..."
    
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
        echo "Searching for asm/types.h..."
        TYPES_H_PATH=$(find /usr/include -name "types.h" 2>/dev/null | grep asm | head -1)
        if [ -n "$TYPES_H_PATH" ]; then
            ASM_DIR=$(dirname "$TYPES_H_PATH")
        fi
    fi
    
    if [ -n "$ASM_DIR" ]; then
        echo "Found asm headers at: $ASM_DIR"
        # Remove existing symlink if it exists
        [ -L /usr/include/asm ] && rm /usr/include/asm
        [ -d /usr/include/asm ] && rm -rf /usr/include/asm
        
        # Create new symlink
        ln -sf "$ASM_DIR" /usr/include/asm
        echo "Created symlink: /usr/include/asm -> $ASM_DIR"
        
        # Verify the fix
        if [ -f /usr/include/asm/types.h ]; then
            echo "✓ asm/types.h is now accessible"
        else
            echo "✗ Warning: asm/types.h still not found"
        fi
    else
        echo "✗ Could not find asm/types.h automatically"
        echo "You may need to install kernel headers:"
        echo "  Ubuntu/Debian: sudo apt install linux-headers-\$(uname -r)"
        echo "  Fedora: sudo dnf install kernel-headers kernel-devel"
        echo "  Arch: sudo pacman -S linux-headers"
    fi
}

# Install system packages
install_system_deps() {
    if command -v apt-get &> /dev/null; then
        sudo apt-get update
        sudo apt-get install libbpf-dev clang llvm libelf-dev zlib1g-dev gcc make python3 linux-headers-\$(uname -r)

        sudo apt update
        sudo apt install net-tools
    elif command -v pacman &> /dev/null; then
        sudo pacman -Syu
        sudo pacman -S --needed libbpf clang llvm libelf zlib gcc make python net-tools bc linux-headers
    elif command -v dnf &> /dev/null; then
        sudo dnf update
        sudo dnf install -y libbpf-devel clang llvm elfutils-libelf-devel zlib-devel gcc make python3 net-tools bc kernel-headers kernel-devel
    else
        echo "Please install dependencies manually"
        exit 1
    fi
}

check_deps
install_system_deps
fix_asm_headers

# Verify eBPF compilation works
echo "Testing eBPF compilation..."
cat > /tmp/test_ebpf.c << 'EOF'
#include <linux/bpf.h>
#include <asm/types.h>

int main() {
    return 0;
}
EOF

if gcc -I/usr/include -c /tmp/test_ebpf.c -o /tmp/test_ebpf.o 2>/dev/null; then
    echo "✓ eBPF headers test passed"
    rm -f /tmp/test_ebpf.c /tmp/test_ebpf.o
else
    echo "✗ eBPF headers test failed"
    echo "You may need to manually fix the asm symlink:"
    echo "  1. Find asm/types.h: find /usr/include -name 'types.h' | grep asm"
    echo "  2. Remove bad symlink: sudo rm /usr/include/asm"
    echo "  3. Create correct symlink: sudo ln -s <correct_path> /usr/include/asm"
fi

make install
echo "eBAF installed successfully!"