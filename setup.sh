#!/bin/bash
# setup.sh - 自动下载对应平台的 Tor + obfs4proxy
# ================================================
# 首次使用前运行此脚本，自动下载当前平台的依赖
#
# 用法: bash setup.sh

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log() { echo -e "${GREEN}[setup]${NC} $*"; }
warn() { echo -e "${YELLOW}[setup]${NC} $*"; }
err() { echo -e "${RED}[setup]${NC} $*"; }
info() { echo -e "${CYAN}[setup]${NC} $*"; }

# 检测平台
detect_platform() {
    local os arch
    case "$(uname -s)" in
        Linux*)  os="linux" ;;
        Darwin*) os="macos" ;;
        CYGWIN*|MINGW*|MSYS*) os="windows" ;;
        *)       err "Unsupported OS: $(uname -s)"; exit 1 ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64)  arch="x86_64" ;;
        arm64|aarch64) arch="aarch64" ;;
        *)             arch="$(uname -m)" ;;
    esac
    echo "${os}-${arch}"
}

PLATFORM=$(detect_platform)
log "Platform: $PLATFORM"

BIN_DIR="bin/$PLATFORM"
mkdir -p "$BIN_DIR"

# Tor 下载地址 (多版本尝试)
TOR_VERSIONS="14.5 14.0 13.5 13.0.9"
get_tor_urls() {
    local ver="$1"
    case "$PLATFORM" in
        linux-x86_64)
            echo "https://dist.torproject.org/torbrowser/${ver}/tor-expert-bundle-linux-x86_64-${ver}.tar.gz"
            ;;
        macos-x86_64)
            echo "https://dist.torproject.org/torbrowser/${ver}/tor-expert-bundle-macos-x86_64-${ver}.tar.gz"
            ;;
        macos-aarch64)
            echo "https://dist.torproject.org/torbrowser/${ver}/tor-expert-bundle-macos-aarch64-${ver}.tar.gz"
            ;;
        windows-x86_64)
            echo "https://dist.torproject.org/torbrowser/${ver}/tor-expert-bundle-windows-i686-${ver}.tar.gz"
            echo "https://dist.torproject.org/torbrowser/${ver}/tor-expert-bundle-windows-x86_64-${ver}.tar.gz"
            ;;
    esac
}

# 下载 Tor
download_tor() {
    if [ -f "$BIN_DIR/tor" ] && [ -x "$BIN_DIR/tor" ]; then
        log "Tor already exists: $BIN_DIR/tor"
        return 0
    fi

    log "Downloading Tor for $PLATFORM..."

    for ver in $TOR_VERSIONS; do
        local url=$(get_tor_urls "$ver")
        local tmpfile="/tmp/tor-${PLATFORM}-${ver}.tar.gz"

        log "  Trying v${ver}..."
        if curl -sL --connect-timeout 15 --max-time 120 "$url" -o "$tmpfile" 2>/dev/null; then
            if [ -f "$tmpfile" ] && [ -s "$tmpfile" ]; then
                log "  Extracting..."
                local extdir="/tmp/tor-extract-${PLATFORM}"
                rm -rf "$extdir" && mkdir -p "$extdir"
                tar xzf "$tmpfile" -C "$extdir" 2>/dev/null

                # 查找 tor 二进制 (可能在不同子目录)
                local tor_bin=$(find "$extdir" -name "tor" -type f -perm +111 2>/dev/null | head -1)
                if [ -n "$tor_bin" ]; then
                    cp "$tor_bin" "$BIN_DIR/tor"
                    chmod +x "$BIN_DIR/tor"

                    # 复制 obfs4proxy (如果存在)
                    local obfs4_bin=$(find "$extdir" -name "obfs4proxy" -type f -perm +111 2>/dev/null | head -1)
                    if [ -n "$obfs4_bin" ]; then
                        cp "$obfs4_bin" "$BIN_DIR/obfs4proxy"
                        chmod +x "$BIN_DIR/obfs4proxy"
                        log "  ✓ obfs4proxy also found"
                    fi

                    # 复制 snowflake-client (如果存在)
                    local sf_bin=$(find "$extdir" -name "snowflake-client" -type f -perm +111 2>/dev/null | head -1)
                    if [ -n "$sf_bin" ]; then
                        cp "$sf_bin" "$BIN_DIR/snowflake-client"
                        chmod +x "$BIN_DIR/snowflake-client"
                        log "  ✓ snowflake-client also found"
                    fi

                    # macOS: 移除 Gatekeeper 隔离标记 (否则二进制可能被阻止运行)
                    if [ "${PLATFORM%%-*}" = "macos" ]; then
                        xattr -d com.apple.quarantine "$BIN_DIR/tor" 2>/dev/null || true
                        [ -f "$BIN_DIR/obfs4proxy" ] && xattr -d com.apple.quarantine "$BIN_DIR/obfs4proxy" 2>/dev/null || true
                        [ -f "$BIN_DIR/snowflake-client" ] && xattr -d com.apple.quarantine "$BIN_DIR/snowflake-client" 2>/dev/null || true
                        log "  ✓ macOS quarantine 标记已移除"
                    fi

                    rm -rf "$extdir" "$tmpfile"
                    log "  ✓ Tor v${ver} installed to $BIN_DIR/tor"
                    return 0
                fi
                rm -rf "$extdir"
            fi
        fi
        rm -f "$tmpfile"
    done

    err "Failed to download Tor for $PLATFORM"
    err "Please download manually from: https://www.torproject.org/download/tor/"
    return 1
}

