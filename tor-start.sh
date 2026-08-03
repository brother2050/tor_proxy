#!/bin/bash
# tor-start.sh - 启动 Tor 代理
# =============================
# 自动从模板生成配置，使用相对路径，可放在任意目录
#
# 用法:
#   ./tor-start.sh          # 启动
#   ./tor-start.sh stop     # 停止
#   ./tor-start.sh restart  # 重启
#   ./tor-start.sh status   # 状态
#   ./tor-start.sh fresh    # 清除缓存并启动
#   ./tor-start.sh refresh  # 刷新描述符缓存

# 获取脚本所在目录 (支持任意路径、含空格等)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 组件路径
TOR_BIN="$SCRIPT_DIR/tor"
OBFS4PROXY="$SCRIPT_DIR/obfs4proxy"
DATA_DIR="$SCRIPT_DIR/data"
LOGS_DIR="$SCRIPT_DIR/logs"
CACHE_DIR="$SCRIPT_DIR/cache/descriptors"
CONFIG_TEMPLATE="$SCRIPT_DIR/config/torrc.template"
CONFIG="$SCRIPT_DIR/config/torrc"
PID_FILE="$DATA_DIR/tor.pid"
SOCKS_PORT=9050

export LD_LIBRARY_PATH="$SCRIPT_DIR"

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log() { echo -e "${GREEN}[tor]${NC} $*"; }
warn() { echo -e "${YELLOW}[tor]${NC} $*"; }
info() { echo -e "${CYAN}[tor]${NC} $*"; }

# 从模板生成 torrc (替换 __DIR__ 为实际目录)
generate_config() {
    if [ ! -f "$CONFIG_TEMPLATE" ]; then
        warn "Template not found: $CONFIG_TEMPLATE"
        return 1
    fi
    # 转义路径中的特殊字符 (用于 sed)
    local escaped_dir
    escaped_dir=$(printf '%s\n' "$SCRIPT_DIR" | sed 's/[[\.*^$()+?{|/]/\\&/g')
    sed "s|__DIR__|${escaped_dir}|g" "$CONFIG_TEMPLATE" > "$CONFIG"
    info "Generated config: $CONFIG"
}

get_pid() { [ -f "$PID_FILE" ] && cat "$PID_FILE" 2>/dev/null; }

