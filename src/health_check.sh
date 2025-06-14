#!/bin/bash
# filepath: /home/sciencerz/Projects/eBAF/src/health_check.sh
# Standalone Health Check for eBAF (eBPF Ad Blocker Firewall)
# This script independently tests if eBAF is working correctly

# Text formatting
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RESET='\033[0m'

# Configuration
MAX_TEST_IPS=30  # Maximum number of IPs to test (to avoid excessive testing)
TEST_INTERFACE=""
ADBLOCKER_PID=""
TEST_DURATION=10
DEFAULT_BLACKLIST="spotify-stable"  # Default blacklist file in project root

# Find the adblocker binary
find_adblocker() {
    if [ -f "./bin/adblocker" ]; then
        echo "./bin/adblocker"
    elif [ -f "/usr/local/bin/adblocker" ]; then
        echo "/usr/local/bin/adblocker"
    else
        echo ""
    fi
}

# Find the wrapper script
find_wrapper() {
    if [ -f "./bin/run-adblocker.sh" ]; then
        echo "./bin/run-adblocker.sh"
    elif [ -f "/usr/local/bin/ebaf" ]; then
        echo "/usr/local/bin/ebaf"
    else
        echo ""
    fi
}

# Find the blacklist file
find_blacklist_file() {
    local blacklist_paths=(
        "./$DEFAULT_BLACKLIST"
        "./blacklists/$DEFAULT_BLACKLIST"
        "/usr/local/share/ebaf/blacklists/$DEFAULT_BLACKLIST"
    )

    for path in "${blacklist_paths[@]}"; do
        if [ -f "$path" ]; then
            echo "$path"
            return 0
        fi
    done
    
    # If default not found, try any file that could be a blacklist
    local possible_file=$(find . -type f -name "*.txt" | grep -v "/tmp/" | head -n 1)
    if [ -n "$possible_file" ]; then
        echo "$possible_file"
        return 0
    fi
    
    echo ""
    return 1
}

# Get default network interface
get_default_interface() {
    # Try to find the interface with the default route
    local default_if=$(ip -o route get 1.1.1.1 2>/dev/null | awk '{print $5}')
    
    # If still not found, return the first non-loopback interface
    if [ -z "$default_if" ] || [ "$default_if" == "lo" ]; then
        default_if=$(ip -o link show | grep -v "lo:" | head -n 1 | cut -d: -f2 | tr -d ' ')
    fi
    
    echo "$default_if"
}

# Check if eBAF is installed
check_installation() {
    echo -e "${BOLD}Checking eBAF installation...${RESET}"
    
    local adblocker_binary=$(find_adblocker)
    if [ -z "$adblocker_binary" ]; then
        echo -e "${RED}✗ eBAF binary not found. Please build or install eBAF first.${RESET}"
        return 1
    else
        echo -e "${GREEN}✓ eBAF binary found at: $adblocker_binary${RESET}"
    fi
    
    # Check for eBPF object file
    if [ -f "./bin/adblocker.bpf.o" ]; then
        echo -e "${GREEN}✓ eBPF object found at: ./bin/adblocker.bpf.o${RESET}"
    elif [ -f "/usr/local/share/ebaf/adblocker.bpf.o" ]; then
        echo -e "${GREEN}✓ eBPF object found at: /usr/local/share/ebaf/adblocker.bpf.o${RESET}"
    else
        echo -e "${RED}✗ eBPF object file not found${RESET}"
        return 1
    fi
    
    return 0
}

# Check system requirements
check_system() {
    echo -e "${BOLD}Checking system requirements...${RESET}"
    
    # Check kernel version
    local kernel_version=$(uname -r | cut -d'.' -f1,2)
    if (( $(echo "$kernel_version >= 4.18" | bc -l) )); then
        echo -e "${GREEN}✓ Kernel version $kernel_version (supported)${RESET}"
    else
        echo -e "${RED}✗ Kernel version $kernel_version may be too old for XDP${RESET}"
        echo -e "${YELLOW}  Recommended: kernel 4.18 or newer${RESET}"
        return 1
    fi
    
    # Check for libbpf
    if ldconfig -p | grep -q libbpf; then
        echo -e "${GREEN}✓ libbpf is installed${RESET}"
    else
        echo -e "${RED}✗ libbpf not found in system libraries${RESET}"
        return 1
    fi
    
    # Check for tools we'll use
    for cmd in ip ping netstat bc; do
        if ! command -v $cmd &>/dev/null; then
            echo -e "${RED}✗ Required command '$cmd' not found${RESET}"
            return 1
        fi
    done
    
    # Check for bpftool (optional)
    if ! command -v bpftool &>/dev/null; then
        echo -e "${YELLOW}! Optional command 'bpftool' not found (some tests will be skipped)${RESET}"
    fi
    
    # Check for root privileges
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}✗ This script requires root privileges${RESET}"
        echo -e "${YELLOW}  Please run with: sudo $0${RESET}"
        return 1
    fi
    
    # Check memory limits
    local memlock_limit=$(ulimit -l)
    if [ "$memlock_limit" = "unlimited" ]; then
        echo -e "${GREEN}✓ RLIMIT_MEMLOCK is unlimited${RESET}"
    else
        echo -e "${YELLOW}! Setting RLIMIT_MEMLOCK to unlimited for this session${RESET}"
        ulimit -l unlimited
        if [ $? -ne 0 ]; then
            echo -e "${RED}✗ Failed to set RLIMIT_MEMLOCK${RESET}"
            return 1
        fi
    fi
    
    return 0
}

