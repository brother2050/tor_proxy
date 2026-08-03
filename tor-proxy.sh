#!/bin/bash
# tor-proxy.sh - Tor 代理管理脚本
# =================================
# 自动从模板生成配置，使用相对路径

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOR_BIN="$SCRIPT_DIR/tor"
TOR_DATA="$SCRIPT_DIR/data"
TOR_LOGS="$SCRIPT_DIR/logs"
CONFIG_TEMPLATE="$SCRIPT_DIR/config/torrc.template"
CONFIG="$SCRIPT_DIR/config/torrc"
TOR_PID_FILE="$TOR_DATA/tor.pid"
SOCKS_PORT=9050

export LD_LIBRARY_PATH="$SCRIPT_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log() { echo -e "${GREEN}[tor-proxy]${NC} $*"; }
warn() { echo -e "${YELLOW}[tor-proxy]${NC} $*"; }

# 从模板生成配置
generate_config() {
    [ ! -f "$CONFIG_TEMPLATE" ] && { warn "Template not found"; return 1; }
    local escaped_dir
    escaped_dir=$(printf '%s\n' "$SCRIPT_DIR" | sed 's/[[\.*^$()+?{|/]/\\&/g')
    sed "s|__DIR__|${escaped_dir}|g" "$CONFIG_TEMPLATE" > "$CONFIG"
}

get_pid() { [ -f "$TOR_PID_FILE" ] && cat "$TOR_PID_FILE" 2>/dev/null; }
is_running() { local pid=$(get_pid); [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }

cmd_start() {
    mkdir -p "$TOR_DATA" "$TOR_LOGS"
    if is_running; then
        log "Already running (PID: $(get_pid))"; return 0
    fi
    generate_config || return 1
    rm -f "$TOR_DATA/lock" "$TOR_DATA/pid" 2>/dev/null
    log "Starting Tor..."
    nohup "$TOR_BIN" -f "$CONFIG" </dev/null >"$TOR_LOGS/startup.log" 2>&1 &
    echo $! > "$TOR_PID_FILE"
    log "Waiting for bootstrap..."
    for i in $(seq 1 180); do
        sleep 2
        local pid=$(get_pid)
        [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null && { log "Tor died!"; return 1; }
        if [ -f "$TOR_LOGS/tor.log" ]; then
            local pct=$(grep -oP 'Bootstrapped \K\d+' "$TOR_LOGS/tor.log" 2>/dev/null | tail -1)
            if [ "$pct" = "100" ]; then
                log "✓ Proxy ready! SOCKS5: 127.0.0.1:$SOCKS_PORT"; return 0
            fi
            [ $((i % 5)) -eq 0 ] && [ -n "$pct" ] && printf "\r  Bootstrap: %s%%" "$pct"
        fi
    done
    echo ""; warn "Bootstrap may be incomplete"
}

cmd_stop() {
    local pid=$(get_pid)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "Stopping Tor (PID: $pid)..."
        kill "$pid" 2>/dev/null; sleep 2
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
        log "Stopped"
    else warn "Not running"; fi
    rm -f "$TOR_PID_FILE"
}

cmd_status() {
    if is_running; then
        log "Running (PID: $(get_pid))"
        [ -f "$TOR_LOGS/tor.log" ] && grep "Bootstrapped" "$TOR_LOGS/tor.log" 2>/dev/null | tail -1
    else warn "Not running"; fi
}

cmd_test() {
    is_running || { log "Not running"; return 1; }
    log "Testing..."
    for s in "Google:https://www.google.com" "Wikipedia:https://en.wikipedia.org" "GitHub:https://github.com"; do
        local n="${s%%:*}" u="${s#*:}"
        local t0=$(date +%s%N)
        local c=$(curl --socks5-hostname 127.0.0.1:$SOCKS_PORT -s --connect-timeout 20 --max-time 40 -o /dev/null -w "%{http_code}" "$u")
        local t1=$(date +%s%N) ms=$(( (t1 - t0) / 1000000 ))
        [ "$c" = "200" ] || [ "$c" = "301" ] || [ "$c" = "302" ] && printf "  ✓ %-15s %5dms  HTTP %s\n" "$n" "$ms" "$c" || printf "  ✗ %-15s %5dms  HTTP %s\n" "$n" "$ms" "$c"
    done
}

cmd_ip() {
    is_running || { log "Not running"; return 1; }
    curl --socks5-hostname 127.0.0.1:$SOCKS_PORT -s --connect-timeout 20 "https://api.ipify.org" 2>/dev/null; echo
}

cmd_log() { [ -f "$TOR_LOGS/tor.log" ] && tail -f "$TOR_LOGS/tor.log" || warn "No log"; }

case "${1:-help}" in
    start) cmd_start ;; stop) cmd_stop ;; restart) cmd_stop; sleep 2; cmd_start ;;
    status) cmd_status ;; test) cmd_test ;; ip) cmd_ip ;; log) cmd_log ;;
    *) echo "Usage: $0 {start|stop|restart|status|test|ip|log}" ;;
esac
