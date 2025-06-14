#!/bin/bash
# filepath: test_blocking.sh
# 
# Comprehensive test script for eBAF domain blocking
# This script tests whether packets from a specific domain are being blocked
# across various protocols and packet types.

# Text formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Make sure we have root privileges
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root (sudo)${NC}"
  exit 1
fi

# Default values
DOMAIN_TO_TEST=""
INTERFACE=""
TIMEOUT=2
VERBOSE=0
CAPTURE_TRAFFIC=0
PCAP_FILE="ebaf_test_traffic.pcap"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -d|--domain)
      DOMAIN_TO_TEST="$2"
      shift 2
      ;;
    -i|--interface)
      INTERFACE="$2"
      shift 2
      ;;
    -t|--timeout)
      TIMEOUT="$2"
      shift 2
      ;;
    -v|--verbose)
      VERBOSE=1
      shift
      ;;
    -c|--capture)
      CAPTURE_TRAFFIC=1
      shift
      ;;
    -p|--pcap)
      PCAP_FILE="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [options]"
      echo "Options:"
      echo "  -d, --domain DOMAIN    Domain to test blocking for (required)"
      echo "  -i, --interface IFACE  Network interface being monitored by eBAF (required)"
      echo "  -t, --timeout SEC      Timeout for tests in seconds (default: 2)"
      echo "  -v, --verbose          Show detailed output"
      echo "  -c, --capture          Capture traffic during tests"
      echo "  -p, --pcap FILE        Specify pcap file name (default: ebaf_test_traffic.pcap)"
      echo "  -h, --help             Show this help"
      exit 0
      ;;
    *)
      echo -e "${RED}Unknown option: $1${NC}"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

# Check for required parameters
if [ -z "$DOMAIN_TO_TEST" ] || [ -z "$INTERFACE" ]; then
  echo -e "${RED}Error: Domain and interface are required${NC}"
  echo "Use --help for usage information"
  exit 1
fi

# Check for required tools
for tool in ping curl host dig nmap nc tcpdump timeout; do
  if ! command -v $tool &> /dev/null; then
    echo -e "${RED}Error: Required tool '$tool' not found${NC}"
    echo "Please install the required packages:"
    echo "sudo apt-get install iputils-ping curl dnsutils nmap tcpdump"
    exit 1
  fi
done

echo -e "${BOLD}eBAF Blocking Test for ${YELLOW}$DOMAIN_TO_TEST${NC}"
echo "==============================================="
echo -e "Interface: ${YELLOW}$INTERFACE${NC}"
echo -e "Timeout: ${YELLOW}${TIMEOUT}s${NC}"
echo "==============================================="

# Start packet capture if requested
if [ $CAPTURE_TRAFFIC -eq 1 ]; then
  echo -e "\n${YELLOW}Starting packet capture...${NC}"
  tcpdump -i $INTERFACE -w $PCAP_FILE "host $DOMAIN_TO_TEST" &
  TCPDUMP_PID=$!
  sleep 1
fi

# Resolve domain to IP addresses
echo -e "\n${BOLD}Resolving domain...${NC}"
IPS=$(host $DOMAIN_TO_TEST | grep "has address" | awk '{print $4}')

if [ -z "$IPS" ]; then
  echo -e "${RED}Failed to resolve domain $DOMAIN_TO_TEST${NC}"
  exit 1
fi

echo -e "Domain resolves to the following IPs:"
for ip in $IPS; do
  echo -e "  - ${YELLOW}$ip${NC}"
done