# Extract IPs to test from the blacklist file
extract_test_targets() {
    local blacklist_file=$1
    local max_ips=$2
    
    echo -e "${BOLD}Extracting test targets from blacklist: $blacklist_file${RESET}"
    
    if [ ! -f "$blacklist_file" ]; then
        echo -e "${RED}✗ Cannot find blacklist file: $blacklist_file${RESET}"
        return 1
    fi
    
    # Create arrays to store IPs and domains
    declare -a extracted_ips
    declare -a extracted_domains
    
    # Read the blacklist file
    while read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue
        
        # Check if line is an IP address
        if [[ "$line" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            extracted_ips+=("$line")
            echo -e "${BLUE}→ Found IP: $line${RESET}"
        else
            # Assume it's a domain
            extracted_domains+=("$line")
            echo -e "${BLUE}→ Found domain: $line${RESET}"
        fi
    done < "$blacklist_file"
    
    # If we have too few IPs, try resolving the domains
    if [ ${#extracted_ips[@]} -lt $max_ips ] && [ ${#extracted_domains[@]} -gt 0 ]; then
        echo -e "${YELLOW}! Not enough direct IP addresses, resolving domains...${RESET}"
        
        for domain in "${extracted_domains[@]}"; do
            # Skip if we already have enough IPs
            if [ ${#extracted_ips[@]} -ge $max_ips ]; then
                break
            fi
            
            # Try to resolve the domain
            resolved_ip=$(host -t A "$domain" | grep "has address" | head -n 1 | awk '{print $NF}')
            if [ -n "$resolved_ip" ]; then
                extracted_ips+=("$resolved_ip")
                echo -e "${BLUE}→ Resolved $domain to $resolved_ip${RESET}"
            fi
        done
    fi
    
    # If we still have no IPs, use some well-known ones
    if [ ${#extracted_ips[@]} -eq 0 ]; then
        echo -e "${YELLOW}! No IPs found or resolved. Using fallback test IPs.${RESET}"
        extracted_ips=("1.1.1.1" "8.8.8.8" "9.9.9.9")
    fi
    
    # Limit to max_ips
    if [ ${#extracted_ips[@]} -gt $max_ips ]; then
        echo -e "${YELLOW}! Limiting test to $max_ips IPs${RESET}"
        # Print the IPs we'll test
        echo -e "${GREEN}✓ Will test ${extracted_ips[@]:0:$max_ips}${RESET}"
        
        # Write just the first max_ips to our output file
        printf "%s\n" "${extracted_ips[@]:0:$max_ips}" > "/tmp/ebaf-test-ips.txt"
    else
        echo -e "${GREEN}✓ Will test ${extracted_ips[@]}${RESET}"
        # Write all IPs to our output file
        printf "%s\n" "${extracted_ips[@]}" > "/tmp/ebaf-test-ips.txt"
    fi
}

# Start the adblocker
start_adblocker() {
    local interface=$1
    
    echo -e "${BOLD}Starting eBAF on interface $interface...${RESET}"
    
    # Try to use the wrapper first
    local wrapper=$(find_wrapper)
    if [ -n "$wrapper" ]; then
        echo -e "${BLUE}→ Using wrapper: $wrapper${RESET}"
        $wrapper $interface > /dev/null 2>&1 &
        ADBLOCKER_PID=$!
    else
        # Otherwise use the binary directly
        local adblocker=$(find_adblocker)
        echo -e "${BLUE}→ Using binary: $adblocker${RESET}"
        $adblocker $interface > /dev/null 2>&1 &
        ADBLOCKER_PID=$!
    fi
    
    # Give it a moment to start up
    sleep 2
    
    # Check if it's running
    if ps -p $ADBLOCKER_PID > /dev/null; then
        echo -e "${GREEN}✓ Started eBAF with PID $ADBLOCKER_PID${RESET}"
        return 0
    else
        echo -e "${RED}✗ Failed to start eBAF${RESET}"
        return 1
    fi
}

# Test connectivity to blacklisted IPs
test_connectivity() {
    echo -e "${BOLD}Testing connectivity to blacklisted IPs...${RESET}"
    local success=0
    local total=0
    
    # Read IPs from our temporary file
    while read -r ip; do
        echo -e "${BLUE}→ Testing connection to $ip${RESET}"
        total=$((total + 1))
        
        # Try pinging with a short timeout
        if ping -c 1 -W 2 $ip > /dev/null 2>&1; then
            echo -e "  ${RED}✗ Can still reach $ip (not blocked)${RESET}"
        else
            echo -e "  ${GREEN}✓ Cannot reach $ip (successfully blocked)${RESET}"
            success=$((success + 1))
        fi
    done < "/tmp/ebaf-test-ips.txt"
    
    # Report results
    echo -e "${BOLD}Blocking test results: $success/$total IPs blocked${RESET}"
    if [ $success -eq $total ]; then
        echo -e "${GREEN}✓ All test IPs are successfully blocked!${RESET}"
        return 0
    elif [ $success -gt 0 ]; then
        echo -e "${YELLOW}! Some IPs were blocked, but not all${RESET}"
        return 1
    else
        echo -e "${RED}✗ No IPs were blocked${RESET}"
        return 1
    fi
}

# Check if XDP is attached to the interface
check_xdp_attached() {
    local interface=$1
    
    echo -e "${BOLD}Checking XDP attachment on $interface...${RESET}"
    
    if ip link show dev $interface | grep -q "xdp"; then
        echo -e "${GREEN}✓ XDP program attached to $interface${RESET}"
        return 0
    else
        echo -e "${RED}✗ No XDP program attached to $interface${RESET}"
        return 1
    fi
}

# Clean up after tests
cleanup() {
    echo -e "${BOLD}Cleaning up...${RESET}"
    
    # Stop adblocker if running
    if [ -n "$ADBLOCKER_PID" ] && ps -p $ADBLOCKER_PID > /dev/null; then
        echo -e "${BLUE}→ Stopping eBAF (PID $ADBLOCKER_PID)${RESET}"
        kill -INT $ADBLOCKER_PID
        sleep 2
    fi
    
    # Make sure XDP programs are detached from the interface
    if [ -n "$TEST_INTERFACE" ]; then
        if ip link show dev $TEST_INTERFACE | grep -q "xdp"; then
            echo -e "${BLUE}→ Detaching XDP program from $TEST_INTERFACE${RESET}"
            ip link set dev $TEST_INTERFACE xdp off
        fi
    fi
    
    # Remove temporary files
    if [ -f /tmp/ebaf-test-ips.txt ]; then
        rm -f /tmp/ebaf-test-ips.txt
    fi
    
    echo -e "${GREEN}✓ Cleanup complete${RESET}"
}

# Run the actual health check
run_health_check() {
    echo -e "${BOLD}======= eBAF Health Check =======${RESET}"
    echo ""
    
    # Register cleanup handler for Ctrl+C
    trap cleanup INT TERM EXIT
    
    # Step 1: Check installation
    check_installation
    if [ $? -ne 0 ]; then
        echo -e "${RED}Health check failed: Installation issues detected${RESET}"
        return 1
    fi
    
    echo ""
    
    # Step 2: Check system requirements
    check_system
    if [ $? -ne 0 ]; then
        echo -e "${RED}Health check failed: System requirements not met${RESET}"
        return 1
    fi
    
    echo ""
    
    # Step 3: Find a suitable network interface
    TEST_INTERFACE=$(get_default_interface)
    if [ -z "$TEST_INTERFACE" ]; then
        echo -e "${RED}Health check failed: Could not find a suitable network interface${RESET}"
        return 1
    fi
    echo -e "${BLUE}→ Selected interface for testing: $TEST_INTERFACE${RESET}"
    
    echo ""
    
    # Step 4: Find the blacklist file and extract test targets
    local blacklist_file=$(find_blacklist_file)
    if [ -z "$blacklist_file" ]; then
        echo -e "${RED}Health check failed: Could not find a blacklist file${RESET}"
        return 1
    fi
    echo -e "${BLUE}→ Found blacklist file: $blacklist_file${RESET}"
    
    extract_test_targets "$blacklist_file" $MAX_TEST_IPS
    if [ $? -ne 0 ]; then
        echo -e "${RED}Health check failed: Could not extract test targets${RESET}"
        return 1
    fi
    
    echo ""
    
    # Step 5: Start the adblocker
    start_adblocker $TEST_INTERFACE
    if [ $? -ne 0 ]; then
        echo -e "${RED}Health check failed: Could not start eBAF${RESET}"
        return 1
    fi
    
    echo ""
    
    # Step 6: Check if XDP is attached
    check_xdp_attached $TEST_INTERFACE
    if [ $? -ne 0 ]; then
        echo -e "${RED}Health check failed: XDP program not attached${RESET}"
        return 1
    fi
    
    echo ""
    
    # Step 7: Test blocking functionality
    echo -e "${BOLD}Waiting $TEST_DURATION seconds for XDP program to initialize...${RESET}"
    sleep $TEST_DURATION
    
    test_connectivity
    local test_result=$?
    
    echo ""
    echo -e "${BOLD}======= Health Check Complete =======${RESET}"
    
    if [ $test_result -eq 0 ]; then
        echo -e "${GREEN}✅ eBAF is working correctly!${RESET}"
        return 0
    else
        echo -e "${RED}❌ eBAF is not working correctly${RESET}"
        return 1
    fi
}

# Execute the health check
run_health_check
exit $?