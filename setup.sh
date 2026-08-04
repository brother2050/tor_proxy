#!/bin/bash
# setup.sh - 验证并修复 Tor 二进制
# ===================================
# 检查内置二进制是否存在，修复权限和 macOS quarantine
# 二进制已内置在 bin/ 目录中，无需下载
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
        *)       err "不支持的系统: $(uname -s)"; exit 1 ;;
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
OS_TYPE="${PLATFORM%%-*}"

log ""
log "========================================="
log "  Tor Proxy Setup - $PLATFORM"
log "========================================="
log ""

# ============================================================
# 检查二进制
# ============================================================
check_binary() {
    local name="$1"
    local path="$BIN_DIR/$name"

    if [ ! -f "$path" ]; then
        err "✗ $name 不存在: $path"
        echo ""
        echo "  可能原因: git clone 不完整 (大文件未下载)"
        echo "  解决方法:"
        echo "    git lfs pull                        # 如果用了 Git LFS"
        echo "    git clone --depth 1 <url>           # 浅克隆后手动放入"
        echo "    从 Release 页面下载对应平台二进制到 $BIN_DIR/"
        echo ""
        return 1
    fi

    # 修复权限
    if [ ! -x "$path" ]; then
        chmod +x "$path" 2>/dev/null
        if [ -x "$path" ]; then
            log "✓ $name (已修复权限)"
        else
            err "✗ $name 无法设为可执行"
            return 1
        fi
    else
        log "✓ $name"
    fi
    return 0
}

# 检查所有必要二进制
missing=0
check_binary "tor" || missing=1
check_binary "obfs4proxy" || missing=1

# 检查可选二进制
[ -f "$BIN_DIR/snowflake-client" ] && check_binary "snowflake-client" || true
[ -f "$BIN_DIR/libevent-2.1.7.dylib" ] && check_binary "libevent-2.1.7.dylib" || true
[ -f "$BIN_DIR/libevent-2.1.so.7" ] && check_binary "libevent-2.1.so.7" || true
[ -f "$BIN_DIR/libevent-2.1.so.7.0.1" ] && check_binary "libevent-2.1.so.7.0.1" || true

if [ $missing -eq 1 ]; then
    echo ""
    err "缺少必要二进制，请确保 bin/$PLATFORM/ 目录完整"
    exit 1
fi

# ============================================================
# macOS 专属优化
# ============================================================
if [ "$OS_TYPE" = "macos" ]; then
    log ""
    log "macOS 优化..."

    # 移除 Gatekeeper quarantine 标记
    for f in "$BIN_DIR"/tor "$BIN_DIR"/obfs4proxy "$BIN_DIR"/snowflake-client; do
        if [ -f "$f" ]; then
            xattr -d com.apple.quarantine "$f" 2>/dev/null && \
                log "  ✓ 移除 quarantine: $(basename "$f")" || true
        fi
    done

    # libevent 软链接 (macOS dylib 兼容)
    if [ -f "$BIN_DIR/libevent-2.1.7.dylib" ] && [ ! -f "$BIN_DIR/libevent-2.1.dylib" ]; then
        ln -sf "libevent-2.1.7.dylib" "$BIN_DIR/libevent-2.1.dylib" 2>/dev/null || true
    fi

    # UDP 缓冲区提示
    if command -v sysctl &>/dev/null; then
        local_buf=$(sysctl -n net.inet.udp.recvspace 2>/dev/null || echo 0)
        if [ "$local_buf" -lt 524288 ] 2>/dev/null; then
            warn "  UDP 缓冲区较小 ($local_buf)，Snowflake 可能慢"
            info "  建议: sudo sysctl -w net.inet.udp.recvspace=524288"
        fi
    fi
fi

# ============================================================
# 创建符号链接
# ============================================================
log ""
log "创建符号链接..."
ln -sfn "$PLATFORM" "$SCRIPT_DIR/bin/current"
log "  bin/current -> $PLATFORM"

# ============================================================
# 完成
# ============================================================
log ""
log "========================================="
log "  ✓ 验证完成"
log "========================================="
log ""
log "  平台: $PLATFORM"
log "  Tor:  $BIN_DIR/tor"
log "  obfs4proxy: $BIN_DIR/obfs4proxy"
log ""
log "  启动: ./tor-start.sh start"
