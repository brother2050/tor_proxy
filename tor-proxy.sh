#!/bin/bash
# tor-proxy - Lightweight Tor SOCKS5 Proxy
# Usage: ./tor-proxy.sh [start|stop|restart|status|test|ip|log]
# ============================================================

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOR_BIN="$SCRIPT_DIR/tor"
TOR_DATA="$SCRIPT_DIR/data"
TOR_LOGS="$SCRIPT_DIR/logs"
TOR_CONFIG="$SCRIPT_DIR/config/torrc"
TOR_PID_FILE="$SCRIPT_DIR/data/tor.pid"
SOCKS_PORT=9050

export LD_LIBRARY_PATH="$SCRIPT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[tor-proxy]${NC} $*"; }
warn() { echo -e "${YELLOW}[tor-proxy]${NC} $*"; }
err() { echo -e "${RED}[tor-proxy]${NC} $*"; }

ensure_dirs() {
    mkdir -p "$TOR_DATA" "$TOR_LOGS"
}

get_pid() {
    if [ -f "$TOR_PID_FILE" ]; then
        cat "$TOR_PID_FILE" 2>/dev/null
    fi
}

is_running() {
    local pid=$(get_pid)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    return 1
}

cmd_start() {
    ensure_dirs
    if is_running; then
        log "Already running (PID: $(get_pid))"
        return 0
    fi

    log "Starting Tor..."
    log "  SOCKS proxy: socks5h://127.0.0.1:$SOCKS_PORT"

    # Clear old data
    rm -f "$TOR_DATA/lock" "$TOR_DATA/pid" 2>/dev/null

    # Start tor
    setsid "$TOR_BIN" -f "$TOR_CONFIG" </dev/null >"$TOR_LOGS/tor-stdout.log" 2>&1 &
    local pid=$!
    echo "$pid" > "$TOR_PID_FILE"

    # Wait for SOCKS port
    log "Waiting for SOCKS port..."
    for i in $(seq 1 30); do
        if ss -tlnp 2>/dev/null | grep -q ":$SOCKS_PORT "; then
            log "SOCKS port ready"
            break
        fi
        sleep 1
    done

    # Wait for bootstrap
    log "Waiting for Tor bootstrap (this may take 30-120s)..."
    for i in $(seq 1 120); do
        if [ -f "$TOR_LOGS/tor.log" ]; then
            local pct=$(grep -oP 'Bootstrapped \K\d+' "$TOR_LOGS/tor.log" 2>/dev/null | tail -1)
            if [ -n "$pct" ]; then
                printf "\r  Bootstrap: %s%%" "$pct"
                if [ "$pct" = "100" ]; then
                    echo ""
                    log "✓ Tor bootstrapped! Proxy ready."
                    log "  Use: curl --socks5-hostname 127.0.0.1:$SOCKS_PORT https://api.ipify.org"
                    return 0
                fi
            fi
        fi
        # Check if process died
        if ! kill -0 "$pid" 2>/dev/null; then
            echo ""
            err "Tor process died! Check logs:"
            tail -20 "$TOR_LOGS/tor.log" 2>/dev/null
            return 1
        fi
        sleep 1
    done
    echo ""
    warn "Bootstrap incomplete. Tor may still work partially."
    warn "Check logs: tail -f $TOR_LOGS/tor.log"
}

cmd_stop() {
    local pid=$(get_pid)
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
        warn "Not running"
        return 0
    fi

    log "Stopping Tor (PID: $pid)..."
    kill "$pid" 2>/dev/null
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null
    fi
    rm -f "$TOR_PID_FILE"
    log "✓ Stopped"
}

cmd_restart() {
    cmd_stop
    sleep 1
    cmd_start
}

cmd_status() {
    if is_running; then
        log "✓ Running (PID: $(get_pid))"
        if [ -f "$TOR_LOGS/tor.log" ]; then
            grep "Bootstrapped" "$TOR_LOGS/tor.log" 2>/dev/null | tail -1
        fi
    else
        warn "Not running"
    fi
}

cmd_ip() {
    if ! is_running; then
        err "Not running. Start first: $0 start"
        return 1
    fi
    log "Fetching Tor exit IP..."
    curl --socks5-hostname 127.0.0.1:$SOCKS_PORT -s "https://api.ipify.org" 2>/dev/null || \
    curl --socks5-hostname 127.0.0.1:$SOCKS_PORT -s "https://httpbin.org/ip" 2>/dev/null
    echo ""
}

cmd_test() {
    if ! is_running; then
        err "Not running. Start first: $0 start"
        return 1
    fi

    log "Testing Tor connectivity..."
    echo ""

    local pass=0
    local total=0

    test_url() {
        local name="$1"
        local url="$2"
        total=$((total + 1))

        local start=$(date +%s%N)
        local code=$(curl --socks5-hostname 127.0.0.1:$SOCKS_PORT -s -o /dev/null -w "%{http_code}" \
            --connect-timeout 15 --max-time 30 "$url" 2>/dev/null)
        local end=$(date +%s%N)
        local ms=$(( (end - start) / 1000000 ))

        if [ "$code" = "200" ] || [ "$code" = "301" ] || [ "$code" = "302" ]; then
            printf "  ✓ %-20s %4dms  HTTP %s\n" "$name" "$ms" "$code"
            pass=$((pass + 1))
        else
            printf "  ✗ %-20s %4dms  HTTP %s\n" "$name" "$ms" "${code:-timeout}"
        fi
    }

    test_url "Tor Check" "https://check.torproject.org/"
    test_url "Google" "https://www.google.com/"
    test_url "Wikipedia" "https://en.wikipedia.org/"
    test_url "GitHub" "https://github.com/"
    test_url "DuckDuckGo" "https://duckduckgo.com/"
    test_url "Cloudflare" "https://1.1.1.1/"

    echo ""
    log "Result: $pass/$total tests passed"
}

cmd_log() {
    if [ -f "$TOR_LOGS/tor.log" ]; then
        tail -f "$TOR_LOGS/tor.log"
    else
        warn "No log file found"
    fi
}

case "${1:-help}" in
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    restart) cmd_restart ;;
    status)  cmd_status ;;
    ip)      cmd_ip ;;
    test)    cmd_test ;;
    log)     cmd_log ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|test|ip|log}"
        echo ""
        echo "  start    - Start Tor SOCKS5 proxy on port $SOCKS_PORT"
        echo "  stop     - Stop Tor"
        echo "  restart  - Restart Tor"
        echo "  status   - Show running status"
        echo "  test     - Test connectivity to popular sites"
        echo "  ip       - Show current Tor exit IP"
        echo "  log      - Tail Tor log"
        echo ""
        echo "Proxy: socks5h://127.0.0.1:$SOCKS_PORT"
        echo "  curl --socks5-hostname 127.0.0.1:$SOCKS_PORT https://api.ipify.org"
        echo "  export ALL_PROXY=socks5h://127.0.0.1:$SOCKS_PORT"
        ;;
esac
