#!/bin/bash
# connect-bridge.sh - 通过桥接连接 Tor
# =====================================
# 使用你部署的桥接服务器连接 Tor
#
# 用法: ./connect-bridge.sh <bridge-line>
# 示例: ./connect-bridge.sh "obfs4 1.2.3.4:12345 cert=xxx iat-mode=0"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOR_BIN="$SCRIPT_DIR/tor"
export LD_LIBRARY_PATH="$SCRIPT_DIR"

BRIDGE_LINE="$1"

if [ -z "$BRIDGE_LINE" ]; then
    echo "Usage: $0 <bridge-line>"
    echo ""
    echo "Get a bridge line from:"
    echo "  1. Your own VPS (run setup-bridge.sh)"
    echo "  2. https://bridges.torproject.org/"
    echo "  3. Email bridges@torproject.org"
    echo ""
    echo "Example:"
    echo "  $0 'obfs4 1.2.3.4:12345 cert=abc123 iat-mode=0'"
    exit 1
fi

# Check for obfs4proxy
if ! command -v obfs4proxy &>/dev/null && [ ! -f "$SCRIPT_DIR/obfs4proxy" ]; then
    echo "ERROR: obfs4proxy not found!"
    echo ""
    echo "Install it:"
    echo "  # From package manager:"
    echo "  sudo apt install obfs4proxy"
    echo ""
    echo "  # Or download binary:"
    echo "  curl -LO https://github.com/nickmolo/obfs4proxy/releases/latest/download/obfs4proxy-linux-amd64"
    echo "  chmod +x obfs4proxy-linux-amd64"
    echo "  mv obfs4proxy-linux-amd64 $SCRIPT_DIR/obfs4proxy"
    exit 1
fi

OBFS4_BIN=$(command -v obfs4proxy || echo "$SCRIPT_DIR/obfs4proxy")

# Create torrc with bridge
mkdir -p "$SCRIPT_DIR/data" "$SCRIPT_DIR/logs"

cat > "$SCRIPT_DIR/config/torrc-bridge" << EOF
SocksPort 9050
DataDirectory $SCRIPT_DIR/data
Log notice file $SCRIPT_DIR/logs/tor.log

UseBridges 1
Bridge $BRIDGE_LINE
ClientTransportPlugin obfs4 exec $OBFS4_BIN

ConnLimit 1024
SafeSocks 0
TestSocks 0
FetchDirInfoEarly 0
FetchDirInfoExtraEarly 0
DisableDebuggerAttachment 0
ORPort 0
DirPort 0
EOF

echo "Starting Tor with bridge..."
echo "  Bridge: $BRIDGE_LINE"
echo "  SOCKS proxy: 127.0.0.1:9050"
echo ""

# Clean old data
rm -f "$SCRIPT_DIR/data/lock" "$SCRIPT_DIR/data/pid" 2>/dev/null

# Start Tor
exec "$TOR_BIN" -f "$SCRIPT_DIR/config/torrc-bridge"
