#!/bin/bash
# eBAF Cleanup Utility - Force cleanup of eBAF processes and ports

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RESET='\033[0m'

echo -e "${YELLOW}🧹 eBAF Cleanup Utility${RESET}"
echo "This will force cleanup all eBAF processes and free port 8080"
echo ""

# Function to kill processes on port
kill_port_processes() {
  local port=$1
  echo -e "${YELLOW}Cleaning up port $port...${RESET}"
  
  if command -v lsof &> /dev/null; then
    local pids=$(lsof -ti:$port 2>/dev/null)
    if [ -n "$pids" ]; then
      echo "Killing processes using port $port: $pids"
      kill -9 $pids 2>/dev/null
      echo -e "${GREEN}✅ Killed processes on port $port${RESET}"
    else
      echo -e "${GREEN}✅ No processes found on port $port${RESET}"
    fi
  elif command -v fuser &> /dev/null; then
    fuser -k ${port}/tcp 2>/dev/null
    echo -e "${GREEN}✅ Cleaned up port $port${RESET}"
  else
    echo -e "${YELLOW}⚠️  No port cleanup tools available (lsof/fuser)${RESET}"
  fi
}

# Kill all eBAF processes
echo -e "${YELLOW}Stopping all eBAF processes...${RESET}"
pkill -f "adblocker" 2>/dev/null
pkill -f "ebaf_dash.py" 2>/dev/null

# Clean up port 8080
kill_port_processes 8080

# Remove PID files
echo -e "${YELLOW}Removing PID files...${RESET}"
rm -f /tmp/ebaf-dashboard.pid
rm -f /tmp/ebaf-stats.dat
rm -f /tmp/ebaf-web-prev-stats.dat

# Wait for cleanup
sleep 2

# Check if cleanup was successful
echo ""
echo -e "${YELLOW}Verifying cleanup...${RESET}"

if pgrep -f "adblocker" > /dev/null; then
  echo -e "${RED}❌ Some adblocker processes are still running${RESET}"
else
  echo -e "${GREEN}✅ All adblocker processes stopped${RESET}"
fi

if pgrep -f "ebaf_dash.py" > /dev/null; then
  echo -e "${RED}❌ Some dashboard processes are still running${RESET}"
else
  echo -e "${GREEN}✅ All dashboard processes stopped${RESET}"
fi

# Test port 8080
if command -v netstat &> /dev/null; then
  if netstat -tlnp 2>/dev/null | grep -q ":8080 "; then
    echo -e "${RED}❌ Port 8080 is still in use${RESET}"
  else
    echo -e "${GREEN}✅ Port 8080 is free${RESET}"
  fi
elif command -v ss &> /dev/null; then
  if ss -tlnp 2>/dev/null | grep -q ":8080 "; then
    echo -e "${RED}❌ Port 8080 is still in use${RESET}"
  else
    echo -e "${GREEN}✅ Port 8080 is free${RESET}"
  fi
fi

echo ""
echo -e "${GREEN}🎉 Cleanup complete! You can now restart eBAF.${RESET}"