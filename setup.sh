#!/bin/bash
# setup.sh - 自动下载对应平台的 Tor + obfs4proxy
# ================================================
# 首次使用前运行此脚本，自动下载当前平台的依赖
#
# 用法: bash setup.sh
#
# 环境变量:
#   TOR_MIRROR  - 自定义镜像地址 (如: https://ghfast.top/https://github.com/xxx)
#   TOR_VERSION - 指定 Tor 版本 (如: 14.5)

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

# ============================================================
# 下载源配置 (多镜像 + 国内加速)
# ============================================================

# Tor 版本列表 (从新到旧尝试)
TOR_VERSIONS="${TOR_VERSION:-14.5 14.0 13.5 13.0.9}"

# 官方源
OFFICIAL_BASE="https://dist.torproject.org/torbrowser"

# 国内镜像源 (按优先级排序)
# ghfast.top 可加速 GitHub release 等
# 如有其他镜像可自行添加
MIRROR_SOURCES=(
    ""  # 空字符串表示使用官方源
    "https://ghfast.top/https://github.com/nickmolo/tor-expert-bundle/releases/download"
    "https://ghproxy.com/https://github.com/nickmolo/tor-expert-bundle/releases/download"
)

# 构建下载 URL 列表
get_download_urls() {
    local ver="$1"
    local urls=()

    # 官方源 (每个版本)
    case "$PLATFORM" in
        linux-x86_64)
            urls+=("${OFFICIAL_BASE}/${ver}/tor-expert-bundle-linux-x86_64-${ver}.tar.gz")
            ;;
        macos-x86_64)
            urls+=("${OFFICIAL_BASE}/${ver}/tor-expert-bundle-macos-x86_64-${ver}.tar.gz")
            ;;
        macos-aarch64)
            urls+=("${OFFICIAL_BASE}/${ver}/tor-expert-bundle-macos-aarch64-${ver}.tar.gz")
            ;;
        windows-x86_64)
            urls+=("${OFFICIAL_BASE}/${ver}/tor-expert-bundle-windows-x86_64-${ver}.tar.gz")
            urls+=("${OFFICIAL_BASE}/${ver}/tor-expert-bundle-windows-i686-${ver}.tar.gz")
            ;;
    esac

    # 镜像源 (如果有 GitHub release 镜像)
    for mirror in "${MIRROR_SOURCES[@]}"; do
        [ -z "$mirror" ] && continue
        case "$PLATFORM" in
            linux-x86_64)
                urls+=("${mirror}/tor-expert-bundle-${ver}/tor-expert-bundle-linux-x86_64-${ver}.tar.gz")
                ;;
            macos-x86_64)
                urls+=("${mirror}/tor-expert-bundle-${ver}/tor-expert-bundle-macos-x86_64-${ver}.tar.gz")
                ;;
            macos-aarch64)
                urls+=("${mirror}/tor-expert-bundle-${ver}/tor-expert-bundle-macos-aarch64-${ver}.tar.gz")
                ;;
            windows-x86_64)
                urls+=("${mirror}/tor-expert-bundle-${ver}/tor-expert-bundle-windows-x86_64-${ver}.tar.gz")
                ;;
        esac
    done

    # 自定义镜像
    if [ -n "${TOR_MIRROR:-}" ]; then
        case "$PLATFORM" in
            linux-x86_64)
                urls=("${TOR_MIRROR}/tor-expert-bundle-linux-x86_64-${ver}.tar.gz" "${urls[@]}")
                ;;
            macos-x86_64)
                urls=("${TOR_MIRROR}/tor-expert-bundle-macos-x86_64-${ver}.tar.gz" "${urls[@]}")
                ;;
            macos-aarch64)
                urls=("${TOR_MIRROR}/tor-expert-bundle-macos-aarch64-${ver}.tar.gz" "${urls[@]}")
                ;;
            windows-x86_64)
                urls=("${TOR_MIRROR}/tor-expert-bundle-windows-x86_64-${ver}.tar.gz" "${urls[@]}")
                ;;
        esac
    fi

    printf '%s\n' "${urls[@]}"
}

# ============================================================
# 下载函数 (多线程加速 + 断点续传 + 重试)
# ============================================================
download_file() {
    local url="$1"
    local output="$2"
    local max_retries="${3:-3}"
    local threads="${4:-8}"
    local retry=0

    # 优先使用 Python 多线程下载器
    local axel="$SCRIPT_DIR/download-axel.py"
    if [ -f "$axel" ] && command -v python3 &>/dev/null; then
        log "  使用多线程下载 ($threads 线程)..."
        if python3 "$axel" "$url" "$output" "$threads" 2>&1; then
            # 验证文件
            local fsize=$(stat -c%s "$output" 2>/dev/null || stat -f%z "$output" 2>/dev/null || echo 0)
            if [ "$fsize" -gt 1024 ] 2>/dev/null; then
                return 0
            fi
        fi
        warn "  多线程下载失败，回退到 curl..."
    fi

    # 回退: curl 单线程下载
    while [ $retry -lt $max_retries ]; do
        retry=$((retry + 1))
        log "  curl 下载 ($retry/$max_retries): ${url:0:60}..."

        if curl -C - -L \
            --connect-timeout 10 \
            --max-time 300 \
            --retry 2 \
            --retry-delay 3 \
            -# \
            -o "$output" \
            "$url" 2>&1; then

            local fsize=$(stat -c%s "$output" 2>/dev/null || stat -f%z "$output" 2>/dev/null || echo 0)
            if [ "$fsize" -gt 1024 ] 2>/dev/null; then
                log "  ✓ 下载成功"
                return 0
            else
                warn "  文件太小 (${fsize}B)"
                rm -f "$output"
            fi
        else
            warn "  curl 失败 (退出码: $?)"
        fi

        if [ $retry -lt $max_retries ]; then
            sleep $((retry * 3))
        fi
    done

    return 1
}

