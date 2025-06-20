#!/bin/bash
# uninstall.sh
set -e

REPO_URL="https://github.com/Kazedaa/eBAF.git"  # Replace with your actual repo URL
TEMP_DIR=""

cleanup() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        echo "Cleaning up temporary directory..."
        rm -rf "$TEMP_DIR"
    fi
}

# Set up cleanup trap
trap cleanup EXIT

echo "Uninstalling eBAF..."

# Check if git is available
if ! command -v git &> /dev/null; then
    echo "Git is required for uninstallation. Installing git..."
    if command -v apt-get &> /dev/null; then
        sudo apt-get update && sudo apt-get install -y git
    elif command -v pacman &> /dev/null; then
        sudo pacman -S --needed git
    elif command -v dnf &> /dev/null; then
        sudo dnf install -y git
    else
        echo "Please install git manually and run this script again"
        exit 1
    fi
fi

# Clone repository to temporary directory
echo "Cloning eBAF repository for uninstallation..."
TEMP_DIR=$(mktemp -d)
git clone "$REPO_URL" "$TEMP_DIR"
cd "$TEMP_DIR"

# Run make uninstall
if [ -f "Makefile" ]; then
    echo "Running make uninstall..."
    make uninstall
    echo "eBAF uninstalled successfully!"
else
    echo "Error: Makefile not found in repository"
    exit 1
fi