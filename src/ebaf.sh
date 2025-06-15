#!/bin/bash
# eBPF Ad Blocker Firewall (eBAF) - Main Command
# This script manages the eBAF ad blocker by:
# 1. Parsing command-line options to determine target interfaces
# 2. Finding and executing the adblocker binary on specified interfaces
# 3. Optionally starting a web dashboard for monitoring
# 4. Handling graceful cleanup on exit

# =============================================================================
# CONFIGURATION AND INITIALIZATION
# =============================================================================

# Global configuration variables
ADBLOCKER=""                    # Path to the adblocker binary
ALL_INTERFACES=0               # Flag: run on all active interfaces
DEFAULT_INTERFACE=1            # Flag: run on default interface (default behavior)
SPECIFIED_INTERFACES=()        # Array: user-specified interfaces
DASHBOARD_PID=""              # PID of the running dashboard process
ENABLE_DASHBOARD=0            # Flag: whether to start dashboard
QUIET_MODE=0                  # Flag: suppress output

# Print usage information and exit
usage() {
    cat << EOF
Usage: ebaf [OPTIONS] [INTERFACE...]

OPTIONS:
  -a, --all               Run on all active interfaces
  -d, --default           Run only on the default interface (with internet access)
  -i, --interface IFACE   Specify an interface to use
  -D, --dash              Start the web dashboard (http://localhost:8080)
  -q, --quiet             Suppress output (quiet mode)
  -h, --help              Show this help message

EOF
    exit 1
}

# Function to handle output based on quiet mode
output() {
    if [ $QUIET_MODE -eq 0 ]; then
        echo "$@"
    fi
}

# Root privilege check - eBPF programs require elevated privileges
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This program requires root privileges."
    echo "Please run with: sudo ebaf"
    exit 1
fi

# Increase memory lock limit for eBPF maps
ulimit -l unlimited

# =============================================================================
# COMMAND LINE ARGUMENT PARSING
# =============================================================================

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
                echo "ERROR: Option -i requires an interface name."
                exit 1
            fi
            SPECIFIED_INTERFACES+=("$2")
            DEFAULT_INTERFACE=0
            shift 2
            ;;
        -D|--dash)
            ENABLE_DASHBOARD=1
            shift
            ;;
        -q|--quiet)
            QUIET_MODE=1
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

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Function: find_adblocker
# Purpose: Locate the adblocker binary in common installation paths
find_adblocker() {
    local paths=(
        "/usr/local/bin/adblocker"
        "./bin/adblocker"
    )
    
    for path in "${paths[@]}"; do
        if [ -f "$path" ]; then
            echo "$path"
            return 0
        fi
    done
    
    return 1
}

# Function: get_default_interface
# Purpose: Determine the default network interface with internet access
get_default_interface() {
    # Try to get the interface used for the default route
    local default_route=$(ip route | grep '^default' | head -n1)
    if [ -n "$default_route" ]; then
        echo "$default_route" | awk '{print $5}'
    else
        # Fallback: get the first non-loopback interface
        ip -o link show | grep -v "lo:" | head -n1 | cut -d: -f2 | tr -d ' '
    fi
}

# Function: get_active_interfaces
# Purpose: Get all active network interfaces (excluding loopback)
get_active_interfaces() {
    ip -o link show | grep 'state UP' | grep -v "lo:" | cut -d: -f2 | tr -d ' '
}

