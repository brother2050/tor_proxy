#!/bin/bash
# deploy.sh - Package tor-proxy for deployment
# Usage: bash deploy.sh
# Creates tor-proxy.tar.gz ready to deploy anywhere

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "Packaging tor-proxy..."

# Clean up
rm -rf data/* logs/* 2>/dev/null

# Create package
tar czf ../tor-proxy.tar.gz \
    tor \
    libevent-2.1.so.7 \
    libevent-2.1.so.7.0.1 \
    tor-proxy.sh \
    tor-proxy.py \
    tor-benchmark.py \
    config/torrc \
    README.md \
    --transform 's,^,tor-proxy/,'

echo "✓ Created tor-proxy.tar.gz"
echo ""
echo "Deploy on target machine:"
echo "  tar xzf tor-proxy.tar.gz"
echo "  cd tor-proxy"
echo "  ./tor-proxy.sh start"
echo "  ./tor-proxy.sh test"
