#!/bin/bash
# tor-quick-restart.sh - 快速重启 Tor (跳过缓存部署)
# ====================================================
# 当 Tor 卡住时使用，快速重启获得新 Snowflake 连接

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

detect_platform() {
    local os arch
    case "$(uname -s)" in Linux*) os="linux";; Darwin*) os="macos";; *) os="unknown";; esac
    case "$(uname -m)" in x86_64|amd64) arch="x86_64";; arm64|aarch64) arch="aarch64";; *) arch="$(uname -m)";; esac
    echo "${os}-${arch}"
}

PLATFORM=$(detect_platform)
BIN_DIR="$SCRIPT_DIR/bin/$PLATFORM"
TOR_BIN="$BIN_DIR/tor"
OBFS4PROXY="$BIN_DIR/obfs4proxy"
CONFIG="$SCRIPT_DIR/config/torrc"
PID_FILE="$SCRIPT_DIR/data/tor.pid"

export LD_LIBRARY_PATH="$BIN_DIR:${LD_LIBRARY_PATH:-}"
export DYLD_LIBRARY_PATH="$BIN_DIR:${DYLD_LIBRARY_PATH:-}"

log() { echo -e "\033[0;32m[tor]\033[0m $*"; }

# 停止
pid=$(cat "$PID_FILE" 2>/dev/null)
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    log "Stopping Tor (PID: $pid)..."
    kill "$pid" 2>/dev/null; sleep 1
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
fi
rm -f "$PID_FILE"

# 清理 Snowflake 状态 (强制新连接)
rm -rf "$SCRIPT_DIR/data/pt_state" 2>/dev/null
rm -f "$SCRIPT_DIR/data/cached-consensus" 2>/dev/null
rm -f "$SCRIPT_DIR/data/cached-microdesc-consensus" 2>/dev/null

log "Restarting Tor with fresh Snowflake connection..."

# 重新生成配置
TEMPLATE="$SCRIPT_DIR/config/torrc.template"
if [ -f "$TEMPLATE" ]; then
    escaped_dir=$(printf '%s\n' "$SCRIPT_DIR" | sed 's/[[\.*^$()+?{|/]/\\&/g')
    escaped_obfs4=$(printf '%s\n' "$OBFS4PROXY" | sed 's/[[\.*^$()+?{|/]/\\&/g')
    sed -e "s|__DIR__|${escaped_dir}|g" -e "s|__OBFS4PROXY__|${escaped_obfs4}|g" "$TEMPLATE" > "$CONFIG"
fi

# 部署缓存描述符
if [ -d "$SCRIPT_DIR/cache/descriptors" ]; then
    cp "$SCRIPT_DIR/cache/descriptors/cached-"* "$SCRIPT_DIR/data/" 2>/dev/null
fi

# 启动
nohup "$TOR_BIN" -f "$CONFIG" </dev/null >"$SCRIPT_DIR/logs/startup.log" 2>&1 &
echo $! > "$PID_FILE"
log "PID: $(cat $PID_FILE)"

# 等待引导，带进度监控和超时
log "Waiting for bootstrap..."
start_time=$(date +%s)
last_pct=0
stuck_count=0

for i in $(seq 1 200); do
    sleep 3
    if [ -f "$SCRIPT_DIR/logs/tor.log" ]; then
        pct=$(grep -oP 'Bootstrapped \K\d+' "$SCRIPT_DIR/logs/tor.log" 2>/dev/null | tail -1)
        if [ -n "$pct" ]; then
            if [ "$pct" = "100" ]; then
                elapsed=$(($(date +%s) - start_time))
                echo ""
                log "✓ Bootstrap complete (${elapsed}s)"
                log "  SOCKS proxy: socks5h://127.0.0.1:9050"
                exit 0
            fi
            # 检测卡住
            if [ "$pct" = "$last_pct" ]; then
                stuck_count=$((stuck_count + 1))
                if [ "$stuck_count" -gt 15 ]; then
                    echo ""
                    log "Stuck at ${pct}% for $((stuck_count * 3))s, restarting..."
                    stuck_count=0
                    # 重启
                    pid=$(cat "$PID_FILE" 2>/dev/null)
                    kill "$pid" 2>/dev/null; sleep 2
                    rm -rf "$SCRIPT_DIR/data/pt_state" 2>/dev/null
                    nohup "$TOR_BIN" -f "$CONFIG" </dev/null >"$SCRIPT_DIR/logs/startup.log" 2>&1 &
                    echo $! > "$PID_FILE"
                    log "Restarted (PID: $(cat $PID_FILE))"
                fi
            else
                stuck_count=0
            fi
            last_pct=$pct
            printf "\r  Bootstrap: %s%%" "$pct"
        fi
    fi
done

echo ""
log "Timeout. Check: tail $SCRIPT_DIR/logs/tor.log"
exit 1
