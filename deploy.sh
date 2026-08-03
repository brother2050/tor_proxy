#!/bin/bash
# deploy.sh - 打包项目用于分发
# ==============================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Packaging tor-proxy..."

# 清理
rm -rf data/* logs/* 2>/dev/null

# 打包 (排除构建缓存)
tar czf ../tor-proxy.tar.gz \
    --exclude='.git' \
    --exclude='.go-install' \
    --exclude='deps/go-sdk' \
    --exclude='deps/go1.22.5.*' \
    --exclude='deps/gopath' \
    --exclude='data/*' \
    --exclude='logs/*' \
    --exclude='*.tar.gz' \
    --transform 's,^,tor-proxy/,' \
    .

echo "✓ Created tor-proxy.tar.gz"
echo ""
echo "Deploy:"
echo "  tar xzf tor-proxy.tar.gz"
echo "  cd tor-proxy"
echo "  bash setup.sh        # 下载当前平台 Tor"
echo "  ./tor-start.sh start  # 启动"
