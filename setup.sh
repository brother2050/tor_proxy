#!/bin/bash
# setup.sh - 下载当前平台二进制 (仅在缺失时)
# ==============================================
# 二进制通常随 git clone 一起下载
# 如果缺失，此脚本从 GitHub Mirror 快速下载
#
# 用法: bash setup.sh

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log() { echo -e "${GREEN}[setup]${NC} $*"; }
warn() { echo -e "${YELLOW}[setup]${NC} $*"; }
err() { echo -e "${RED}[setup]${NC} $*"; }

# 检测平台
detect_platform() {
    local os arch
    case "$(uname -s)" in
        Linux*)  os="linux" ;;
        Darwin*) os="macos" ;;
        CYGWIN*|MINGW*|MSYS*) os="windows" ;;
        *)       err "不支持: $(uname -s)"; exit 1 ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64)  arch="x86_64" ;;
        arm64|aarch64) arch="aarch64" ;;
        *)             arch="$(uname -m)" ;;
    esac
    echo "${os}-${arch}"
}

PLATFORM=$(detect_platform)
BIN_DIR="bin/$PLATFORM"

# 如果二进制已存在，直接退出
if [ -x "$BIN_DIR/tor" ] && [ -x "$BIN_DIR/obfs4proxy" ]; then
    log "二进制已存在，无需下载"
    log "  Tor: $BIN_DIR/tor"
    log "  obfs4proxy: $BIN_DIR/obfs4proxy"
    exit 0
fi

log "平台: $PLATFORM"
log "二进制缺失，开始下载..."
mkdir -p "$BIN_DIR"

# ============================================================
# GitHub Mirror 下载 (比官方源快)
# ============================================================
# 使用 ghfast.top 加速 GitHub Raw
MIRROR="https://ghfast.top/https://raw.githubusercontent.com/brother2050/tor_proxy/master"

download() {
    local name="$1"
    local url="$MIRROR/$BIN_DIR/$name"
    local output="$BIN_DIR/$name"

    log "  下载 $name..."
    if curl -L --connect-timeout 15 --max-time 300 --retry 3 -# -o "$output" "$url" 2>&1; then
        local size=$(stat -c%s "$output" 2>/dev/null || stat -f%z "$output" 2>/dev/null || echo 0)
        if [ "$size" -gt 1024 ]; then
            chmod +x "$output" 2>/dev/null
            log "  ✓ $name ($(( size / 1024 / 1024 ))MB)"
            return 0
        fi
    fi
    rm -f "$output"
    err "  ✗ $name 下载失败"
    return 1
}

failed=0
download "tor" || failed=1
download "obfs4proxy" || failed=1

# macOS 额外下载 libevent
if [ "${PLATFORM%%-*}" = "macos" ]; then
    download "libevent-2.1.7.dylib" || true
    # quarantine
    for f in "$BIN_DIR"/tor "$BIN_DIR"/obfs4proxy; do
        [ -f "$f" ] && xattr -d com.apple.quarantine "$f" 2>/dev/null || true
    done
fi

# Linux 额外下载 libevent
if [ "${PLATFORM%%-*}" = "linux" ]; then
    download "libevent-2.1.so.7.0.1" || true
    [ -f "$BIN_DIR/libevent-2.1.so.7.0.1" ] && ln -sf "libevent-2.1.so.7.0.1" "$BIN_DIR/libevent-2.1.so.7" 2>/dev/null || true
fi

# 创建符号链接
ln -sfn "$PLATFORM" "$SCRIPT_DIR/bin/current" 2>/dev/null || true

if [ $failed -eq 0 ]; then
    log ""
    log "✓ 下载完成"
    log "  运行: ./tor-start.sh start"
else
    err ""
    err "部分文件下载失败，请检查网络后重试"
    exit 1
fi
