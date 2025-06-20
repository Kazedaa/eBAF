#!/bin/bash
# eBAF Spotify Monitor - Automatically start/stop eBAF with Spotify

EBAF_PID=""
SPOTIFY_RUNNING=false

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [eBAF-Monitor] $1" | systemd-cat -t ebaf-monitor
}

cleanup() {
    log "Shutting down eBAF..."
    if [ -n "$EBAF_PID" ]; then
        sudo pkill -P $EBAF_PID 2>/dev/null
        sudo pkill -f "ebaf" 2>/dev/null
    fi
    exit 0
}

trap cleanup SIGTERM SIGINT

start_ebaf() {
    if [ -z "$EBAF_PID" ]; then
        log "Starting eBAF..."
        # Start eBAF in quiet mode with dashboard
        sudo /usr/local/bin/ebaf -d -D -q &
        EBAF_PID=$!
        
        # Wait for eBAF to initialize (about 10 seconds)
        sleep 10
        
        if kill -0 $EBAF_PID 2>/dev/null; then
            log "eBAF started successfully (PID: $EBAF_PID)"
            return 0
        else
            log "Failed to start eBAF"
            EBAF_PID=""
            return 1
        fi
    fi
}

stop_ebaf() {
    if [ -n "$EBAF_PID" ]; then
        log "Stopping eBAF..."
        sudo pkill -P $EBAF_PID 2>/dev/null
        sudo pkill -f "ebaf" 2>/dev/null
        EBAF_PID=""
        log "eBAF stopped"
    fi
}

# Main monitoring loop
log "Starting Spotify monitor..."

while true; do
    # Check if Spotify is running
    if pgrep -x "spotify" > /dev/null || pgrep -f "spotify" > /dev/null; then
        if [ "$SPOTIFY_RUNNING" = false ]; then
            log "Spotify detected, starting eBAF..."
            if start_ebaf; then
                SPOTIFY_RUNNING=true
            fi
        fi
    else
        if [ "$SPOTIFY_RUNNING" = true ]; then
            log "Spotify closed, stopping eBAF..."
            stop_ebaf
            SPOTIFY_RUNNING=false
        fi
    fi
    
    sleep 5
done