# Function: start_dashboard
# Purpose: Start the web dashboard for monitoring eBAF statistics
start_dashboard() {
    local dashboard_script=""
    local port=8080
    
    output "Initializing dashboard startup..."
    
    # Clean up any existing dashboard processes first
    output "Cleaning up existing dashboard processes..."
    pkill -f "ebaf_dash.py" 2>/dev/null
    sleep 2
    
    # Force kill any remaining processes on port 8080
    if command -v lsof &> /dev/null; then
        local pids=$(lsof -ti:$port 2>/dev/null)
        if [ -n "$pids" ]; then
            output "Killing processes on port $port: $pids"
            kill -9 $pids 2>/dev/null
            sleep 1
        fi
    fi
    
    # Double-check port is free
    if ss -tlnp 2>/dev/null | grep -q ":$port " || netstat -tlnp 2>/dev/null | grep -q ":$port "; then
        output "ERROR: Port $port is still in use after cleanup. Cannot start dashboard."
        return 1
    fi
    
    # Locate the dashboard script in common paths
    local paths=(
        "./bin/ebaf_dash.py"
        "/usr/local/share/ebaf/ebaf_dash.py"
    )
    
    for path in "${paths[@]}"; do
        if [ -f "$path" ]; then
            dashboard_script="$path"
            output "Found dashboard script: $path"
            break
        fi
    done
    
    if [ -z "$dashboard_script" ]; then
        output "WARNING: Dashboard script not found, skipping web dashboard"
        output "Searched paths:"
        if [ $QUIET_MODE -eq 0 ]; then
            printf "  %s\n" "${paths[@]}"
        fi
        return 1
    fi
    
    # Verify Python3 is available
    if ! command -v python3 &> /dev/null; then
        output "WARNING: Python3 not found, skipping web dashboard"
        return 1
    fi
    
    # Start dashboard in background with explicit output redirection
    output "Starting dashboard on port $port..."
    nohup python3 "$dashboard_script" > /dev/null 2>&1 &
    DASHBOARD_PID=$!
    
    # Wait longer for startup
    sleep 15
    
    # Verify dashboard started successfully
    if kill -0 $DASHBOARD_PID 2>/dev/null; then
        # Double-check that something is actually listening on the port
        local listening=0
        for i in {1..5}; do
            if ss -tlnp 2>/dev/null | grep -q ":$port " || netstat -tlnp 2>/dev/null | grep -q ":$port "; then
                listening=1
                break
            fi
            sleep 1
        done
        
        if [ $listening -eq 1 ]; then
            output "Dashboard started successfully: http://localhost:$port (PID: $DASHBOARD_PID)"
            return 0
        else
            output "WARNING: Dashboard process started but not listening on port $port"
            kill $DASHBOARD_PID 2>/dev/null
            DASHBOARD_PID=""
            return 1
        fi
    else
        output "WARNING: Failed to start dashboard process"
        DASHBOARD_PID=""
        return 1
    fi
}
# Function: cleanup
# Purpose: Gracefully stop all eBAF instances and dashboard on script exit
cleanup() {
    if [ $QUIET_MODE -eq 0 ]; then
        echo ""
        echo "Shutting down eBAF..."
        echo "=========================================="
    fi
    
    # Stop dashboard if it's running
    if [ -n "$DASHBOARD_PID" ]; then
        output "Stopping dashboard (PID: $DASHBOARD_PID)..."
        kill $DASHBOARD_PID 2>/dev/null
        sleep 1
        # Force kill if still running
        kill -9 $DASHBOARD_PID 2>/dev/null
    fi
    
    # Stop all adblocker processes
    output "Stopping adblocker processes..."
    pkill -f "$(basename "$ADBLOCKER")" 2>/dev/null
    
    # Clean up any remaining dashboard processes
    output "Cleaning up dashboard processes..."
    pkill -f "ebaf_dash.py" 2>/dev/null
    sleep 1
    pkill -9 -f "ebaf_dash.py" 2>/dev/null
    
    # Force cleanup port 8080
    if command -v lsof &> /dev/null; then
        local pids=$(lsof -ti:8080 2>/dev/null)
        if [ -n "$pids" ]; then
            output "Force killing remaining processes on port 8080..."
            kill -9 $pids 2>/dev/null
        fi
    fi
    
    # Remove any PID files
    rm -f /tmp/ebaf-dashboard.pid 2>/dev/null
    
    output "All eBAF instances stopped."
    exit 0
}

# =============================================================================
# MAIN EXECUTION LOGIC
# =============================================================================

# Find the adblocker binary
if [ $QUIET_MODE -eq 0 ]; then
    echo "=========================================="
    echo "eBAF Initialization"
    echo "=========================================="
fi