is_running() {
    local pid=$(get_pid)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

deploy_cache() {
    if [ ! -f "$CACHE_DIR/cached-microdesc-consensus" ]; then
        warn "No pre-cached descriptors found"
        return 1
    fi
    local cache_size=$(du -sh "$CACHE_DIR" | awk '{print $1}')
    local relay_count=$(grep -c "onion-key" "$CACHE_DIR/cached-microdescs" 2>/dev/null || echo 0)
    info "Deploying cached descriptors ($cache_size, $relay_count relays)..."
    mkdir -p "$DATA_DIR"
    cp "$CACHE_DIR/cached-certs" "$DATA_DIR/" 2>/dev/null
    cp "$CACHE_DIR/cached-microdesc-consensus" "$DATA_DIR/" 2>/dev/null
    cp "$CACHE_DIR/cached-microdescs" "$DATA_DIR/" 2>/dev/null
    log "✓ Cache deployed - boot should be fast (~30s)"
}

sync_to_cache() {
    mkdir -p "$CACHE_DIR"
    local synced=0
    for f in cached-certs cached-microdesc-consensus cached-microdescs; do
        if [ -f "$DATA_DIR/$f" ]; then
            local src_size=$(stat -c%s "$DATA_DIR/$f" 2>/dev/null || echo 0)
            local dst_size=$(stat -c%s "$CACHE_DIR/$f" 2>/dev/null || echo 0)
            if [ "$src_size" -gt 0 ] && [ "$src_size" -gt "$dst_size" ] 2>/dev/null; then
                cp "$DATA_DIR/$f" "$CACHE_DIR/$f"
                synced=$((synced + 1))
            fi
        fi
    done
    [ "$synced" -gt 0 ] && log "Synced $synced files to cache"
}

do_stop() {
    local pid=$(get_pid)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "Stopping Tor (PID: $pid)..."
        sync_to_cache
        kill "$pid" 2>/dev/null
        sleep 2
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
        log "Stopped"
    else
        warn "Not running"
    fi
    rm -f "$PID_FILE"
}

do_start() {
    if is_running; then
        log "Already running (PID: $(get_pid))"
        return 0
    fi

    # 生成配置
    generate_config || return 1

    mkdir -p "$DATA_DIR" "$LOGS_DIR"
    rm -f "$DATA_DIR/pid" "$DATA_DIR/lock" 2>/dev/null

    # 检查缓存
    local need_cache=false
    if [ ! -f "$DATA_DIR/cached-microdesc-consensus" ]; then
        need_cache=true
    else
        local valid_until=$(grep "valid-until" "$DATA_DIR/cached-microdesc-consensus" 2>/dev/null | awk '{print $2, $3}')
        if [ -n "$valid_until" ]; then
            local until_ts=$(date -d "$valid_until" +%s 2>/dev/null)
            local now_ts=$(date +%s)
            local remaining=$(( (until_ts - now_ts) / 60 ))
            if [ "$remaining" -lt 30 ]; then
                info "Consensus expired (${remaining}min remaining)"
                need_cache=true
            fi
        fi
    fi
    $need_cache && deploy_cache

    log "Starting Tor..."
    nohup "$TOR_BIN" -f "$CONFIG" </dev/null >"$LOGS_DIR/startup.log" 2>&1 &
    local pid=$!
    echo "$pid" > "$PID_FILE"

    log "Waiting for bootstrap..."
    local start_time=$(date +%s)
    for i in $(seq 1 300); do
        sleep 2
        if ! kill -0 "$pid" 2>/dev/null; then
            echo ""
            log "Tor died! Check: tail $LOGS_DIR/tor.log"
            return 1
        fi
        if [ -f "$LOGS_DIR/tor.log" ]; then
            local pct=$(grep -oP 'Bootstrapped \K\d+' "$LOGS_DIR/tor.log" 2>/dev/null | tail -1)
            if [ "$pct" = "100" ]; then
                local elapsed=$(($(date +%s) - start_time))
                echo ""
                log "✓ Bootstrap complete (${elapsed}s)"
                log "  SOCKS proxy: socks5h://127.0.0.1:$SOCKS_PORT"
                sync_to_cache
                nohup "$SCRIPT_DIR/tor-refresh.sh" >>"$LOGS_DIR/refresh.log" 2>&1 &
                return 0
            fi
            [ $((i % 5)) -eq 0 ] && [ -n "$pct" ] && printf "\r  Bootstrap: %s%%" "$pct"
        fi
    done
    echo ""
    warn "Bootstrap timeout. Check logs."
    return 1
}

do_restart() { do_stop; sleep 2; do_start; }

do_fresh() {
    log "Clearing all caches..."
    do_stop
    rm -rf "$DATA_DIR"/*
    mkdir -p "$DATA_DIR"
    do_start
}

do_refresh() {
    log "Refreshing descriptor cache..."
    if is_running; then
        "$SCRIPT_DIR/tor-refresh.sh"
    else
        do_start
        "$SCRIPT_DIR/tor-refresh.sh"
    fi
}

do_status() {
    echo -e "${CYAN}=== Tor Proxy Status ===${NC}"
    if is_running; then
        log "Running (PID: $(get_pid))"
    else
        warn "Not running"
    fi
    [ -f "$LOGS_DIR/tor.log" ] && grep "Bootstrapped" "$LOGS_DIR/tor.log" 2>/dev/null | tail -1
    echo ""
    echo -e "${CYAN}=== Descriptor Cache ===${NC}"
    if [ -f "$CACHE_DIR/cached-microdesc-consensus" ]; then
        local cache_size=$(du -sh "$CACHE_DIR" | awk '{print $1}')
        local relay_count=$(grep -c "onion-key" "$CACHE_DIR/cached-microdescs" 2>/dev/null || echo 0)
        local valid_until=$(grep "valid-until" "$CACHE_DIR/cached-microdesc-consensus" | awk '{print $2, $3}')
        local until_ts=$(date -d "$valid_until" +%s 2>/dev/null)
        local now_ts=$(date +%s)
        local remaining=$(( (until_ts - now_ts) / 60 ))
        echo "  Size: $cache_size | Relays: $relay_count | Valid: ${remaining}min"
    else
        echo "  No cache"
    fi
}

case "${1:-start}" in
    start)   do_start ;;
    stop)    do_stop ;;
    restart) do_restart ;;
    fresh)   do_fresh ;;
    refresh) do_refresh ;;
    status)  do_status ;;
    *)       echo "Usage: $0 {start|stop|restart|fresh|refresh|status}" ;;
esac