# 交叉编译 obfs4proxy (从源码)
compile_obfs4proxy() {
    if [ -f "$BIN_DIR/obfs4proxy" ]; then
        log "obfs4proxy already exists: $BIN_DIR/obfs4proxy"
        return 0
    fi

    # 检查 Go SDK
    local go_bin="deps/go-sdk/go/bin/go"
    if [ ! -f "$go_bin" ]; then
        warn "Go SDK not found at deps/go-sdk/"
        warn "obfs4proxy needs to be compiled manually"
        return 1
    fi

    log "Compiling obfs4proxy for $PLATFORM..."
    export GOROOT="$SCRIPT_DIR/deps/go-sdk/go"
    export PATH="$GOROOT/bin:$PATH"
    export GOPATH="$SCRIPT_DIR/deps/gopath"
    export GO111MODULE=on
    export GOPROXY=https://goproxy.cn,direct

    local goos goarch output_ext=""
    case "$PLATFORM" in
        linux-x86_64)   goos="linux"  goarch="amd64" ;;
        macos-x86_64)   goos="darwin" goarch="amd64" ;;
        macos-aarch64)  goos="darwin" goarch="arm64" ;;
        windows-x86_64) goos="windows" goarch="amd64"; output_ext=".exe" ;;
    esac

    cd src/obfs4 && chmod -R u+w .
    GOOS="$goos" GOARCH="$goarch" go build -o "$SCRIPT_DIR/$BIN_DIR/obfs4proxy${output_ext}" ./cmd/lyrebird/
    cd "$SCRIPT_DIR"

    if [ -f "$BIN_DIR/obfs4proxy${output_ext}" ]; then
        log "✓ obfs4proxy compiled for $PLATFORM"
        return 0
    else
        err "Failed to compile obfs4proxy"
        return 1
    fi
}

# macOS 专属优化
macos_optimize() {
    if [ "${PLATFORM%%-*}" != "macos" ]; then
        return 0
    fi

    log ""
    log "macOS 优化检查..."

    # 1. 移除所有二进制的 quarantine 标记
    for bin in "$BIN_DIR/tor" "$BIN_DIR/obfs4proxy" "$BIN_DIR/snowflake-client"; do
        if [ -f "$bin" ]; then
            xattr -d com.apple.quarantine "$bin" 2>/dev/null && \
                log "  ✓ 移除 quarantine: $(basename "$bin")" || true
        fi
    done

    # 2. 检查 UDP 缓冲区 (Snowflake WebRTC 需要)
    if command -v sysctl &>/dev/null; then
        local current_buf=$(sysctl -n net.inet.udp.recvspace 2>/dev/null || echo 0)
        if [ "$current_buf" -lt 524288 ] 2>/dev/null; then
            warn "  macOS UDP 缓冲区较小 ($current_buf bytes)"
            warn "  Snowflake 可能连接慢，建议执行:"
            warn "    sudo sysctl -w net.inet.udp.recvspace=524288"
            warn "    sudo sysctl -w net.inet.udp.maxdgram=524288"
        else
            log "  ✓ UDP 缓冲区: $current_buf bytes"
        fi
    fi

    # 3. 检查 SIP 限制
    if command -v csrutil &>/dev/null; then
        local sip_status=$(csrutil status 2>/dev/null | grep -o 'enabled\|disabled' || echo "unknown")
        if [ "$sip_status" = "enabled" ]; then
            info "  SIP 已启用 (正常) - DYLD_LIBRARY_PATH 可能受限"
            info "  确保 libevent 和 tor 在同一目录: $BIN_DIR"
        fi
    fi
}

# 主流程
log ""
log "========================================="
log "  Tor Proxy Setup - $PLATFORM"
log "========================================="
log ""

download_tor
compile_obfs4proxy
macos_optimize

# 创建平台符号链接
log ""
log "Creating platform symlink..."
ln -sfn "$PLATFORM" "$SCRIPT_DIR/bin/current"

log ""
log "========================================="
log "  Setup Complete!"
log "========================================="
log ""
log "  Platform: $PLATFORM"
log "  Tor:      $BIN_DIR/tor"
[ -f "$BIN_DIR/obfs4proxy" ] && log "  obfs4proxy: $BIN_DIR/obfs4proxy"
log ""
log "  Run: ./tor-start.sh start"
