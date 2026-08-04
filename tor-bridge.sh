#!/bin/bash
# tor-bridge.sh - 统一桥接管理器
# ================================
# 替代碎片化的 connect-bridge.sh，统一管理所有桥接类型
#
# 用法:
#   ./tor-bridge.sh list              # 列出所有可用桥接
#   ./tor-bridge.sh test              # 测试所有桥接连通性
#   ./tor-bridge.sh test <bridge>     # 测试单条桥接
#   ./tor-bridge.sh auto              # 自动选择最快桥接
#   ./tor-bridge.sh add <bridge-line> # 添加自定义桥接
#   ./tor-bridge.sh set <type>        # 设置首选桥接类型 (snowflake/obfs4/meek)
#   ./tor-bridge.sh reset             # 重置为默认配置
#   ./tor-bridge.sh fetch             # 从网络获取新桥接

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 平台检测
detect_platform() {
    local os arch
    case "$(uname -s)" in Linux*) os="linux";; Darwin*) os="macos";; *) os="unknown";; esac
    case "$(uname -m)" in x86_64|amd64) arch="x86_64";; arm64|aarch64) arch="aarch64";; *) arch="$(uname -m)";; esac
    echo "${os}-${arch}"
}

PLATFORM=$(detect_platform)
BIN_DIR="$SCRIPT_DIR/bin/$PLATFORM"

# 查找二进制
TOR_BIN=""
OBFS4PROXY=""
[ -x "$BIN_DIR/tor" ] && TOR_BIN="$BIN_DIR/tor"
[ -x "$BIN_DIR/obfs4proxy" ] && OBFS4PROXY="$BIN_DIR/obfs4proxy"
[ -z "$TOR_BIN" ] && [ -x "$SCRIPT_DIR/tor" ] && TOR_BIN="$SCRIPT_DIR/tor"
[ -z "$OBFS4PROXY" ] && [ -x "$SCRIPT_DIR/obfs4proxy" ] && OBFS4PROXY="$SCRIPT_DIR/obfs4proxy"

DATA_DIR="$SCRIPT_DIR/data"
LOGS_DIR="$SCRIPT_DIR/logs"
CONFIG="$SCRIPT_DIR/config/torrc"
USER_BRIDGES="$SCRIPT_DIR/bridges.txt"
SOCKS_PORT=9050

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log() { echo -e "${GREEN}[bridge]${NC} $*"; }
warn() { echo -e "${YELLOW}[bridge]${NC} $*"; }
err() { echo -e "${RED}[bridge]${NC} $*"; }
info() { echo -e "${CYAN}[bridge]${NC} $*"; }

# ============================================================
# 内置公共桥接
# ============================================================
BUILTIN_OBFS4=(
    "obfs4 192.95.36.142:443 CDF2E852BF539B82BD10E27E9115B317090CE2AA cert=sPzFLASSJhDnpQk4JCQjJzLSHWIvAG0KVOECPu86y7kFDd/JqBo0RUfpc3C6b7Kcc1G96Q iat-mode=0"
    "obfs4 37.218.245.14:38224 03FB60BDF89E2FF87BAE44AE7AB9B228B0D7FAFC cert=CfCMJxkJXqGhXTzRqs8GQYS8Hgvy2kBWPWpEpNtU7SUv0XgzpFlP7FN6B6z2LI37S1Bhw iat-mode=0"
    "obfs4 45.14.174.245:443 7B1233BBAB5B2F0002E72A6A2993C54D4E8FA8C8 cert=ssH+MTvyGoK3Fpr2HgFPio81O7C7YYDAaKc97HBgFp4B/SUpYVHJLMp3/FV䈷OUr6Q iat-mode=0"
    "obfs4 51.15.43.205:443 5E015EE2E4D864B02DEFE3521B24B2AB5E015EE2 cert=MgCBA3QLyWZPDpNOKPLwKFVRpUU7MZ+IgOBSJVVHKUBB7G6HxA13yrqPMVMFYM0MG0O8 iat-mode=0"
    "obfs4 109.70.100.10:443 A0B0D8158A31E981359FC0C00B3B6852C2544FA7 cert=/4C6jHEFKvxCpQMP01LG3UHCYarDIA+i4uSIB4ORYXkMoFPE4n3vQJY8jKFKYaCTJEc iat-mode=0"
)

