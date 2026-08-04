#!/bin/bash
# tor-start.sh - Tor 代理 (一键启动)
# ====================================
# 自动完成所有事情：检测平台、修复权限、macOS 优化、启动 Tor
#
# 用法:
#   ./tor-start.sh          # 启动
#   ./tor-start.sh stop     # 停止
#   ./tor-start.sh restart  # 重启
#   ./tor-start.sh status   # 状态
#   ./tor-start.sh fresh    # 清除缓存并启动

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================
# 平台检测
# ============================================================
detect_platform() {
    local os arch
    case "$(uname -s)" in
        Linux*)  os="linux" ;;
        Darwin*) os="macos" ;;
        CYGWIN*|MINGW*|MSYS*) os="windows" ;;
        *)       echo "unknown"; return ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64)  arch="x86_64" ;;
        arm64|aarch64) arch="aarch64" ;;
        *)             arch="$(uname -m)" ;;
    esac
    echo "${os}-${arch}"
}

PLATFORM=$(detect_platform)
BIN_DIR="$SCRIPT_DIR/bin/$PLATFORM"
OS_TYPE="${PLATFORM%%-*}"

# ============================================================
# 颜色
# ============================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log() { echo -e "${GREEN}[tor]${NC} $*"; }
warn() { echo -e "${YELLOW}[tor]${NC} $*"; }
err() { echo -e "${RED}[tor]${NC} $*"; }
info() { echo -e "${CYAN}[tor]${NC} $*"; }

# ============================================================
# 自动初始化 (首次运行自动完成所有事情)
# ============================================================
auto_init() {
    # 1. 修复权限
    for f in "$BIN_DIR"/tor "$BIN_DIR"/obfs4proxy "$BIN_DIR"/snowflake-client; do
        [ -f "$f" ] && [ ! -x "$f" ] && chmod +x "$f" 2>/dev/null
    done

    # 2. macOS: 移除 quarantine + libevent 软链接
    if [ "$OS_TYPE" = "macos" ]; then
        for f in "$BIN_DIR"/tor "$BIN_DIR"/obfs4proxy "$BIN_DIR"/snowflake-client; do
            [ -f "$f" ] && xattr -d com.apple.quarantine "$f" 2>/dev/null || true
        done
        # libevent 软链接兼容
        if [ -f "$BIN_DIR/libevent-2.1.7.dylib" ] && [ ! -f "$BIN_DIR/libevent-2.1.dylib" ]; then
            ln -sf "libevent-2.1.7.dylib" "$BIN_DIR/libevent-2.1.dylib" 2>/dev/null || true
        fi
    fi

    # 3. 设置动态库路径
    if [ -d "$BIN_DIR" ]; then
        export LD_LIBRARY_PATH="$BIN_DIR:${LD_LIBRARY_PATH:-}"
        export DYLD_LIBRARY_PATH="$BIN_DIR:${DYLD_LIBRARY_PATH:-}"
    fi

    # 4. 创建符号链接
    ln -sfn "$PLATFORM" "$SCRIPT_DIR/bin/current" 2>/dev/null || true

    # 5. 确保目录存在
    mkdir -p "$SCRIPT_DIR/data" "$SCRIPT_DIR/logs"
}

# 启动时自动初始化
auto_init

# ============================================================
# 二进制路径
# ============================================================
TOR_BIN="$BIN_DIR/tor"
OBFS4PROXY="$BIN_DIR/obfs4proxy"
DATA_DIR="$SCRIPT_DIR/data"
LOGS_DIR="$SCRIPT_DIR/logs"
CACHE_DIR="$SCRIPT_DIR/cache/descriptors"
CONFIG_TEMPLATE="$SCRIPT_DIR/config/torrc.template"
CONFIG="$SCRIPT_DIR/config/torrc"
PID_FILE="$DATA_DIR/tor.pid"
SOCKS_PORT=9050