# ============================================================
# 下载 Tor
# ============================================================
download_tor() {
    if [ -f "$BIN_DIR/tor" ] && [ -x "$BIN_DIR/tor" ]; then
        log "Tor 已存在: $BIN_DIR/tor"
        # 验证二进制是否可用
        if "$BIN_DIR/tor" --version >/dev/null 2>&1; then
            return 0
        else
            warn "Tor 二进制不可用，重新下载..."
            rm -f "$BIN_DIR/tor"
        fi
    fi

    log "下载 Tor ($PLATFORM)..."

    for ver in $TOR_VERSIONS; do
        local urls
        urls=$(get_download_urls "$ver")
        local tmpfile="/tmp/tor-${PLATFORM}-${ver}.tar.gz"

        for url in $urls; do
            log "  尝试 v${ver}: ${url:0:60}..."

            if download_file "$url" "$tmpfile" 2; then
                log "  解压中..."
                local extdir="/tmp/tor-extract-${PLATFORM}"
                rm -rf "$extdir" && mkdir -p "$extdir"

                if tar xzf "$tmpfile" -C "$extdir" 2>/dev/null; then
                    # 查找 tor 二进制
                    local tor_bin=$(find "$extdir" -name "tor" -type f 2>/dev/null | head -1)
                    [ -z "$tor_bin" ] && tor_bin=$(find "$extdir" -name "tor.exe" -type f 2>/dev/null | head -1)

                    if [ -n "$tor_bin" ]; then
                        cp "$tor_bin" "$BIN_DIR/"
                        chmod +x "$BIN_DIR/$(basename "$tor_bin")"

                        # 复制 obfs4proxy
                        local obfs4_bin=$(find "$extdir" -name "obfs4proxy" -type f 2>/dev/null | head -1)
                        [ -z "$obfs4_bin" ] && obfs4_bin=$(find "$extdir" -name "obfs4proxy.exe" -type f 2>/dev/null | head -1)
                        if [ -n "$obfs4_bin" ]; then
                            cp "$obfs4_bin" "$BIN_DIR/"
                            chmod +x "$BIN_DIR/$(basename "$obfs4_bin")" 2>/dev/null
                            log "  ✓ obfs4proxy 也已安装"
                        fi

                        # 复制 snowflake-client
                        local sf_bin=$(find "$extdir" -name "snowflake-client" -type f 2>/dev/null | head -1)
                        if [ -n "$sf_bin" ]; then
                            cp "$sf_bin" "$BIN_DIR/"
                            chmod +x "$BIN_DIR/$(basename "$sf_bin")" 2>/dev/null
                            log "  ✓ snowflake-client 也已安装"
                        fi

                        # 复制 libevent (macOS 需要)
                        local libevent=$(find "$extdir" -name "libevent*" -type f 2>/dev/null | head -1)
                        if [ -n "$libevent" ]; then
                            cp "$libevent" "$BIN_DIR/"
                            log "  ✓ libevent 也已安装"
                        fi

                        # macOS: 移除 Gatekeeper 隔离标记
                        if [ "${PLATFORM%%-*}" = "macos" ]; then
                            for f in "$BIN_DIR"/tor "$BIN_DIR"/obfs4proxy "$BIN_DIR"/snowflake-client; do
                                [ -f "$f" ] && xattr -d com.apple.quarantine "$f" 2>/dev/null || true
                            done
                            log "  ✓ macOS quarantine 标记已移除"
                        fi

                        rm -rf "$extdir" "$tmpfile"
                        log "  ✓ Tor v${ver} 安装成功 -> $BIN_DIR/"
                        return 0
                    fi
                fi
                rm -rf "$extdir"
            fi
            rm -f "$tmpfile"
        done
    done

    err "下载 Tor 失败 (所有源都不可用)"
    echo ""
    echo "  手动下载方法:"
    echo "  1. 访问 https://www.torproject.org/download/tor/"
    echo "  2. 下载 Expert Bundle (对应平台)"
    echo "  3. 解压后将 tor/obfs4proxy 放入 $BIN_DIR/"
    echo ""
    echo "  或设置自定义镜像:"
    echo "  TOR_MIRROR=https://your-mirror.com/path bash setup.sh"
    return 1
}

# ============================================================
# 编译 obfs4proxy (从源码)
# ============================================================
compile_obfs4proxy() {
    if [ -f "$BIN_DIR/obfs4proxy" ]; then
        log "obfs4proxy 已存在: $BIN_DIR/obfs4proxy"
        return 0
    fi

    # 检查 Go SDK
    local go_bin="deps/go-sdk/go/bin/go"
    if [ ! -f "$go_bin" ]; then
        warn "Go SDK 未找到 (deps/go-sdk/)"
        warn "obfs4proxy 需要手动编译"
        return 1
    fi

    log "编译 obfs4proxy ($PLATFORM)..."
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
        log "✓ obfs4proxy 编译成功"
        return 0
    else
        err "obfs4proxy 编译失败"
        return 1
    fi
}

# ============================================================
# macOS 专属优化
# ============================================================
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

# ============================================================
# 主流程
# ============================================================
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
log "创建平台符号链接..."
ln -sfn "$PLATFORM" "$SCRIPT_DIR/bin/current"

log ""
log "========================================="
log "  安装完成!"
log "========================================="
log ""
log "  平台:     $PLATFORM"
log "  Tor:      $BIN_DIR/tor"
[ -f "$BIN_DIR/obfs4proxy" ] && log "  obfs4proxy: $BIN_DIR/obfs4proxy"
log ""
log "  启动: ./tor-start.sh start"
