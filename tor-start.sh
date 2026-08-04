#!/bin/bash
# tor-start.sh - 启动 Tor 代理 (统一多桥接版)
# =============================================
# 自动检测平台，支持 macOS/Linux/Windows(WSL)
# 自动尝试 Snowflake → obfs4 → meek 降级
#
# 用法:
#   ./tor-start.sh          # 启动 (自动选最优桥接)
#   ./tor-start.sh stop     # 停止
#   ./tor-start.sh restart  # 重启
#   ./tor-start.sh status   # 状态
#   ./tor-start.sh fresh    # 清除缓存并启动
#   ./tor-start.sh refresh  # 刷新描述符缓存
#   ./tor-start.sh setup    # 下载当前平台依赖
#   ./tor-start.sh bridge   # 桥接管理 (list/test/auto/add)

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
OS_TYPE="${PLATFORM%%-*}"  # linux / macos / windows

# ============================================================
# 二进制查找
# ============================================================
find_tor() {
    [ -x "$BIN_DIR/tor" ] && echo "$BIN_DIR/tor" && return
    [ -x "$SCRIPT_DIR/bin/current/tor" ] && echo "$SCRIPT_DIR/bin/current/tor" && return
    [ -x "$SCRIPT_DIR/tor" ] && echo "$SCRIPT_DIR/tor" && return
    command -v tor 2>/dev/null && return
    echo ""
}

find_obfs4proxy() {
    [ -x "$BIN_DIR/obfs4proxy" ] && echo "$BIN_DIR/obfs4proxy" && return
    [ -x "$SCRIPT_DIR/bin/current/obfs4proxy" ] && echo "$SCRIPT_DIR/bin/current/obfs4proxy" && return
    [ -x "$SCRIPT_DIR/obfs4proxy" ] && echo "$SCRIPT_DIR/obfs4proxy" && return
    command -v obfs4proxy 2>/dev/null && return
    echo ""
}

TOR_BIN=$(find_tor)
OBFS4PROXY=$(find_obfs4proxy)
DATA_DIR="$SCRIPT_DIR/data"
LOGS_DIR="$SCRIPT_DIR/logs"
CACHE_DIR="$SCRIPT_DIR/cache/descriptors"
CONFIG_TEMPLATE="$SCRIPT_DIR/config/torrc.template"
CONFIG="$SCRIPT_DIR/config/torrc"
PID_FILE="$DATA_DIR/tor.pid"
SOCKS_PORT=9050

# ============================================================
# OS 专属环境设置
# ============================================================
setup_os_env() {
    # 动态库路径
    if [ -d "$BIN_DIR" ]; then
        export LD_LIBRARY_PATH="$BIN_DIR:${LD_LIBRARY_PATH:-}"
        export DYLD_LIBRARY_PATH="$BIN_DIR:${DYLD_LIBRARY_PATH:-}"
    fi

    # macOS 专属修复
    if [ "$OS_TYPE" = "macos" ]; then
        # 移除 macOS Gatekeeper 隔离标记 (否则二进制可能被阻止运行)
        if [ -f "$BIN_DIR/tor" ]; then
            xattr -d com.apple.quarantine "$BIN_DIR/tor" 2>/dev/null || true
        fi
        if [ -f "$BIN_DIR/obfs4proxy" ]; then
            xattr -d com.apple.quarantine "$BIN_DIR/obfs4proxy" 2>/dev/null || true
        fi
        if [ -f "$BIN_DIR/snowflake-client" ]; then
            xattr -d com.apple.quarantine "$BIN_DIR/snowflake-client" 2>/dev/null || true
        fi

        # macOS SIP 可能限制 DYLD_LIBRARY_PATH，确保 libevent 在同一目录
        # 如果 tor 找不到 libevent，创建软链接
        if [ -f "$BIN_DIR/tor" ] && [ ! -f "$BIN_DIR/libevent-2.1.7.dylib" ]; then
            local libevent=$(find "$BIN_DIR" -name "libevent-2.1*" -o -name "libevent*" 2>/dev/null | head -1)
            if [ -n "$libevent" ] && [ "$libevent" != "$BIN_DIR/libevent-2.1.7.dylib" ]; then
                ln -sf "$(basename "$libevent")" "$BIN_DIR/libevent-2.1.7.dylib" 2>/dev/null || true
            fi
        fi

        # macOS 网络优化：增加 UDP 缓冲区 (Snowflake WebRTC 需要)
        # 这些是 sysctl 建议值，不强制设置
        if command -v sysctl &>/dev/null; then
            local current_buf=$(sysctl -n net.inet.udp.recvspace 2>/dev/null || echo 0)
            if [ "$current_buf" -lt 524288 ] 2>/dev/null; then
                info "提示: macOS UDP 缓冲区较小 ($current_buf)，建议执行:"
                info "  sudo sysctl -w net.inet.udp.recvspace=524288"
                info "  sudo sysctl -w net.inet.udp.maxdgram=524288"
            fi
        fi
    fi

    # Linux 专属优化
    if [ "$OS_TYPE" = "linux" ]; then
        # 增加文件描述符限制
        if command -v ulimit &>/dev/null; then
            ulimit -n 4096 2>/dev/null || true
        fi
    fi
}

