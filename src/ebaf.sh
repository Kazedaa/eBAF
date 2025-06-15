#!/bin/bash
# eBPF Ad Blocker Firewall (eBAF) - Main Command

# Configuration
ADBLOCKER=""
ALL_INTERFACES=0
DEFAULT_INTERFACE=1
VERBOSE=0
SPECIFIED_INTERFACES=()
DASHBOARD_PID=""

# Print usage information
usage() {
  echo "Usage: ebaf [OPTIONS] [INTERFACE...]"
  echo ""
  echo "OPTIONS:"
  echo "  -a, --all               Run on all active interfaces"
  echo "  -d, --default           Run only on the default interface (with internet access)"
  echo "  -i, --interface IFACE   Specify an interface to use"
  echo "  -v, --verbose           Show more detailed output"
  echo "  --dash             Start the web dashboard (http://localhost:8080)"
  echo "  -h, --help              Show this help message"
  echo ""
  echo "Examples:"
  echo "  ebaf                    Run on the default interface"
  echo "  ebaf --dash        Run with web dashboard"
  echo "  ebaf -a                 Run on all active interfaces"
  echo "  ebaf -i eth0            Run on eth0 interface only"
  echo "  ebaf eth0 wlan0         Run on both eth0 and wlan0"
  exit 1
}

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
  echo "Error: This program requires root privileges."
  echo "Please run with: sudo ebaf"
  exit 1
fi

# Increase memory lock limit for eBPF maps
ulimit -l unlimited

# Parse command line arguments
ENABLE_DASHBOARD=0
while [[ $# -gt 0 ]]; do
  case $1 in
    -a|--all)
      ALL_INTERFACES=1
      DEFAULT_INTERFACE=0
      shift
      ;;
    -d|--default)
      DEFAULT_INTERFACE=1
      ALL_INTERFACES=0
      shift
      ;;
    -i|--interface)
      if [[ -z $2 || $2 == -* ]]; then
        echo "Error: Option -i requires an interface name."
        exit 1
      fi
      SPECIFIED_INTERFACES+=("$2")
      DEFAULT_INTERFACE=0
      shift 2
      ;;
    -v|--verbose)
      VERBOSE=1
      shift
      ;;
    --dash)
      ENABLE_DASHBOARD=1
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      # Assume it's an interface name
      SPECIFIED_INTERFACES+=("$1")
      DEFAULT_INTERFACE=0
      shift
      ;;
  esac
done

# Find the adblocker binary
find_adblocker() {
  if [ -f "$(dirname "$0")/adblocker" ]; then
    echo "$(dirname "$0")/adblocker"
  elif [ -f "/usr/local/bin/adblocker" ]; then
    echo "/usr/local/bin/adblocker"
  else
    echo ""
  fi
}

# Function to check if port is in use
check_port_in_use() {
  local port=$1
  if command -v netstat &> /dev/null; then
    netstat -tlnp 2>/dev/null | grep -q ":$port "
  elif command -v ss &> /dev/null; then
    ss -tlnp 2>/dev/null | grep -q ":$port "
  else
    # Fallback: try to bind to the port
    python3 -c "import socket; s=socket.socket(); s.bind(('', $port)); s.close()" 2>/dev/null
    return $?
  fi
}

# Function to kill processes on port
kill_port_processes() {
  local port=$1
  echo "🔄 Cleaning up processes on port $port..."
  
  # Kill any existing dashboard processes
  pkill -f "ebaf_dash.py" 2>/dev/null
  
  # Find and kill processes using the port
  if command -v lsof &> /dev/null; then
    local pids=$(lsof -ti:$port 2>/dev/null)
    if [ -n "$pids" ]; then
      echo "Killing processes using port $port: $pids"
      kill -9 $pids 2>/dev/null
    fi
  elif command -v fuser &> /dev/null; then
    fuser -k ${port}/tcp 2>/dev/null
  fi
  
  # Wait a moment for cleanup
  sleep 2
}

