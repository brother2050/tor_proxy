#!/bin/bash
# tor-proxy.sh - Tor 代理管理脚本
# =================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 平台检测
detect_platform() {
    local os arch
    case "$(uname -s)" in Linux*) os="linux";; Darwin*) os="macos";; *) os="unknown";; esac
    case "$(uname -m)" in x86_64|amd64) arch="x86_64";; arm64|aarch64) arch="aarch64";; *) arch="$(uname -m)";; esac
    echo "${os}-${arch}"
}

PLATFORM=$(detect_platform)
BIN_DIR="$SCRIPT_DIR/bin/$PLATFORM"

# 查找二进制
TOR_BIN=""
OBFS4PROXY=""
[ -x "$BIN_DIR/tor" ] && TOR_BIN="$BIN_DIR/tor"
[ -x "$BIN_DIR/obfs4proxy" ] && OBFS4PROXY="$BIN_DIR/obfs4proxy"
[ -z "$TOR_BIN" ] && [ -x "$SCRIPT_DIR/tor" ] && TOR_BIN="$SCRIPT_DIR/tor"
[ -z "$OBFS4PROXY" ] && [ -x "$SCRIPT_DIR/obfs4proxy" ] && OBFS4PROXY="$SCRIPT_DIR/obfs4proxy"
[ -z "$TOR_BIN" ] && TOR_BIN=$(command -v tor 2>/dev/null)

TOR_DATA="$SCRIPT_DIR/data"
TOR_LOGS="$SCRIPT_DIR/logs"
CONFIG_TEMPLATE="$SCRIPT_DIR/config/torrc.template"
CONFIG="$SCRIPT_DIR/config/torrc"
TOR_PID_FILE="$TOR_DATA/tor.pid"
SOCKS_PORT=9050

export LD_LIBRARY_PATH="$BIN_DIR:${LD_LIBRARY_PATH:-}"
export DYLD_LIBRARY_PATH="$BIN_DIR:${DYLD_LIBRARY_PATH:-}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log() { echo -e "${GREEN}[tor-proxy]${NC} $*"; }
warn() { echo -e "${YELLOW}[tor-proxy]${NC} $*"; }

generate_config() {
    [ ! -f "$CONFIG_TEMPLATE" ] && { warn "Template not found"; return 1; }
    local escaped_dir escaped_obfs4
    escaped_dir=$(printf '%s\n' "$SCRIPT_DIR" | sed 's/[[\.*^$()+?{|/]/\\&/g')
    escaped_obfs4=$(printf '%s\n' "$OBFS4PROXY" | sed 's/[[\.*^$()+?{|/]/\\&/g')
    sed -e "s|__DIR__|${escaped_dir}|g" -e "s|__OBFS4PROXY__|${escaped_obfs4}|g" "$CONFIG_TEMPLATE" > "$CONFIG"
}

get_pid() { [ -f "$TOR_PID_FILE" ] && cat "$TOR_PID_FILE" 2>/dev/null; }
is_running() { local pid=$(get_pid); [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }

cmd_start() {
    mkdir -p "$TOR_DATA" "$TOR_LOGS"
    is_running && { log "Already running (PID: $(get_pid))"; return 0; }
    [ -z "$TOR_BIN" ] && { log "Tor not found. Run: ./setup.sh"; return 1; }
    generate_config || return 1
    rm -f "$TOR_DATA/lock" "$TOR_DATA/pid" 2>/dev/null
    log "Starting Tor ($PLATFORM)..."
    nohup "$TOR_BIN" -f "$CONFIG" </dev/null >"$TOR_LOGS/startup.log" 2>&1 &
    echo $! > "$TOR_PID_FILE"
    log "Waiting for bootstrap..."
    for i in $(seq 1 180); do
        sleep 2
        local pid=$(get_pid)
        [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null && { log "Tor died!"; return 1; }
        if [ -f "$TOR_LOGS/tor.log" ]; then
            local pct=$(grep -oP 'Bootstrapped \K\d+' "$TOR_LOGS/tor.log" 2>/dev/null || grep -o 'Bootstrapped [0-9]*%' "$TOR_LOGS/tor.log" 2>/dev/null | tail -1 | grep -o '[0-9]*')
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
        log "Stopping Tor (PID: $pid)..."; kill "$pid" 2>/dev/null; sleep 2
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null; log "Stopped"
    else warn "Not running"; fi
    rm -f "$TOR_PID_FILE"
}

cmd_status() {
    echo "Platform: $PLATFORM"
    echo "Tor: ${TOR_BIN:-NOT FOUND}"
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
        local t0=$(date +%s%N 2>/dev/null || python3 -c "import time;print(int(time.time()*1e9))")
        local c=$(curl --socks5-hostname 127.0.0.1:$SOCKS_PORT -s --connect-timeout 20 --max-time 40 -o /dev/null -w "%{http_code}" "$u")
        local t1=$(date +%s%N 2>/dev/null || python3 -c "import time;print(int(time.time()*1e9))")
        local ms=$(( (t1 - t0) / 1000000 ))
        [ "$c" = "200" ] || [ "$c" = "301" ] || [ "$c" = "302" ] && printf "  ✓ %-15s %5dms  HTTP %s\n" "$n" "$ms" "$c" || printf "  ✗ %-15s %5dms  HTTP %s\n" "$n" "$ms" "$c"
    done
}

case "${1:-help}" in
    start) cmd_start ;; stop) cmd_stop ;; restart) cmd_stop; sleep 2; cmd_start ;;
    status) cmd_status ;; test) cmd_test ;;
    *) echo "Usage: $0 {start|stop|restart|status|test}" ;;
esac