# ============================================================
# 颜色和日志
# ============================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log() { echo -e "${GREEN}[tor]${NC} $*"; }
warn() { echo -e "${YELLOW}[tor]${NC} $*"; }
err() { echo -e "${RED}[tor]${NC} $*"; }
info() { echo -e "${CYAN}[tor]${NC} $*"; }

# ============================================================
# 依赖检查
# ============================================================
check_deps() {
    local missing=0
    if [ -z "$TOR_BIN" ]; then
        err "Tor 二进制未找到 (平台: $PLATFORM)"
        echo "  运行: ./tor-start.sh setup"
        missing=1
    fi
    if [ -z "$OBFS4PROXY" ]; then
        warn "obfs4proxy 未找到 (Snowflake/obfs4 可能不工作)"
        echo "  运行: ./tor-start.sh setup"
    fi
    [ $missing -eq 1 ] && return 1
    return 0
}

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

    # 如果用户有自定义桥接，追加到配置
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
        log "已加载用户自定义桥接: $user_bridges"
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
    info "部署缓存描述符 ($cache_size, $relay_count 中继)..."
    mkdir -p "$DATA_DIR"
    cp "$CACHE_DIR/cached-certs" "$DATA_DIR/" 2>/dev/null
    cp "$CACHE_DIR/cached-microdesc-consensus" "$DATA_DIR/" 2>/dev/null
    cp "$CACHE_DIR/cached-microdescs" "$DATA_DIR/" 2>/dev/null
    log "✓ 缓存已部署 - 启动应该很快 (~30-45s)"
}

sync_to_cache() {
    mkdir -p "$CACHE_DIR"
    local synced=0
    for f in cached-certs cached-microdesc-consensus cached-microdescs; do
        if [ -f "$DATA_DIR/$f" ]; then
            local src_size=$(stat -c%s "$DATA_DIR/$f" 2>/dev/null || stat -f%z "$DATA_DIR/$f" 2>/dev/null || echo 0)
            local dst_size=$(stat -c%s "$CACHE_DIR/$f" 2>/dev/null || stat -f%z "$CACHE_DIR/$f" 2>/dev/null || echo 0)
            if [ "$src_size" -gt 0 ] && [ "$src_size" -gt "$dst_size" ] 2>/dev/null; then
                cp "$DATA_DIR/$f" "$CACHE_DIR/$f"
                synced=$((synced + 1))
            fi
        fi
    done
    [ "$synced" -gt 0 ] && log "已同步 $synced 个文件到缓存"
}