# Function to start dashboard
start_dashboard() {
  local dashboard_script=""
  local port=8080
  
  # Check if port is already in use
  if check_port_in_use $port; then
    echo "⚠️  Port $port is already in use. Attempting to clean up..."
    kill_port_processes $port
    
    # Check again after cleanup
    if check_port_in_use $port; then
      echo "❌ Port $port is still in use. Cannot start dashboard."
      return 1
    fi
  fi
  
  # Find dashboard script
  if [ -f "$(dirname "$0")/ebaf_dash.py" ]; then
    dashboard_script="$(dirname "$0")/ebaf_dash.py"
  elif [ -f "./bin/ebaf_dash.py" ]; then
    dashboard_script="./bin/ebaf_dash.py"
  elif [ -f "/usr/local/share/ebaf/ebaf_dash.py" ]; then
    dashboard_script="/usr/local/share/ebaf/ebaf_dash.py"
  else
    echo "⚠️  Warning: Dashboard script not found, skipping web dashboard"
    return 1
  fi
  
  # Check if Python3 is available
  if ! command -v python3 &> /dev/null; then
    echo "⚠️  Warning: Python3 not found, skipping web dashboard"
    return 1
  fi
  
  # Start dashboard in background
  python3 "$dashboard_script" > /dev/null 2>&1 &
  DASHBOARD_PID=$!
  
  # Save PID to file for cleanup
  echo $DASHBOARD_PID > /tmp/ebaf-dashboard.pid
  
  # Give it a moment to start
  sleep 2
  
  # Check if it's still running
  if kill -0 $DASHBOARD_PID 2>/dev/null; then
    echo "🌐 Dashboard started: http://localhost:$port (PID: $DASHBOARD_PID)"
    return 0
  else
    echo "⚠️  Warning: Failed to start dashboard"
    DASHBOARD_PID=""
    rm -f /tmp/ebaf-dashboard.pid
    return 1
  fi
}

# Function to stop dashboard
stop_dashboard() {
  echo "🛑 Stopping dashboard..."
  
  # Stop tracked PID
  if [ -n "$DASHBOARD_PID" ]; then
    kill $DASHBOARD_PID 2>/dev/null
  fi
  
  # Also kill any dashboard processes from PID file
  if [ -f /tmp/ebaf-dashboard.pid ]; then
    local saved_pid=$(cat /tmp/ebaf-dashboard.pid 2>/dev/null)
    if [ -n "$saved_pid" ]; then
      kill $saved_pid 2>/dev/null
    fi
    rm -f /tmp/ebaf-dashboard.pid
  fi
  
  # Force kill any remaining dashboard processes
  pkill -f "ebaf_dash.py" 2>/dev/null
  
  # Clean up port 8080
  kill_port_processes 8080
  
  echo "✅ Dashboard stopped"
}

# Function to get default interface
get_default_interface() {
  # Try to find the interface with the default route
  local default_if=$(ip -o route get 1.1.1.1 2>/dev/null | awk '{print $5}')
  
  # If still not found, return the first non-loopback interface
  if [ -z "$default_if" ] || [ "$default_if" == "lo" ]; then
    default_if=$(ip -o link show | grep -v "lo:" | head -n 1 | cut -d: -f2 | tr -d ' ')
  fi
  
  echo "$default_if"
}

# Function to get all active interfaces
get_active_interfaces() {
  # Get all interfaces except lo (loopback)
  ip -o link show up | grep -v "lo:" | cut -d: -f2 | tr -d ' '
}

# Function to start the adblocker on a single interface
run_on_interface() {
  local interface=$1
  
  if [ $VERBOSE -eq 1 ]; then
    echo "🚀 Starting eBAF on interface: $interface"
    "$ADBLOCKER" "$interface"
  else
    "$ADBLOCKER" "$interface" > /dev/null 2>&1
  fi
  
  # Check if started successfully
  if [ $? -eq 0 ]; then
    echo "✅ eBAF running on $interface"
  else
    echo "❌ Failed to start eBAF on $interface"
    return 1
  fi
}

# Cleanup function for graceful shutdown
cleanup() {
  printf '\n🛑 Stopping all eBAF instances...\n'
  
  # Stop dashboard first
  if [ $ENABLE_DASHBOARD -eq 1 ]; then
    stop_dashboard
  fi
  
  # Stop all adblocker processes
  pkill -f "$(basename "$ADBLOCKER")"
  
  # Clean up any remaining dashboard processes and port
  pkill -f "ebaf_dash.py" 2>/dev/null
  kill_port_processes 8080
  
  # Remove PID file
  rm -f /tmp/ebaf-dashboard.pid
  
  # Wait a moment for processes to stop
  sleep 2
  
  echo "✅ All eBAF instances stopped"
  exit 0
}

