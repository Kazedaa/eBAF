#!/bin/bash

# Test if IP blocking is working correctly

# Terminal colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

if [ "$#" -lt 2 ]; then
    echo -e "${RED}Error:${NC} Missing arguments"
    echo "Usage: $0 <interface> <ip_to_test>"
    echo "Example: $0 wlan0 8.8.8.8"
    exit 1
fi

INTERFACE=$1
TEST_IP=$2

echo -e "${GREEN}===== eBPF IP Blocking Test =====${NC}"
echo "Interface: $INTERFACE"
echo "Test IP: $TEST_IP"
echo

# Create a temporary blacklist file
TMP_BLACKLIST="/tmp/ip_test_blacklist.txt"
echo "$TEST_IP" > $TMP_BLACKLIST
echo "Created temporary blacklist with IP $TEST_IP"

# Check if the IP is reachable before blocking
echo -e "${YELLOW}Testing without blocker:${NC}"
if ping -c 1 -W 2 $TEST_IP > /dev/null 2>&1; then
    echo "✓ IP is reachable (expected)"
else
    echo -e "${RED}✗ IP is NOT reachable${NC} (check your network connection)"
    exit 1
fi

# Start blocker
echo -e "\n${YELLOW}Starting IP blocker:${NC}"
echo "sudo ./bin/adblocker $INTERFACE $TMP_BLACKLIST"
echo "Press Ctrl+C to stop the test when done"
echo

# Run blocker in background
sudo ./bin/adblocker $INTERFACE $TMP_BLACKLIST &
BLOCKER_PID=$!

# Sleep to give time for the blocker to start
sleep 3

# Test if IP is now blocked
echo -e "\n${YELLOW}Testing with blocker active:${NC}"
if ping -c 1 -W 2 $TEST_IP > /dev/null 2>&1; then
    echo -e "${RED}✗ IP is still reachable${NC} (blocker not working)"
else
    echo -e "${GREEN}✓ IP is blocked${NC} (blocker working correctly)"
fi

# Clean up
echo -e "\nCleaning up..."
sudo kill $BLOCKER_PID
rm $TMP_BLACKLIST
echo "Done."

chmod +x "$0"
