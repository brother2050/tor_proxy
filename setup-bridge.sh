#!/bin/bash
# setup-bridge.sh - 在有公网的 VPS 上部署 Tor 桥接
# ================================================
# 在你的 VPS (AWS/GCP/Azure/DigitalOcean) 上运行此脚本
# 部署后会生成桥接地址，用于受限环境连接
#
# 用法: curl -sSL <url>/setup-bridge.sh | bash
# 或:   bash setup-bridge.sh

set -e

echo "========================================"
echo "  Tor Bridge Setup Script"
echo "========================================"

# 检测系统
if [ -f /etc/debian_version ]; then
    PM="apt-get"
elif [ -f /etc/redhat-release ]; then
    PM="yum"
else
    echo "Unsupported OS. Install tor manually."
    exit 1
fi

# 安装 Tor
echo "[1/5] Installing Tor..."
if ! command -v tor &>/dev/null; then
    if [ "$PM" = "apt-get" ]; then
        # Add Tor repository for latest version
        apt-get update -qq
        apt-get install -y -qq gnupg2 curl
        curl -sSL https://deb.torproject.org/torproject.org/A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89.asc | gpg --dearmor > /usr/share/keyrings/tor-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/tor-archive-keyring.gpg] https://deb.torproject.org/torproject.org $(lsb_release -cs) main" > /etc/apt/sources.list.d/tor.list
        apt-get update -qq
        apt-get install -y -qq tor deb.torproject.org-keyring
    else
        yum install -y epel-release
        yum install -y tor
    fi
fi

echo "[2/5] Configuring Tor bridge..."

# 获取服务器公网 IP
PUBLIC_IP=$(curl -s4 https://api.ipify.org || curl -s4 https://ifconfig.me || hostname -I | awk '{print $1}')
echo "  Server IP: $PUBLIC_IP"

# 生成随机 ORPort (避免常见端口被封)
OR_PORT=$((RANDOM % 10000 + 40000))
PT_PORT=$((RANDOM % 10000 + 40000))

# 写入配置
cat > /etc/tor/torrc << EOF
# Tor Bridge Configuration
# Generated: $(date)

# 基本设置
BridgeRelay 1
SocksPort 0
ORPort ${OR_PORT}
ORPort 443 NoListen
ORPort ${PT_PORT} NoListen

# 服务器信息
Nickname tor-bridge-$(head -c4 /dev/urandom | xxd -p)
ContactInfo bridge-admin@$(hostname)
ExitPolicy reject *:*

# Pluggable Transport (obfs4)
ServerTransportPlugin obfs4 exec /usr/bin/obfs4proxy

# 性能优化
ConnLimit 1024
BandwidthRate 10 MBits
BandwidthBurst 20 MBits

# 日志
Log notice file /var/log/tor/notices.log
EOF

echo "[3/5] Installing obfs4proxy..."
if ! command -v obfs4proxy &>/dev/null; then
    if [ "$PM" = "apt-get" ]; then
        apt-get install -y -qq obfs4proxy
    else
        # Build from source
        if ! command -v go &>/dev/null; then
            echo "  Installing Go..."
            GO_VERSION="1.22.5"
            curl -sSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" | tar -C /usr/local -xzf -
            export PATH=$PATH:/usr/local/go/bin
        fi
        echo "  Building obfs4proxy..."
        GOPATH=/tmp/go go install gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/obfs4@latest
        cp /tmp/go/bin/obfs4 /usr/local/bin/obfs4proxy
    fi
fi

echo "[4/5] Starting Tor bridge..."
mkdir -p /var/log/tor
chown -R tor:tor /var/log/tor 2>/dev/null || true
systemctl enable tor
systemctl restart tor

# 等待启动
echo "  Waiting for Tor to start..."
for i in $(seq 1 30); do
    sleep 2
    if [ -f /var/lib/tor/pt_state/obfs4_bridgeline.txt ]; then
        echo "  ✓ Tor bridge started"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "  ✗ Timeout. Check: journalctl -u tor"
        exit 1
    fi
done

echo "[5/5] Getting bridge address..."

# 获取桥接信息
BRIDGE_LINE=$(cat /var/lib/tor/pt_state/obfs4_bridgeline.txt 2>/dev/null | grep "Bridge" | head -1)
FINGERPRINT=$(cat /var/lib/tor/fingerprint 2>/dev/null | awk '{print $2}')

echo ""
echo "========================================"
echo "  ✓ Tor Bridge Deployed!"
echo "========================================"
echo ""
echo "Bridge address (add this to torrc):"
echo ""
echo "  UseBridges 1"
echo "  ${BRIDGE_LINE/0.0.0.0/$PUBLIC_IP}"
echo ""
echo "Or use with Tor Browser:"
echo "  ${BRIDGE_LINE/0.0.0.0/$PUBLIC_IP}"
echo ""
echo "Fingerprint: $FINGERPRINT"
echo "ORPort: $OR_PORT"
echo "obfs4 Port: $PT_PORT"
echo ""
echo "Status: systemctl status tor"
echo "Logs:   tail -f /var/log/tor/notices.log"
echo ""

# 验证桥接运行
if systemctl is-active --quiet tor; then
    echo "✓ Tor bridge is running"
else
    echo "✗ Tor bridge failed to start"
    journalctl -u tor --no-pager -n 20
fi