ADBLOCKER=$(find_adblocker)
if [ -z "$ADBLOCKER" ]; then
    echo "ERROR: Could not find adblocker binary."
    echo "Make sure eBAF is properly compiled and installed."
    exit 1
fi

output "Found adblocker: $ADBLOCKER"

# Determine which interfaces to use
INTERFACES=()

# Add user-specified interfaces
if [ ${#SPECIFIED_INTERFACES[@]} -gt 0 ]; then
    INTERFACES+=("${SPECIFIED_INTERFACES[@]}")
fi

# Add default interface if requested
if [ $DEFAULT_INTERFACE -eq 1 ]; then
    default_if=$(get_default_interface)
    if [ -n "$default_if" ]; then
        # Avoid duplicates
        if [[ ! " ${INTERFACES[*]} " =~ " ${default_if} " ]]; then
            INTERFACES+=("$default_if")
        fi
        output "Using default interface: $default_if"
    else
        echo "ERROR: Could not determine default interface."
        echo "Available interfaces:"
        ip -o link show | cut -d: -f2 | tr -d ' '
        exit 1
    fi
fi

# Add all active interfaces if requested
if [ $ALL_INTERFACES -eq 1 ]; then
    while read -r iface; do
        if [[ ! " ${INTERFACES[*]} " =~ " ${iface} " ]]; then
            INTERFACES+=("$iface")
        fi
    done < <(get_active_interfaces)
    output "Using all active interfaces: ${INTERFACES[*]}"
fi

# Validate interfaces exist
if [ $QUIET_MODE -eq 0 ]; then
    echo ""
    echo "Validating interfaces..."
fi
valid_interfaces=()
for iface in "${INTERFACES[@]}"; do
    if ip link show "$iface" &>/dev/null; then
        valid_interfaces+=("$iface")
        output "  $iface - Valid"
    else
        output "  $iface - Interface not found"
    fi
done

if [ ${#valid_interfaces[@]} -eq 0 ]; then
    echo "ERROR: No valid interfaces found."
    exit 1
fi

INTERFACES=("${valid_interfaces[@]}")

# Set up signal handling for graceful shutdown
trap cleanup SIGINT SIGTERM

# Check for conflicting options
if [ $ALL_INTERFACES -eq 1 ] && [ ${#SPECIFIED_INTERFACES[@]} -gt 0 ]; then
    echo "WARNING: Both --all and specific interfaces specified. Using all interfaces."
fi

# Start eBAF on selected interfaces
if [ $QUIET_MODE -eq 0 ]; then
    echo ""
    echo "=========================================="
    echo "Starting eBAF"
    echo "=========================================="
fi

for iface in "${INTERFACES[@]}"; do
    output "Starting eBAF on interface: $iface"
    "$ADBLOCKER" "$iface" > /dev/null 2>&1 &

done

# Brief wait for startup
sleep 3

# Verify processes started successfully
running_count=$(pgrep -fc "$(basename "$ADBLOCKER")")
if [ $running_count -eq 0 ]; then
    echo "ERROR: Failed to start eBAF on any interface."
    exit 1
fi

output "eBAF is running successfully on ${#INTERFACES[@]} interface(s)."

# Start dashboard if requested
if [ $ENABLE_DASHBOARD -eq 1 ]; then
    if [ $QUIET_MODE -eq 0 ]; then
        echo ""
        echo "Starting web dashboard..."
    fi
    start_dashboard
fi

# Display monitoring information
if [ $QUIET_MODE -eq 0 ]; then
    echo ""
    echo "=========================================="
    echo "eBAF Status"
    echo "=========================================="
    echo "Active interfaces: ${INTERFACES[*]}"
    echo "Running processes: $running_count"
    if [ $ENABLE_DASHBOARD -eq 1 ] && [ -n "$DASHBOARD_PID" ]; then
        echo "Web dashboard: http://localhost:8080"
    else
        echo "Web dashboard: Use -D flag to enable"
    fi
    echo ""
    echo "Use Ctrl+C to stop all instances."
    echo "=========================================="
fi

# Wait for processes to finish (or signal)
wait