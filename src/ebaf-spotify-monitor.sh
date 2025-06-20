#!/bin/bash
# eBAF Spotify Monitor Service
# Automatically starts/stops eBAF when Spotify starts/stops

EBAF_BIN="/usr/local/bin/ebaf"
SPOTIFY_PROCESSES=("spotify" "spotify-launcher" "spotify-desktop")
EBAF_PID=""
CHECK_INTERVAL=5

log() {
    echo "[$(date)] $1" | systemd-cat -t ebaf-spotify-monitor
}

is_spotify_running() {
    for proc in "${SPOTIFY_PROCESSES[@]}"; do
        if pgrep -x "$proc" > /dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

start_ebaf() {
    if [ -n "$EBAF_PID" ] && kill -0 "$EBAF_PID" 2>/dev/null; then
        return 0  # Already running
    fi
    
    log "Starting eBAF for Spotify session..."
    # Start eBAF with default settings and dashboard
    sudo "$EBAF_BIN" -d -D -q &
    EBAF_PID=$!
    
    # Wait for eBAF to fully initialize (up to 30 seconds)
    local timeout=30
    local count=0
    while [ $count -lt $timeout ]; do
        if kill -0 "$EBAF_PID" 2>/dev/null; then
            # Check if dashboard is ready (port 8080 listening)
            if ss -tlnp 2>/dev/null | grep -q ":8080 " || netstat -tlnp 2>/dev/null | grep -q ":8080 "; then
                log "eBAF fully initialized and ready"
                return 0
            fi
        else
            log "eBAF process died during initialization"
            EBAF_PID=""
            return 1
        fi
        sleep 1
        ((count++))
    done
    
    log "eBAF initialization timeout after ${timeout}s"
    return 1
}

stop_ebaf() {
    if [ -n "$EBAF_PID" ] && kill -0 "$EBAF_PID" 2>/dev/null; then
        log "Stopping eBAF..."
        kill "$EBAF_PID" 2>/dev/null
        sleep 5
        
        # Force kill if still running
        if kill -0 "$EBAF_PID" 2>/dev/null; then
            kill -9 "$EBAF_PID" 2>/dev/null
        fi
        
        # Clean up any remaining processes
        sudo pkill -f "adblocker" 2>/dev/null
        sudo pkill -f "ebaf_dash.py" 2>/dev/null
        
        EBAF_PID=""
        log "eBAF stopped"
    fi
}

cleanup() {
    log "Monitor service shutting down..."
    stop_ebaf
    exit 0
}

trap cleanup SIGTERM SIGINT

log "eBAF Spotify Monitor started"

# Main monitoring loop
while true; do
    if is_spotify_running; then
        if [ -z "$EBAF_PID" ] || ! kill -0 "$EBAF_PID" 2>/dev/null; then
            log "Spotify detected, starting eBAF..."
            start_ebaf
        fi
    else
        if [ -n "$EBAF_PID" ] && kill -0 "$EBAF_PID" 2>/dev/null; then
            log "Spotify closed, stopping eBAF..."
            stop_ebaf
        fi
    fi
    
    sleep $CHECK_INTERVAL
done