# ============================================================
# 核心：启动 Tor (带 bootstrap 进度和超时)
# ============================================================
do_start() {
    if is_running; then
        log "已在运行 (PID: $(get_pid))"
        return 0
    fi

    check_deps || return 1
    setup_os_env
    generate_config || return 1

    mkdir -p "$DATA_DIR" "$LOGS_DIR"
    rm -f "$DATA_DIR/pid" "$DATA_DIR/lock" 2>/dev/null

    # 检查缓存有效性
    local need_cache=false
    if [ ! -f "$DATA_DIR/cached-microdesc-consensus" ]; then
        need_cache=true
    else
        # 检查 consensus 是否过期
        local valid_until=$(grep "valid-until" "$DATA_DIR/cached-microdesc-consensus" 2>/dev/null | awk '{print $2, $3}')
        if [ -n "$valid_until" ]; then
            local until_ts
            until_ts=$(date -d "$valid_until" +%s 2>/dev/null || date -jf "%Y-%m-%d %H:%M:%S" "$valid_until" +%s 2>/dev/null || echo 0)
            local now_ts=$(date +%s)
            local remaining=$(( (until_ts - now_ts) / 60 ))
            [ "$remaining" -lt 30 ] 2>/dev/null && need_cache=true
        fi
    fi
    $need_cache && deploy_cache

    log "启动 Tor ($PLATFORM)..."
    log "配置: $CONFIG"

    # 清理旧日志
    : > "$LOGS_DIR/tor.log" 2>/dev/null

    nohup "$TOR_BIN" -f "$CONFIG" </dev/null >"$LOGS_DIR/startup.log" 2>&1 &
    local pid=$!
    echo "$pid" > "$PID_FILE"

    # ============================================================
    # Bootstrap 等待 - 带进度显示和智能超时
    # ============================================================
    log "等待引导连接..."
    local start_time=$(date +%s)
    local last_pct=0
    local stuck_count=0
    local max_stuck=30  # 60秒无进度则认为卡住 (30 * 2s)

    for i in $(seq 1 200); do
        sleep 2

        # 检查进程是否还活着
        if ! kill -0 "$pid" 2>/dev/null; then
            echo ""
            err "Tor 进程已退出!"
            [ -f "$LOGS_DIR/tor.log" ] && tail -5 "$LOGS_DIR/tor.log"
            return 1
        fi

        # 解析 bootstrap 进度
        if [ -f "$LOGS_DIR/tor.log" ]; then
            local pct
            pct=$(grep -oP 'Bootstrapped \K\d+' "$LOGS_DIR/tor.log" 2>/dev/null | tail -1 || \
                  grep -o 'Bootstrapped [0-9]*%' "$LOGS_DIR/tor.log" 2>/dev/null | tail -1 | grep -o '[0-9]*' || \
                  echo "")

            if [ -n "$pct" ]; then
                # 检测是否卡住
                if [ "$pct" = "$last_pct" ]; then
                    stuck_count=$((stuck_count + 1))
                else
                    stuck_count=0
                    last_pct="$pct"
                fi

                # 完成
                if [ "$pct" = "100" ]; then
                    local elapsed=$(($(date +%s) - start_time))
                    echo ""
                    log "✓ 引导完成 (${elapsed}s)"
                    log "  SOCKS 代理: socks5h://127.0.0.1:$SOCKS_PORT"
                    sync_to_cache
                    # 后台刷新描述符
                    if [ -f "$SCRIPT_DIR/tor-refresh.sh" ]; then
                        nohup "$SCRIPT_DIR/tor-refresh.sh" >>"$LOGS_DIR/refresh.log" 2>&1 &
                    fi
                    return 0
                fi

                # 进度显示
                [ $((i % 3)) -eq 0 ] && printf "\r  引导进度: %s%% (已等待 %ds)" "$pct" "$(( $(date +%s) - start_time ))"
            fi

            # 检测错误
            if grep -qi "failed\|error\|refused\|unreachable" "$LOGS_DIR/tor.log" 2>/dev/null; then
                local err_msg
                err_msg=$(grep -i "failed\|error\|refused\|unreachable" "$LOGS_DIR/tor.log" 2>/dev/null | tail -1)
                # 只有非 bridge 相关的错误才报错
                if echo "$err_msg" | grep -qi "bridge\|pluggable\|transport"; then
                    [ $((i % 10)) -eq 0 ] && warn "桥接连接中... ($err_msg)"
                fi
            fi

            # 卡住超时 - 尝试重启
            if [ "$stuck_count" -ge "$max_stuck" ]; then
                echo ""
                warn "Bootstrap 卡在 ${last_pct}% 已超过 $((max_stuck * 2))秒"
                warn "尝试重启 Tor..."
                kill "$pid" 2>/dev/null
                sleep 2
                kill -9 "$pid" 2>/dev/null || true
                rm -f "$PID_FILE"

                # 重启
                nohup "$TOR_BIN" -f "$CONFIG" </dev/null >"$LOGS_DIR/startup.log" 2>&1 &
                pid=$!
                echo "$pid" > "$PID_FILE"
                stuck_count=0
                log "Tor 已重启 (PID: $pid)"
            fi
        fi
    done

    echo ""
    warn "Bootstrap 超时 (400s)。检查日志: tail -f $LOGS_DIR/tor.log"
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
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
        log "已停止"
    else
        warn "未在运行"
    fi
    rm -f "$PID_FILE"
    return 0
}

