#!/bin/bash
# connect-bridge.sh - 通过桥接连接 Tor (已废弃，请使用 tor-bridge.sh)
# ==================================================================
# 此脚本保留向后兼容，推荐使用:
#   ./tor-bridge.sh add <bridge-line>   # 添加桥接
#   ./tor-start.sh start                # 启动
#
# 用法: ./connect-bridge.sh <bridge-line>
# 示例: ./connect-bridge.sh "obfs4 1.2.3.4:12345 cert=xxx iat-mode=0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# 查找 obfs4proxy
OBFS4_BIN=""
if [ -f "$SCRIPT_DIR/obfs4proxy" ]; then
    OBFS4_BIN="$SCRIPT_DIR/obfs4proxy"
elif command -v obfs4proxy &>/dev/null; then
    OBFS4_BIN="$(command -v obfs4proxy)"
else
    echo "ERROR: obfs4proxy not found!"
    echo "  Place it in: $SCRIPT_DIR/obfs4proxy"
    exit 1
fi

# 判断桥接类型
BRIDGE_TYPE="obfs4"
echo "$BRIDGE_LINE" | grep -q "^snowflake" && BRIDGE_TYPE="snowflake"
echo "$BRIDGE_LINE" | grep -q "^meek" && BRIDGE_TYPE="meek_lite"
echo "$BRIDGE_LINE" | grep -q "^webtunnel" && BRIDGE_TYPE="webtunnel"

# 生成配置
mkdir -p "$SCRIPT_DIR/data" "$SCRIPT_DIR/logs"
CONFIG="$SCRIPT_DIR/config/torrc-bridge"

cat > "$CONFIG" << EOF
SocksPort 9050
DataDirectory $SCRIPT_DIR/data
Log notice file $SCRIPT_DIR/logs/tor.log

UseBridges 1
Bridge $BRIDGE_LINE
ClientTransportPlugin $BRIDGE_TYPE exec $OBFS4_BIN

ConnLimit 1024
SafeSocks 0
TestSocks 0
DisableDebuggerAttachment 0
ORPort 0
DirPort 0
EOF

echo "Starting Tor with bridge..."
echo "  Type: $BRIDGE_TYPE"
echo "  Bridge: $BRIDGE_LINE"
echo "  SOCKS proxy: 127.0.0.1:9050"
echo ""

rm -f "$SCRIPT_DIR/data/lock" "$SCRIPT_DIR/data/pid" 2>/dev/null
exec "$TOR_BIN" -f "$CONFIG"