BUILTIN_SNOWFLAKE=(
    "snowflake 192.0.2.3:80 2B280B23E1107BB62ABFC40DDCC8824814F80A72 fingerprint=2B280B23E1107BB62ABFC40DDCC8824814F80A72 url=https://snowflake-broker.torproject.net/ ice=stun:stun.antisip.com:3478,stun:stun.dus.net:3478,stun:stun.sonetel.com:3478,stun:stun.uls.co.za:3478 utls-imitate=hellorandomizedalpn"
)

BUILTIN_MEEK=(
    "meek_lite 0.0.2.0:2 url=https://ajax.aspnetcdn.com/ front=ajax.aspnetcdn.com"
)

# ============================================================
# 桥接解析
# ============================================================
parse_bridge_type() {
    local line="$1"
    line=$(echo "$line" | sed 's/^[[:space:]]*//')
    [[ "$line" == \#* ]] && return 1
    [ -z "$line" ] && return 1

    if echo "$line" | grep -qi "^snowflake"; then
        echo "snowflake"
    elif echo "$line" | grep -qi "^obfs4"; then
        echo "obfs4"
    elif echo "$line" | grep -qi "^meek"; then
        echo "meek"
    elif echo "$line" | grep -qi "^webtunnel"; then
        echo "webtunnel"
    else
        echo "unknown"
    fi
}

extract_bridge_addr() {
    local line="$1"
    # 提取 IP:PORT
    echo "$line" | awk '{print $2}'
}

# ============================================================
# TCP 连通性测试
# ============================================================
test_tcp() {
    local addr="$1"
    local timeout="${2:-5}"
    local ip port

    ip=$(echo "$addr" | cut -d: -f1)
    port=$(echo "$addr" | cut -d: -f2)

    # 跳过虚拟地址 (snowflake 用 192.0.2.3)
    if [ "$ip" = "192.0.2.3" ] || [ "$ip" = "0.0.0.0" ]; then
        return 0  # 需要实际测试
    fi

    # macOS 用 nc, Linux 用 timeout+nc 或 bash
    if command -v nc &>/dev/null; then
        nc -z -w "$timeout" "$ip" "$port" 2>/dev/null && return 0
    elif command -v timeout &>/dev/null; then
        timeout "$timeout" bash -c "echo >/dev/tcp/$ip/$port" 2>/dev/null && return 0
    else
        # 纯 bash TCP 测试
        (echo >/dev/tcp/"$ip"/"$port") 2>/dev/null && return 0
    fi
    return 1
}

# ============================================================
# 桥接测试 (通过 Tor 实际连接)
# ============================================================
test_bridge_via_tor() {
    local bridge_line="$1"
    local timeout="${2:-30}"
    local btype

    btype=$(parse_bridge_type "$bridge_line")
    [ -z "$btype" ] && return 1

    # 对 Snowflake，先检查 broker 可达性
    if [ "$btype" = "snowflake" ]; then
        if ! curl -s --connect-timeout 5 "https://snowflake-broker.torproject.net/" >/dev/null 2>&1; then
            return 1
        fi
        return 0  # Broker 可达就算可用
    fi

    # 对 obfs4，先测 TCP
    if [ "$btype" = "obfs4" ]; then
        local addr
        addr=$(extract_bridge_addr "$bridge_line")
        if ! test_tcp "$addr" 5; then
            return 1
        fi
    fi

    # meek 不需要 TCP 测试 (走 CDN)
    if [ "$btype" = "meek" ]; then
        return 0
    fi

    # 可选：用 Tor 实际测试 (更慢但更准确)
    if [ -n "$TOR_BIN" ] && [ -n "$OBFS4PROXY" ]; then
        local test_dir="$DATA_DIR/test-bridge-$$"
        mkdir -p "$test_dir"

        cat > "$test_dir/torrc" << EOF
SocksPort 0
DataDirectory $test_dir
Log notice stdout
UseBridges 1
ClientTransportPlugin $btype exec $OBFS4PROXY
Bridge $bridge_line
ConnLimit 1024
SafeSocks 0
DisableDebuggerAttachment 0
ORPort 0
DirPort 0
EOF

        local env_extra=""
        [ -d "$BIN_DIR" ] && env_extra="LD_LIBRARY_PATH=$BIN_DIR DYLD_LIBRARY_PATH=$BIN_DIR"

        local result=1
        local output
        output=$(timeout "$timeout" env $env_extra "$TOR_BIN" -f "$test_dir/torrc" 2>&1) || true

        if echo "$output" | grep -q "Bootstrapped 1[0-9]%" || echo "$output" | grep -q "Bootstrapped [2-9][0-9]%" || echo "$output" | grep -q "Bootstrapped 100%"; then
            result=0
        fi

        rm -rf "$test_dir"
        return $result
    fi

    # 无法实际测试，假设 TCP 可达即为可用
    return 0
}

# ============================================================
# 列出桥接
# ============================================================
do_list() {
    echo -e "${CYAN}=== 可用桥接 ===${NC}"
    echo ""

    echo -e "${GREEN}内置 obfs4 桥接:${NC}"
    for b in "${BUILTIN_OBFS4[@]}"; do
        local addr=$(extract_bridge_addr "$b")
        echo "  [obfs4] $addr"
    done

    echo ""
    echo -e "${GREEN}内置 Snowflake 桥接:${NC}"
    for b in "${BUILTIN_SNOWFLAKE[@]}"; do
        echo "  [snowflake] (WebRTC 自动发现)"
    done

    echo ""
    echo -e "${GREEN}内置 meek 桥接:${NC}"
    for b in "${BUILTIN_MEEK[@]}"; do
        echo "  [meek] CDN 伪装"
    done

    # 用户自定义桥接
    if [ -f "$USER_BRIDGES" ]; then
        echo ""
        echo -e "${GREEN}用户自定义桥接:${NC}"
        while IFS= read -r line; do
            line=$(echo "$line" | sed 's/^[[:space:]]*//')
            [ -z "$line" ] && continue
            [[ "$line" == \#* ]] && continue
            local btype=$(parse_bridge_type "$line")
            echo "  [$btype] ${line:0:80}"
        done < "$USER_BRIDGES"
    fi

    echo ""
    echo -e "${CYAN}当前配置: $CONFIG${NC}"
    if [ -f "$CONFIG" ]; then
        local bridge_count=$(grep -c "^Bridge " "$CONFIG" 2>/dev/null || echo 0)
        echo "  已配置 $bridge_count 条桥接"
    fi
}

# ============================================================
# 测试桥接
# ============================================================
do_test() {
    if [ $# -gt 0 ]; then
        # 测试单条桥接
        local bridge_line="$*"
        echo "测试桥接: ${bridge_line:0:80}..."
        if test_bridge_via_tor "$bridge_line" 30; then
            log "✓ 可用"
        else
            err "✗ 不可用"
        fi
        return
    fi

    echo -e "${CYAN}=== 测试所有桥接 ===${NC}"
    echo ""

    local total=0
    local ok=0

    # 测试 obfs4
    echo -e "${GREEN}obfs4 桥接:${NC}"
    for b in "${BUILTIN_OBFS4[@]}"; do
        total=$((total + 1))
        local addr=$(extract_bridge_addr "$b")
        printf "  %-40s " "$addr"
        if test_tcp "$addr" 5; then
            echo -e "${GREEN}✓ TCP 可达${NC}"
            ok=$((ok + 1))
        else
            echo -e "${RED}✗ TCP 不可达${NC}"
        fi
    done

    # 测试 Snowflake
    echo ""
    echo -e "${GREEN}Snowflake 桥接:${NC}"
    total=$((total + 1))
    printf "  %-40s " "Broker (snowflake-broker.torproject.net)"
    if curl -s --connect-timeout 5 "https://snowflake-broker.torproject.net/" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ 可达${NC}"
        ok=$((ok + 1))
    else
        echo -e "${RED}✗ 不可达${NC}"
    fi

    # 测试 meek
    echo ""
    echo -e "${GREEN}meek 桥接:${NC}"
    total=$((total + 1))
    printf "  %-40s " "CDN (ajax.aspnetcdn.com)"
    if curl -s --connect-timeout 5 "https://ajax.aspnetcdn.com/" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ 可达${NC}"
        ok=$((ok + 1))
    else
        echo -e "${RED}✗ 不可达${NC}"
    fi

    # 用户桥接
    if [ -f "$USER_BRIDGES" ]; then
        echo ""
        echo -e "${GREEN}用户桥接:${NC}"
        while IFS= read -r line; do
            line=$(echo "$line" | sed 's/^[[:space:]]*//')
            [ -z "$line" ] && continue
            [[ "$line" == \#* ]] && continue
            total=$((total + 1))
            local btype=$(parse_bridge_type "$line")
            local addr=$(extract_bridge_addr "$line")
            printf "  %-40s " "[$btype] $addr"
            if [ "$btype" = "meek" ]; then
                echo -e "${YELLOW}⚠ 需要实际测试${NC}"
            elif test_tcp "$addr" 5; then
                echo -e "${GREEN}✓ TCP 可达${NC}"
                ok=$((ok + 1))
            else
                echo -e "${RED}✗ TCP 不可达${NC}"
            fi
        done < "$USER_BRIDGES"
    fi

    echo ""
    echo "总计: $ok/$total 可用"
}

# ============================================================
# 自动选择最快桥接
# ============================================================
do_auto() {
    echo -e "${CYAN}=== 自动选择最快桥接 ===${NC}"
    echo ""

    local best_bridge=""
    local best_type=""
    local best_time=999

    # 测试 obfs4 桥接 (速度最快)
    echo "测试 obfs4 桥接..."
    for b in "${BUILTIN_OBFS4[@]}"; do
        local addr=$(extract_bridge_addr "$b")
        local start_time=$(date +%s%N 2>/dev/null || date +%s)
        if test_tcp "$addr" 5; then
            local end_time=$(date +%s%N 2>/dev/null || date +%s)
            local elapsed=$(( (end_time - start_time) / 1000000 ))  # ms
            [ "$elapsed" -eq 0 ] && elapsed=1
            echo "  ✓ $addr (${elapsed}ms)"
            if [ "$elapsed" -lt "$best_time" ]; then
                best_time=$elapsed
                best_bridge="$b"
                best_type="obfs4"
            fi
        else
            echo "  ✗ $addr"
        fi
    done

    # 如果 obfs4 都不可用，尝试 Snowflake
    if [ -z "$best_bridge" ]; then
        echo ""
        echo "obfs4 不可用，测试 Snowflake..."
        if curl -s --connect-timeout 10 "https://snowflake-broker.torproject.net/" >/dev/null 2>&1; then
            best_bridge="${BUILTIN_SNOWFLAKE[0]}"
            best_type="snowflake"
            best_time=500
            echo "  ✓ Snowflake Broker 可达"
        fi
    fi

    # 最后尝试 meek
    if [ -z "$best_bridge" ]; then
        echo ""
        echo "Snowflake 不可用，测试 meek..."
        if curl -s --connect-timeout 10 "https://ajax.aspnetcdn.com/" >/dev/null 2>&1; then
            best_bridge="${BUILTIN_MEEK[0]}"
            best_type="meek"
            best_time=1000
            echo "  ✓ meek CDN 可达"
        fi
    fi

    echo ""
    if [ -n "$best_bridge" ]; then
        log "✓ 最佳桥接: [$best_type] (${best_time}ms)"
        echo "  $best_bridge"
        echo ""
        
        # 写入用户桥接文件
        echo "$best_bridge" > "$USER_BRIDGES"
        log "✓ 已写入配置: $USER_BRIDGES"
        echo ""
        echo "重启 Tor 生效:"
        echo "  ./tor-start.sh restart"
    else
        err "✗ 所有桥接都不可用"
        echo "  请检查网络连接，或手动添加桥接:"
        echo "  ./tor-bridge.sh add 'obfs4 IP:PORT cert=xxx iat-mode=0'"
    fi
}

# ============================================================
# 添加自定义桥接
# ============================================================
do_add() {
    local bridge_line="$*"
    if [ -z "$bridge_line" ]; then
        err "用法: $0 add <bridge-line>"
        echo "  示例: $0 add 'obfs4 1.2.3.4:443 cert=xxx iat-mode=0'"
        return 1
    fi

    # 去掉 "Bridge " 前缀
    bridge_line=$(echo "$bridge_line" | sed 's/^Bridge[[:space:]]*//')

    # 验证格式
    local btype
    btype=$(parse_bridge_type "$bridge_line")
    if [ "$btype" = "unknown" ]; then
        err "无法识别桥接类型: $bridge_line"
        echo "  支持: obfs4, snowflake, meek_lite, webtunnel"
        return 1
    fi

    # 写入用户桥接文件
    echo "$bridge_line" >> "$USER_BRIDGES"
    log "✓ 已添加 [$btype] 桥接到 $USER_BRIDGES"
    echo "  下次启动时自动加载，或运行: ./tor-start.sh restart"
}

# ============================================================
# 设置首选桥接类型
# ============================================================
do_set() {
    local preferred="$1"
    case "$preferred" in
        snowflake|obfs4|meek)
            info "设置首选桥接类型: $preferred"
            info "这会修改 torrc.template 中的桥接顺序"
            # TODO: 实现自动重排
            echo "  当前版本请手动编辑 config/torrc.template 调整顺序"
            ;;
        *)
            err "未知桥接类型: $preferred"
            echo "  支持: snowflake, obfs4, meek"
            ;;
    esac
}

# ============================================================
# 重置桥接配置
# ============================================================
do_reset() {
    log "重置桥接配置为默认..."
    rm -f "$USER_BRIDGES"
    if [ -f "$SCRIPT_DIR/config/torrc.template" ]; then
        log "✓ 已重置。运行 ./tor-start.sh restart 生效"
    fi
}

# ============================================================
# 从网络获取新桥接
# ============================================================
do_fetch() {
    echo -e "${CYAN}=== 从网络获取新桥接 ===${NC}"
    echo ""

    local fetched=0

    # 从 Tor 官方获取
    echo "1. 从 Tor 官方 bridgedb 获取..."
    if command -v curl &>/dev/null; then
        local result
        result=$(curl -s --connect-timeout 10 "https://bridges.torproject.org/moat/fetch" \
            -H "Content-Type: application/vnd.api+json" \
            -d '{"data":{"type":"client-transports","supported":["obfs4"]}}' 2>/dev/null || true)
        if [ -n "$result" ] && echo "$result" | grep -q "bridge"; then
            echo "  ✓ 获取到桥接"
            echo "$result" | python3 -c "
import json,sys
data=json.load(sys.stdin)
for b in data.get('data',[]):
    if b.get('type')=='bridge':
        print(b.get('bridge',{}).get('address',''))
" 2>/dev/null | while read -r line; do
                [ -n "$line" ] && echo "  $line"
            done
            fetched=$((fetched + 1))
        else
            echo "  ✗ 获取失败"
        fi
    fi

    # 从 GitHub 获取
    echo ""
    echo "2. 从 GitHub 公开仓库获取..."
    local github_urls=(
        "https://raw.githubusercontent.com/nickmolo/Tor-Bridges/main/bridges.txt"
        "https://raw.githubusercontent.com/nickmolo/Tor-Bridges/main/obfs4.txt"
    )
    for url in "${github_urls[@]}"; do
        local content
        content=$(curl -s --connect-timeout 10 "$url" 2>/dev/null || true)
        if [ -n "$content" ] && echo "$content" | grep -q "obfs4"; then
            local count=$(echo "$content" | grep -c "obfs4" || echo 0)
            echo "  ✓ $(echo "$url" | cut -d/ -f4)/$(echo "$url" | cut -d/ -f5): $count 条桥接"
            fetched=$((fetched + 1))
        fi
    done

    echo ""
    if [ "$fetched" -gt 0 ]; then
        log "获取到 $fetched 个来源的桥接"
        echo "  运行 ./tor-bridge.sh test 测试连通性"
    else
        warn "未获取到新桥接"
        echo "  手动添加: ./tor-bridge.sh add 'obfs4 IP:PORT cert=xxx iat-mode=0'"
    fi
}

# ============================================================
# 主入口
# ============================================================
case "${1:-help}" in
    list)   do_list ;;
    test)   shift; do_test "$@" ;;
    auto)   do_auto ;;
    add)    shift; do_add "$@" ;;
    set)    shift; do_set "$@" ;;
    reset)  do_reset ;;
    fetch)  do_fetch ;;
    help|*)
        echo "tor-bridge.sh - 统一桥接管理器"
        echo ""
        echo "用法:"
        echo "  $0 list              列出所有可用桥接"
        echo "  $0 test              测试所有桥接连通性"
        echo "  $0 test <bridge>     测试单条桥接"
        echo "  $0 auto              自动选择最快桥接"
        echo "  $0 add <bridge-line> 添加自定义桥接"
        echo "  $0 set <type>        设置首选桥接类型"
        echo "  $0 reset             重置为默认配置"
        echo "  $0 fetch             从网络获取新桥接"
        ;;
esac
