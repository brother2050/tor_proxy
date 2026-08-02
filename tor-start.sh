#!/bin/bash
# tor-start.sh - 启动 Tor 代理 (优化版)
# ========================================
# 自动使用预缓存描述符，首次启动也快
#
# 用法:
#   ./tor-start.sh          # 启动 (自动用缓存)
#   ./tor-start.sh stop     # 停止
#   ./tor-start.sh restart  # 重启 (保留缓存)
#   ./tor-start.sh status   # 状态
#   ./tor-start.sh fresh    # 清除缓存并启动
#   ./tor-start.sh refresh  # 刷新描述符缓存

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOR_BIN="$SCRIPT_DIR/tor"
OBFS4PROXY="$SCRIPT_DIR/obfs4proxy"
DATA_DIR="$SCRIPT_DIR/data"
LOGS_DIR="$SCRIPT_DIR/logs"
CACHE_DIR="$SCRIPT_DIR/cache/descriptors"
CONFIG="$SCRIPT_DIR/config/torrc"
PID_FILE="$SCRIPT_DIR/data/tor.pid"
SOCKS_PORT=9050

export LD_LIBRARY_PATH="$SCRIPT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[tor]${NC} $*"; }
warn() { echo -e "${YELLOW}[tor]${NC} $*"; }
info() { echo -e "${CYAN}[tor]${NC} $*"; }

get_pid() {
    [ -f "$PID_FILE" ] && cat "$PID_FILE" 2>/dev/null
}

is_running() {
    local pid=$(get_pid)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# 从缓存部署描述符
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

    # 不复制 state 文件 (让 Tor 自己生成，避免序列号冲突)

    log "✓ Cache deployed - boot should be fast (~30s)"
    return 0
}

# 同步运行时数据到缓存
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
        # 停止前同步描述符到缓存
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

    mkdir -p "$DATA_DIR" "$LOGS_DIR"
    rm -f "$DATA_DIR/pid" "$DATA_DIR/lock" 2>/dev/null

    # 检查是否需要部署缓存
    local need_cache=false
    if [ ! -f "$DATA_DIR/cached-microdesc-consensus" ]; then
        need_cache=true
    else
        # 检查缓存是否过期
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

    # 部署缓存
    if $need_cache; then
        deploy_cache
    else
        local relay_count=$(grep -c "onion-key" "$DATA_DIR/cached-microdescs" 2>/dev/null || echo 0)
        info "Using existing cache ($relay_count relays) - fast boot"
    fi

    log "Starting Tor..."
    nohup "$TOR_BIN" -f "$CONFIG" </dev/null >"$LOGS_DIR/startup.log" 2>&1 &
    local pid=$!
    echo "$pid" > "$PID_FILE"

    # 等待引导
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
                # 启动后同步缓存
                sync_to_cache
                # 启动后台刷新
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

do_restart() {
    do_stop
    sleep 2
    do_start
}

do_fresh() {
    log "Clearing all caches..."
    do_stop
    rm -rf "$DATA_DIR"/*
    mkdir -p "$DATA_DIR"
    log "Starting fresh (will be slow)..."
    do_start
}

do_refresh() {
    log "Refreshing descriptor cache..."
    if is_running; then
        "$SCRIPT_DIR/tor-refresh.sh"
    else
        log "Tor not running - starting temporarily..."
        do_start
        "$SCRIPT_DIR/tor-refresh.sh"
    fi
}

do_status() {
    echo -e "${CYAN}=== Tor Proxy Status ===${NC}"
    echo ""

    if is_running; then
        log "Running (PID: $(get_pid))"
    else
        warn "Not running"
    fi

    if [ -f "$LOGS_DIR/tor.log" ]; then
        local last_boot=$(grep "Bootstrapped" "$LOGS_DIR/tor.log" 2>/dev/null | tail -1)
        [ -n "$last_boot" ] && echo "  $last_boot"
    fi

    echo ""
    echo -e "${CYAN}=== Descriptor Cache ===${NC}"
    if [ -f "$CACHE_DIR/cached-microdesc-consensus" ]; then
        local cache_size=$(du -sh "$CACHE_DIR" | awk '{print $1}')
        local relay_count=$(grep -c "onion-key" "$CACHE_DIR/cached-microdescs" 2>/dev/null || echo 0)
        local valid_until=$(grep "valid-until" "$CACHE_DIR/cached-microdesc-consensus" | awk '{print $2, $3}')
        local until_ts=$(date -d "$valid_until" +%s 2>/dev/null)
        local now_ts=$(date +%s)
        local remaining=$(( (until_ts - now_ts) / 60 ))

        echo "  Size: $cache_size"
        echo "  Relays: $relay_count"
        echo "  Valid for: ${remaining}min"
    else
        echo "  No cache"
    fi
}

# 清理
cleanup() {
    sync_to_cache
}

case "${1:-start}" in
    start)    do_start ;;
    stop)     do_stop ;;
    restart)  do_restart ;;
    fresh)    do_fresh ;;
    refresh)  do_refresh ;;
    status)   do_status ;;
    *)
        echo "Usage: $0 {start|stop|restart|fresh|refresh|status}"
        echo ""
        echo "  start    - 启动 (自动用缓存，~30秒)"
        echo "  stop     - 停止 (自动保存缓存)"
        echo "  restart  - 重启 (保留缓存)"
        echo "  fresh    - 清除缓存并启动 (首次用)"
        echo "  refresh  - 刷新描述符缓存"
        echo "  status   - 查看状态"
        ;;
esac