# Cleanup any existing dashboard processes on startup
cleanup_existing_dashboard() {
  if check_port_in_use 8080; then
    echo "🔄 Found existing processes on port 8080, cleaning up..."
    kill_port_processes 8080
  fi
  
  # Remove stale PID file
  rm -f /tmp/ebaf-dashboard.pid
}

# Find the adblocker binary
ADBLOCKER=$(find_adblocker)
if [ -z "$ADBLOCKER" ]; then
  echo "❌ Error: Could not find adblocker binary."
  echo "Make sure eBAF is properly compiled and installed."
  exit 1
fi

# Clean up any existing dashboard processes
cleanup_existing_dashboard

# Collect interfaces to use
INTERFACES=()

# Handle user specified interfaces
if [ ${#SPECIFIED_INTERFACES[@]} -gt 0 ]; then
  for iface in "${SPECIFIED_INTERFACES[@]}"; do
    INTERFACES+=("$iface")
  done
fi

# Add default interface if needed
if [ $DEFAULT_INTERFACE -eq 1 ]; then
  default_if=$(get_default_interface)
  if [ -n "$default_if" ]; then
    # Check if already in our list
    if [[ ! " ${INTERFACES[*]} " =~ " ${default_if} " ]]; then
      INTERFACES+=("$default_if")
    fi
    echo "🔧 Using default interface: $default_if"
  else
    echo "❌ Error: Could not determine default interface."
    exit 1
  fi
fi

# Add all active interfaces if requested
if [ $ALL_INTERFACES -eq 1 ]; then
  while read -r iface; do
    # Skip if already in our list
    if [[ ! " ${INTERFACES[*]} " =~ " ${iface} " ]]; then
      INTERFACES+=("$iface")
    fi
  done < <(get_active_interfaces)
  echo "🔧 Using all active interfaces: ${INTERFACES[*]}"
fi

# Check if we have any interfaces
if [ ${#INTERFACES[@]} -eq 0 ]; then
  echo "❌ Error: No network interfaces found or specified."
  exit 1
fi

# Validate interfaces exist
echo "🔍 Validating interfaces..."
valid_interfaces=()
for iface in "${INTERFACES[@]}"; do
  if ip link show "$iface" &>/dev/null; then
    valid_interfaces+=("$iface")
    echo "  ✅ $iface - Valid"
  else
    echo "  ❌ $iface - Interface not found"
  fi
done

if [ ${#valid_interfaces[@]} -eq 0 ]; then
  echo "❌ Error: No valid interfaces found."
  exit 1
fi

INTERFACES=("${valid_interfaces[@]}")

# Set up signal handling for graceful shutdown
trap cleanup SIGINT SIGTERM EXIT

# Start the adblocker on all selected interfaces
echo ""
echo "🚀 Starting eBAF on ${#INTERFACES[@]} interface(s)..."
failed=0

for iface in "${INTERFACES[@]}"; do
  run_on_interface "$iface" &
  if [ $? -ne 0 ]; then
    failed=$((failed + 1))
  fi
done

# Wait a moment for processes to start
sleep 2

# Check if at least one instance is running
running_count=$(pgrep -fc "$(basename "$ADBLOCKER")")
if [ $running_count -eq 0 ]; then
  echo "❌ Error: Failed to start eBAF on any interface."
  exit 1
fi

if [ $failed -gt 0 ]; then
  echo "⚠️  Warning: eBAF failed to start on $failed out of ${#INTERFACES[@]} interfaces."
else
  echo "✅ eBAF is running successfully on ${#INTERFACES[@]} interface(s)."
fi

# Start dashboard if enabled
if [ $ENABLE_DASHBOARD -eq 1 ]; then
  echo ""
  echo "🌐 Starting web dashboard..."
  start_dashboard
fi

echo ""
echo "📊 Monitoring Options:"
if [ $ENABLE_DASHBOARD -eq 1 ] && [ -n "$DASHBOARD_PID" ]; then
  echo "  • Web Dashboard: http://localhost:8080"
else
  echo "  • Web Dashboard: Use --dash flag to enable"
fi
echo "  • Health Check: ebaf-health"
echo ""
echo "💡 Use Ctrl+C to stop all instances."

# Wait for user to press Ctrl+C or process termination
wait