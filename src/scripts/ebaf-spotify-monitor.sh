#!/bin/bash
# eBAF Spotify Monitor - Automatically start/stop eBAF with Spotify
# Now runs as a system-level daemon (root)

EBAF_PID=""

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [eBAF-Monitor] $1" | systemd-cat -t ebaf-monitor
}

cleanup() {
    log "Shutting down eBAF monitor..."
    stop_ebaf
    exit 0
}

trap cleanup SIGTERM SIGINT

start_ebaf() {
    if [ -z "$EBAF_PID" ]; then
        log "Starting eBAF..."
        # Start eBAF in quiet mode with dashboard. 
        # No 'sudo' needed here because this script is run by the root systemd service!
        /usr/local/bin/ebaf -d -D -q &
        EBAF_PID=$!
        
        # Give it a couple of seconds to initialize
        sleep 2
        
        if kill -0 $EBAF_PID 2>/dev/null; then
            log "eBAF started successfully (PID: $EBAF_PID)"
        else
            log "Failed to start eBAF"
            EBAF_PID=""
        fi
    fi
}

stop_ebaf() {
    if [ -n "$EBAF_PID" ]; then
        log "Stopping eBAF..."
        kill $EBAF_PID 2>/dev/null
        pkill -P $EBAF_PID 2>/dev/null
        pkill -x "ebaf-core" 2>/dev/null  # Only kill the exact C binary!
        EBAF_PID=""
        log "eBAF stopped"
    fi
}

is_spotify_running() {
    # Check for various Spotify process names across native, Snap, and Flatpak
    if pgrep -x "spotify" > /dev/null || \
       pgrep -x "spotify-client" > /dev/null || \
       pgrep -f "com.spotify.Client" > /dev/null; then
        return 0
    fi
    return 1
}

log "Starting Spotify monitor..."

ebaf_running=false

while true; do
    if is_spotify_running; then
        if [ "$ebaf_running" = false ]; then
            start_ebaf
            ebaf_running=true
        fi
    else
        if [ "$ebaf_running" = true ]; then
            stop_ebaf
            ebaf_running=false
        fi
    fi
    # 5 seconds is a good balance between responsiveness and CPU/battery efficiency
    sleep 5
done