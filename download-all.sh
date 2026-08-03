#!/bin/bash
# download-all.sh - 一键下载所有平台 Tor 二进制到项目中
# ========================================================
# 在有网络的机器上运行此脚本，自动下载并放入 bin/ 目录
# 下载完成后 git push 即可
#
# 用法: bash download-all.sh

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

VERSION="14.0"
BASE_URL="https://dist.torproject.org/torbrowser/${VERSION}"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
log() { echo -e "${GREEN}[download]${NC} $*"; }
err() { echo -e "${RED}[download]${NC} $*"; }

# 下载并解压
download_and_extract() {
    local url="$1"
    local dest_dir="$2"
    local desc="$3"

    mkdir -p "$dest_dir"
    local tmpfile="/tmp/tor-$(basename "$url")"

    log "Downloading $desc..."
    if ! curl -sL --connect-timeout 15 --max-time 300 "$url" -o "$tmpfile"; then
        err "  Failed to download $desc"
        return 1
    fi

    if [ ! -s "$tmpfile" ]; then
        err "  Empty file for $desc"
        return 1
    fi

    log "  Extracting..."
    local extdir="/tmp/tor-ext-$$"
    rm -rf "$extdir" && mkdir -p "$extdir"
    tar xzf "$tmpfile" -C "$extdir" 2>/dev/null

    # 复制 tor 二进制
    local tor_bin=$(find "$extdir" -name "tor" -o -name "tor.exe" 2>/dev/null | grep -v "\.txt" | head -1)
    if [ -n "$tor_bin" ]; then
        cp "$tor_bin" "$dest_dir/"
        chmod +x "$dest_dir/$(basename "$tor_bin")"
        log "  ✓ tor -> $dest_dir/"
    else
        err "  tor binary not found in archive"
    fi

    # 复制 obfs4proxy (如果存在)
    local obfs4_bin=$(find "$extdir" -name "obfs4proxy" -o -name "obfs4proxy.exe" 2>/dev/null | head -1)
    if [ -n "$obfs4_bin" ]; then
        cp "$obfs4_bin" "$dest_dir/"
        chmod +x "$dest_dir/$(basename "$obfs4_bin")" 2>/dev/null
        log "  ✓ obfs4proxy -> $dest_dir/"
    fi

    # 复制 snowflake-client (如果存在)
    local sf_bin=$(find "$extdir" -name "snowflake-client" -o -name "snowflake-client.exe" 2>/dev/null | head -1)
    if [ -n "$sf_bin" ]; then
        cp "$sf_bin" "$dest_dir/"
        chmod +x "$dest_dir/$(basename "$sf_bin")" 2>/dev/null
        log "  ✓ snowflake-client -> $dest_dir/"
    fi

    rm -rf "$extdir" "$tmpfile"
    log "  Done: $desc"
    echo ""
}

echo "========================================="
echo "  Tor Binary Downloader"
echo "  Version: $VERSION"
echo "========================================="
echo ""

# macOS x86_64
download_and_extract \
    "${BASE_URL}/tor-expert-bundle-macos-x86_64-${VERSION}.tar.gz" \
    "bin/macos-x86_64" \
    "macOS x86_64 (Intel)"

# macOS aarch64
download_and_extract \
    "${BASE_URL}/tor-expert-bundle-macos-aarch64-${VERSION}.tar.gz" \
    "bin/macos-aarch64" \
    "macOS aarch64 (Apple Silicon)"

# Windows x86_64
download_and_extract \
    "${BASE_URL}/tor-expert-bundle-windows-x86_64-${VERSION}.tar.gz" \
    "bin/windows-x86_64" \
    "Windows x86_64"

# Linux x86_64 (补充，如果根目录的 tor 缺失)
if [ ! -f "bin/linux-x86_64/tor" ]; then
    download_and_extract \
        "${BASE_URL}/tor-expert-bundle-linux-x86_64-${VERSION}.tar.gz" \
        "bin/linux-x86_64" \
        "Linux x86_64"
fi

echo "========================================="
echo "  Download Complete!"
echo "========================================="
echo ""
echo "Platform binaries:"
for d in bin/*/; do
    [ "$d" = "bin/current/" ] && continue
    echo "  $d:"
    ls "$d" | grep -v "^$" | while read f; do
        echo "    $f ($(du -sh "$d$f" 2>/dev/null | awk '{print $1}'))"
    done
done
echo ""
echo "Next steps:"
echo "  git add bin/"
echo "  git commit -m 'add: Tor binaries for all platforms'"
echo "  git push"