# ============================================================
# 配置生成
# ============================================================
generate_config() {
    [ ! -f "$CONFIG_TEMPLATE" ] && { warn "模板未找到: $CONFIG_TEMPLATE"; return 1; }

    local escaped_dir escaped_obfs4
    escaped_dir=$(printf '%s\n' "$SCRIPT_DIR" | sed 's/[[\.*^$()+?{|/]/\\&/g')
    escaped_obfs4=$(printf '%s\n' "$OBFS4PROXY" | sed 's/[[\.*^$()+?{|/]/\\&/g')

    sed -e "s|__DIR__|${escaped_dir}|g" \
        -e "s|__OBFS4PROXY__|${escaped_obfs4}|g" \
        "$CONFIG_TEMPLATE" > "$CONFIG"

    # 加载用户自定义桥接
    local user_bridges="$SCRIPT_DIR/bridges.txt"
    if [ -f "$user_bridges" ]; then
        echo "" >> "$CONFIG"
        echo "# === 用户自定义桥接 ===" >> "$CONFIG"
        while IFS= read -r line; do
            line=$(echo "$line" | sed 's/^[[:space:]]*//')
            [ -z "$line" ] && continue
            [[ "$line" == \#* ]] && continue
            echo "Bridge $line" >> "$CONFIG"
        done < "$user_bridges"
        log "已加载用户桥接: $user_bridges"
    fi
}

# ============================================================
# 缓存管理
# ============================================================
get_pid() { [ -f "$PID_FILE" ] && cat "$PID_FILE" 2>/dev/null; }

is_running() {
    local pid=$(get_pid)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

deploy_cache() {
    if [ ! -f "$CACHE_DIR/cached-microdesc-consensus" ]; then
        warn "无预缓存描述符"
        return 1
    fi
    local cache_size=$(du -sh "$CACHE_DIR" 2>/dev/null | awk '{print $1}')
    local relay_count=$(grep -c "onion-key" "$CACHE_DIR/cached-microdescs" 2>/dev/null || echo 0)
    info "部署缓存 ($cache_size, $relay_count 中继)..."
    mkdir -p "$DATA_DIR"
    cp "$CACHE_DIR/cached-certs" "$DATA_DIR/" 2>/dev/null
    cp "$CACHE_DIR/cached-microdesc-consensus" "$DATA_DIR/" 2>/dev/null
    cp "$CACHE_DIR/cached-microdescs" "$DATA_DIR/" 2>/dev/null
    log "✓ 缓存已部署"
}

sync_to_cache() {
    mkdir -p "$CACHE_DIR"
    for f in cached-certs cached-microdesc-consensus cached-microdescs; do
        if [ -f "$DATA_DIR/$f" ]; then
            local src_size=$(stat -c%s "$DATA_DIR/$f" 2>/dev/null || stat -f%z "$DATA_DIR/$f" 2>/dev/null || echo 0)
            local dst_size=$(stat -c%s "$CACHE_DIR/$f" 2>/dev/null || stat -f%z "$CACHE_DIR/$f" 2>/dev/null || echo 0)
            [ "$src_size" -gt 0 ] && [ "$src_size" -gt "$dst_size" ] 2>/dev/null && cp "$DATA_DIR/$f" "$CACHE_DIR/$f"
        fi
    done
}

# ============================================================
# 启动 Tor
# ============================================================
do_start() {
    if is_running; then
        log "已在运行 (PID: $(get_pid))"
        return 0
    fi

    # 检查二进制
    if [ ! -x "$TOR_BIN" ]; then
        err "Tor 不存在: $TOR_BIN"
        err "请确保 git clone 完整 (包含 bin/ 目录)"
        return 1
    fi

    generate_config || return 1

    # 检查缓存
    local need_cache=false
    if [ ! -f "$DATA_DIR/cached-microdesc-consensus" ]; then
        need_cache=true
    else
        local valid_until=$(grep "valid-until" "$DATA_DIR/cached-microdesc-consensus" 2>/dev/null | awk '{print $2, $3}')
        if [ -n "$valid_until" ]; then
            local until_ts=$(date -d "$valid_until" +%s 2>/dev/null || date -jf "%Y-%m-%d %H:%M:%S" "$valid_until" +%s 2>/dev/null || echo 0)
            local now_ts=$(date +%s)
            [ "$(( (until_ts - now_ts) / 60 ))" -lt 30 ] 2>/dev/null && need_cache=true
        fi
    fi
    $need_cache && deploy_cache

    log "启动 Tor ($PLATFORM)..."
    : > "$LOGS_DIR/tor.log" 2>/dev/null

    nohup "$TOR_BIN" -f "$CONFIG" </dev/null >"$LOGS_DIR/startup.log" 2>&1 &
    local pid=$!
    echo "$pid" > "$PID_FILE"

    log "等待连接..."
    local start_time=$(date +%s)
    local last_pct=0
    local stuck_count=0

    for i in $(seq 1 200); do
        sleep 2

        if ! kill -0 "$pid" 2>/dev/null; then
            echo ""
            err "Tor 进程退出"
            [ -f "$LOGS_DIR/tor.log" ] && tail -5 "$LOGS_DIR/tor.log"
            return 1
        fi

        if [ -f "$LOGS_DIR/tor.log" ]; then
            local pct=$(grep -oP 'Bootstrapped \K\d+' "$LOGS_DIR/tor.log" 2>/dev/null | tail -1 || \
                        grep -o 'Bootstrapped [0-9]*%' "$LOGS_DIR/tor.log" 2>/dev/null | tail -1 | grep -o '[0-9]*' || \
                        echo "")

            if [ -n "$pct" ]; then
                if [ "$pct" = "$last_pct" ]; then
                    stuck_count=$((stuck_count + 1))
                else
                    stuck_count=0
                    last_pct="$pct"
                fi

                if [ "$pct" = "100" ]; then
                    local elapsed=$(($(date +%s) - start_time))
                    echo ""
                    log "✓ 连接成功 (${elapsed}s)"
                    log "  代理: socks5h://127.0.0.1:$SOCKS_PORT"
                    sync_to_cache
                    return 0
                fi

                [ $((i % 3)) -eq 0 ] && printf "\r  进度: %s%% (%ds)" "$pct" "$(( $(date +%s) - start_time ))"
            fi

            # 卡住自动重启
            if [ "$stuck_count" -ge 30 ]; then
                echo ""
                warn "卡在 ${last_pct}%，重启 Tor..."
                kill "$pid" 2>/dev/null; sleep 2; kill -9 "$pid" 2>/dev/null || true
                rm -f "$PID_FILE"
                nohup "$TOR_BIN" -f "$CONFIG" </dev/null >"$LOGS_DIR/startup.log" 2>&1 &
                pid=$!; echo "$pid" > "$PID_FILE"
                stuck_count=0
                log "已重启 (PID: $pid)"
            fi
        fi
    done

    echo ""
    warn "超时。日志: tail -f $LOGS_DIR/tor.log"
    return 1
}

# ============================================================
# 停止 / 重启
# ============================================================
do_stop() {
    local pid=$(get_pid)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "停止 Tor (PID: $pid)..."
        sync_to_cache
        kill "$pid" 2>/dev/null || true
        sleep 2
        kill -9 "$pid" 2>/dev/null || true
        log "已停止"
    else
        warn "未在运行"
    fi
    rm -f "$PID_FILE"
    return 0
}

do_restart() { do_stop; sleep 2; do_start; }

do_fresh() {
    log "清除缓存..."
    do_stop
    rm -rf "$DATA_DIR"/*
    mkdir -p "$DATA_DIR"
    do_start
}

# ============================================================
# 状态
# ============================================================
do_status() {
    echo -e "${CYAN}=== Tor Proxy ===${NC}"
    echo "  平台: $PLATFORM"
    echo "  Tor: ${TOR_BIN} $([ -x "$TOR_BIN" ] && echo '✓' || echo '✗')"
    echo "  obfs4proxy: ${OBFS4PROXY} $([ -x "$OBFS4PROXY" ] && echo '✓' || echo '✗')"
    echo ""
    if is_running; then
        log "运行中 (PID: $(get_pid))"
    else
        warn "未运行"
    fi
    [ -f "$LOGS_DIR/tor.log" ] && grep "Bootstrapped" "$LOGS_DIR/tor.log" 2>/dev/null | tail -1
    echo ""
    if [ -f "$CACHE_DIR/cached-microdesc-consensus" ]; then
        local cache_size=$(du -sh "$CACHE_DIR" | awk '{print $1}')
        local relay_count=$(grep -c "onion-key" "$CACHE_DIR/cached-microdescs" 2>/dev/null || echo 0)
        echo "  缓存: $cache_size | 中继: $relay_count"
    fi
}

# ============================================================
# 桥接管理
# ============================================================
do_bridge() {
    if [ -f "$SCRIPT_DIR/tor-bridge.sh" ]; then
        bash "$SCRIPT_DIR/tor-bridge.sh" "${@:2}"
    else
        err "tor-bridge.sh 不存在"
    fi
}

# ============================================================
# 主入口
# ============================================================
case "${1:-start}" in
    start)   do_start ;;
    stop)    do_stop ;;
    restart) do_restart ;;
    fresh)   do_fresh ;;
    status)  do_status ;;
    bridge)  do_bridge "$@" ;;
    *)       echo "用法: $0 {start|stop|restart|fresh|status|bridge}" ;;
esac