# Function to run a test and check result
run_test() {
  local test_name="$1"
  local test_command="$2"
  local expected_failure="$3"
  
  echo -e "\n${BOLD}Test: $test_name${NC}"
  echo -e "${YELLOW}Command: $test_command${NC}"
  
  # Run the command with a timeout
  if [ $VERBOSE -eq 1 ]; then
    result=$(timeout $TIMEOUT bash -c "$test_command" 2>&1)
    exit_code=$?
  else
    result=$(timeout $TIMEOUT bash -c "$test_command" 2>&1)
    exit_code=$?
  fi
  
  # Check if the command timed out
  if [ $exit_code -eq 124 ]; then
    if [ "$expected_failure" = "true" ]; then
      echo -e "${GREEN}✓ Test PASSED (timeout as expected - traffic blocked)${NC}"
      return 0
    else
      echo -e "${RED}✗ Test FAILED (unexpected timeout - traffic might be blocked)${NC}"
      return 1
    fi
  fi
  
  # Check if command failed as expected (blocked) or succeeded unexpectedly (not blocked)
  if [ $exit_code -ne 0 ]; then
    if [ "$expected_failure" = "true" ]; then
      echo -e "${GREEN}✓ Test PASSED (failed as expected - traffic blocked)${NC}"
      return 0
    else
      echo -e "${RED}✗ Test FAILED (unexpected failure - might be network issue)${NC}"
      if [ $VERBOSE -eq 1 ]; then
        echo -e "Output: $result"
      fi
      return 1
    fi
  else
    if [ "$expected_failure" = "true" ]; then
      echo -e "${RED}✗ Test FAILED (unexpected success - traffic NOT blocked)${NC}"
      if [ $VERBOSE -eq 1 ]; then
        echo -e "Output: $result"
      fi
      return 1
    else
      echo -e "${GREEN}✓ Test PASSED (succeeded as expected - control test)${NC}"
      return 0
    fi
  fi
}

# Function to run the blocking tests
run_blocking_tests() {
  local target="$1"
  local target_type="$2"
  local expect_blocked="$3"
  
  echo -e "\n${BOLD}Testing $target_type: ${YELLOW}$target${NC}"
  
  # ICMP (ping) test
  run_test "ICMP Echo (ping)" "ping -c 3 -W 1 $target" "$expect_blocked"
  
  # TCP connection tests to common ports
  run_test "TCP connection to port 80 (HTTP)" "nc -zv -w 1 $target 80" "$expect_blocked"
  run_test "TCP connection to port 443 (HTTPS)" "nc -zv -w 1 $target 443" "$expect_blocked"
  
  # HTTP tests
  run_test "HTTP GET request" "curl -m $TIMEOUT -s -o /dev/null -w '%{http_code}' http://$target/" "$expect_blocked"
  run_test "HTTPS GET request" "curl -m $TIMEOUT -s -k -o /dev/null -w '%{http_code}' https://$target/" "$expect_blocked"
  
  # DNS resolution test
  if [ "$target_type" = "domain" ]; then
    run_test "DNS resolution" "dig +short +timeout=$TIMEOUT $target" "$expect_blocked"
  fi
  
  # Traceroute test
  run_test "Traceroute" "traceroute -w 1 -q 1 -m 5 $target" "$expect_blocked"
  
  # TCP scan for common ports
  run_test "TCP port scan" "nmap -T4 -p 80,443,8080,8443 -sT --host-timeout ${TIMEOUT}s $target" "$expect_blocked"
}

# Run control test against a domain that shouldn't be blocked (to verify test functionality)
echo -e "\n${BOLD}Running control test against example.com (should NOT be blocked)${NC}"
run_blocking_tests "example.com" "domain" "false"

# Run tests against the target domain
echo -e "\n${BOLD}Running blocking tests against target domain${NC}"
run_blocking_tests "$DOMAIN_TO_TEST" "domain" "true"

# Test each IP address individually
for ip in $IPS; do
  run_blocking_tests "$ip" "IP" "true"
done

# Optional: Test DNS-over-HTTPS if curl supports it
if curl --help | grep -q "doh-url"; then
  echo -e "\n${BOLD}Testing DNS-over-HTTPS resolution${NC}"
  run_test "DNS-over-HTTPS" "curl --doh-url https://1.1.1.1/dns-query -s https://$DOMAIN_TO_TEST/" "true"
fi

# Stop packet capture if it was started
if [ $CAPTURE_TRAFFIC -eq 1 ]; then
  echo -e "\n${YELLOW}Stopping packet capture...${NC}"
  kill $TCPDUMP_PID 2>/dev/null
  wait $TCPDUMP_PID 2>/dev/null
  echo -e "Packet capture saved to: ${YELLOW}$PCAP_FILE${NC}"
  echo -e "You can analyze it with: tcpdump -r $PCAP_FILE -n"
fi

echo -e "\n${BOLD}Test Summary${NC}"
echo "==============================================="
echo -e "If the eBAF blocker is working correctly:"
echo -e "  - Control tests against example.com should ${GREEN}PASS${NC}"
echo -e "  - All tests against $DOMAIN_TO_TEST should ${GREEN}PASS${NC} (by failing/timing out)"
echo "==============================================="
echo -e "${YELLOW}Note: Some tests might give false results if the target is legitimately unavailable${NC}"
echo -e "${YELLOW}Use the packet capture (-c option) for more detailed analysis${NC}"