do_restart() { do_stop; sleep 2; do_start; }

do_fresh() {
    log "清除所有缓存..."
    do_stop
    rm -rf "$DATA_DIR"/*
    mkdir -p "$DATA_DIR"
    do_start
}

do_refresh() {
    log "刷新描述符缓存..."
    if [ -f "$SCRIPT_DIR/tor-refresh.sh" ]; then
        if is_running; then
            "$SCRIPT_DIR/tor-refresh.sh"
        else
            do_start
            "$SCRIPT_DIR/tor-refresh.sh"
        fi
    else
        warn "tor-refresh.sh 不存在"
    fi
}

do_setup() {
    bash "$SCRIPT_DIR/setup.sh"
}

# ============================================================
# 状态显示
# ============================================================
do_status() {
    echo -e "${CYAN}=== Tor Proxy 状态 ===${NC}"
    echo "  平台: $PLATFORM"
    echo "  Tor: ${TOR_BIN:-未找到}"
    echo "  obfs4proxy: ${OBFS4PROXY:-未找到}"
    echo "  配置: $CONFIG"
    echo ""
    if is_running; then
        log "运行中 (PID: $(get_pid))"
    else
        warn "未运行"
    fi
    [ -f "$LOGS_DIR/tor.log" ] && grep "Bootstrapped" "$LOGS_DIR/tor.log" 2>/dev/null | tail -1
    echo ""

    # 显示当前桥接状态
    echo -e "${CYAN}=== 桥接配置 ===${NC}"
    if [ -f "$CONFIG" ]; then
        grep "^Bridge " "$CONFIG" 2>/dev/null | while read -r line; do
            local btype=$(echo "$line" | awk '{print $2}')
            echo "  [$btype] ${line:0:80}..."
        done
    fi
    echo ""

    # 显示缓存状态
    echo -e "${CYAN}=== 描述符缓存 ===${NC}"
    if [ -f "$CACHE_DIR/cached-microdesc-consensus" ]; then
        local cache_size=$(du -sh "$CACHE_DIR" | awk '{print $1}')
        local relay_count=$(grep -c "onion-key" "$CACHE_DIR/cached-microdescs" 2>/dev/null || echo 0)
        echo "  大小: $cache_size | 中继: $relay_count"
    else
        echo "  无缓存"
    fi
}

# ============================================================
# 桥接管理入口
# ============================================================
do_bridge() {
    if [ -f "$SCRIPT_DIR/tor-bridge.sh" ]; then
        bash "$SCRIPT_DIR/tor-bridge.sh" "${@:2}"
    else
        err "tor-bridge.sh 不存在"
        echo "  可以手动编辑 bridges.txt 添加桥接"
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
    refresh) do_refresh ;;
    setup)   do_setup ;;
    status)  do_status ;;
    bridge)  do_bridge "$@" ;;
    *)       echo "用法: $0 {start|stop|restart|fresh|refresh|setup|status|bridge}" ;;
esac
