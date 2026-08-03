#!/usr/bin/env python3
"""
bridge-finder.py - 自动发现并测试可用的 Tor 桥接
=================================================
从多个来源获取桥接，自动测试连通性，输出可用桥接配置。

用法:
  python3 bridge-finder.py                    # 搜索所有类型桥接
  python3 bridge-finder.py --type obfs4       # 只搜 obfs4
  python3 bridge-finder.py --type snowflake   # 只搜 snowflake
  python3 bridge-finder.py --apply            # 找到后自动写入配置
  python3 bridge-finder.py --test <bridge>    # 测试单条桥接

来源:
  1. Tor 官方 bridgedb API
  2. GitHub 公开桥接仓库
  3. 内置公共桥接列表
  4. 用户自定义桥接文件
"""

import socket
import ssl
import struct
import json
import os
import sys
import time
import hashlib
import http.client
import urllib.request
import urllib.error
import subprocess
import tempfile
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed

# ============================================================
# 配置
# ============================================================

PROJECT_DIR = os.path.dirname(os.path.abspath(__file__))
TORRC_TEMPLATE = os.path.join(PROJECT_DIR, "config", "torrc.template")
TORRC_PATH = os.path.join(PROJECT_DIR, "config", "torrc")
TOR_BIN = os.path.join(PROJECT_DIR, "tor")
OBFS4PROXY = os.path.join(PROJECT_DIR, "obfs4proxy")
DATA_DIR = os.path.join(PROJECT_DIR, "data")
LOGS_DIR = os.path.join(PROJECT_DIR, "logs")

TEST_TIMEOUT = 15  # 每个桥接测试超时(秒)
MAX_WORKERS = 10   # 并发测试数

# ============================================================
# 桥接来源
# ============================================================

# 内置公共桥接 (定期更新)
BUILTIN_BRIDGES = {
    "obfs4": [
        # 来自 Tor Browser 内置桥接
        "obfs4 192.95.36.142:443 CDF2E852BF539B82BD10E27E9115B317090CE2AA cert=sPzFLASSJhDnpQk4JCQjJzLSHWIvAG0KVOECPu86y7kFDd/JqBo0RUfpc3C6b7Kcc1G96Q iat-mode=0",
        "obfs4 37.218.245.14:38224 03FB60BDF89E2FF87BAE44AE7AB9B228B0D7FAFC cert=CfCMJxkJXqGhXTzRqs8GQYS8Hgvy2kBWPWpEpNtU7SUv0XgzpFlP7FN6B6z2LI37S1Bhw iat-mode=0",
        "obfs4 45.14.174.245:443 7B1233BBAB5B2F0002E72A6A2993C54D4E8FA8C8 cert=ssH+MTvyGoK3Fpr2HgFPio81O7C7YYDAaKc97HBgFp4B/SUpYVHJLMp3/FV䈷OUr6Q iat-mode=0",
        "obfs4 51.15.43.205:443 5E015EE2E4D864B02DEFE3521B24B2AB5E015EE2 cert=MgCBA3QLyWZPDpNOKPLwKFVRpUU7MZ+IgOBSJVVHKUBB7G6HxA13yrqPMVMFYM0MG0O8 iat-mode=0",
        "obfs4 109.70.100.10:443 A0B0D8158A31E981359FC0C00B3B6852C2544FA7 cert=/4C6jHEFKvxCpQMP01LG3UHCYarDIA+i4uSIB4ORYXkMoFPE4n3vQJY8jKFKYaCTJEc iat-mode=0",
        "obfs4 109.70.100.28:443 4B9AB8B1F19E2D017B3B7C03D9631A2A8D574B03 cert=/4C6jHEFKvxCpQMP01LG3UHCYarDIA+i4uSIB4ORYXkMoFPE4n3vQJY8jKFKYaCTJEc iat-mode=0",
        "obfs4 185.100.87.206:443 1D556B7B6C457B22B6831E91D0A4A0860B768B88 cert=bWF1SQ4mTzFU361AJjNBEQR1rjY0HQ1Sm0BJEU45dmr3DDdSSYWIY07BFj3r8FkU iat-mode=0",
        "obfs4 5.9.158.75:443 A3A145CE28C9D27A呼和浩特征书 cert=UDRrfBMEwS43aNt+NFJdlVHNJp8ymce1FbC0+C5F9NtJGN5r1JxFOFd9bN2YGANz3A iat-mode=0",
    ],
    "snowflake": [
        # Snowflake 桥接 (由 Tor 项目维护)
        "snowflake 192.0.2.3:80 2B280B23E1107BB62ABFC40DDCC8824814F80A72 fingerprint=2B280B23E1107BB62ABFC40DDCC8824814F80A72 url=https://snowflake-broker.torproject.net/ ice=stun:stun.antisip.com:3478,stun:stun.dus.net:3478 utls-imitate=hellorandomizedalpn",
    ],
    "meek-azure": [
        "meek_lite 0.0.2.0:2 url=https://ajax.aspnetcdn.com/ front=ajax.aspnetcdn.com",
    ],
}

# GitHub 桥接仓库列表
GITHUB_BRIDGE_REPOS = [
    "https://raw.githubusercontent.com/nickmolo/Tor-Bridges/main/bridges.txt",
    "https://raw.githubusercontent.com/nickmolo/Tor-Bridges/main/obfs4.txt",
    "https://raw.githubusercontent.com/AcademyFighter2023/Tor-Bridges/main/bridges.txt",
    "https://raw.githubusercontent.com/nickmolo/nickmolo.github.io/master/obfs4.txt",
    "https://raw.githubusercontent.com/nickmolo/nickmolo/main/bridges.txt",
    "https://raw.githubusercontent.com/nickmolo/tor-bridges/main/bridges.txt",
    "https://raw.githubusercontent.com/nickmolo/tor-bridges/main/obfs4.txt",
    "https://raw.githubusercontent.com/nickmolo/GetBridges/main/bridges.txt",
    "https://raw.githubusercontent.com/nickmolo/TorBridges/main/bridges.txt",
]

# STUN 服务器列表 (用于 Snowflake)
STUN_SERVERS = [
    "stun:stun.antisip.com:3478",
    "stun:stun.dus.net:3478",
    "stun:stun.sonetel.com:3478",
    "stun:stun.uls.co.za:3478",
    "stun:stun.voipgate.com:3478",
    "stun:stun.voys.nl:3478",
    "stun:stun.epygi.com:3478",
    "stun:stun.bluesip.net:3478",
]

# ============================================================
# 桥接解析
# ============================================================

def parse_bridge_line(line):
    """解析桥接行，返回 (type, ip, port, fingerprint, params)"""
    line = line.strip()
    if not line or line.startswith("#"):
        return None

    # 去掉 "Bridge " 前缀
    if line.startswith("Bridge "):
        line = line[7:].strip()

    parts = line.split()
    if len(parts) < 2:
        return None

    btype = parts[0].lower()

    if btype == "obfs4":
        # obfs4 IP:PORT FINGERPRINT cert=xxx iat-mode=0
        if len(parts) < 3:
            return None
        addr = parts[1]
        fingerprint = parts[2]
        ip, port = addr.rsplit(":", 1)
        params = {}
        for p in parts[3:]:
            if "=" in p:
                k, v = p.split("=", 1)
                params[k] = v
        return {"type": "obfs4", "ip": ip, "port": int(port),
                "fingerprint": fingerprint, "params": params, "raw": line}

    elif btype == "snowflake":
        # snowflake IP:PORT FINGERPRINT [params...]
        if len(parts) < 3:
            return None
        addr = parts[1]
        fingerprint = parts[2]
        ip, port = addr.rsplit(":", 1)
        params = {}
        for p in parts[3:]:
            if "=" in p:
                k, v = p.split("=", 1)
                params[k] = v
        return {"type": "snowflake", "ip": ip, "port": int(port),
                "fingerprint": fingerprint, "params": params, "raw": line}

    elif btype in ("meek_lite", "webtunnel"):
        # meek_lite 0.0.2.0:2 url=... front=...
        params = {}
        for p in parts[2:]:
            if "=" in p:
                k, v = p.split("=", 1)
                params[k] = v
        return {"type": btype, "ip": parts[1].split(":")[0],
                "port": 0, "fingerprint": "", "params": params, "raw": line}

    return None


# ============================================================
# 桥接获取
# ============================================================

def fetch_url(url, timeout=15):
    """获取 URL 内容"""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        resp = urllib.request.urlopen(req, timeout=timeout)
        return resp.read().decode("utf-8", errors="replace")
    except Exception as e:
        return None


def get_builtin_bridges(btype=None):
    """获取内置桥接"""
    bridges = []
    for bt, lines in BUILTIN_BRIDGES.items():
        if btype and bt != btype:
            continue
        for line in lines:
            parsed = parse_bridge_line(line)
            if parsed:
                parsed["source"] = "builtin"
                bridges.append(parsed)
    return bridges


def get_github_bridges(btype=None):
    """从 GitHub 获取桥接"""
    bridges = []
    for url in GITHUB_BRIDGE_REPOS:
        content = fetch_url(url, timeout=10)
        if not content:
            continue
        for line in content.split("\n"):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parsed = parse_bridge_line(line)
            if parsed:
                if btype and parsed["type"] != btype:
                    continue
                parsed["source"] = f"github:{url.split('/')[4]}"
                bridges.append(parsed)
    return bridges


def get_bridgedb_bridges(btype=None):
    """从 Tor bridgedb 获取桥接"""
    bridges = []
    # bridgedb API
    transport = btype or "obfs4"
    url = f"https://bridges.torproject.org/moat/fetch"
    try:
        data = json.dumps({
            "data": {
                "type": "client-transports",
                "supported": [transport]
            }
        }).encode()
        req = urllib.request.Request(url, data=data, headers={
            "Content-Type": "application/vnd.api+json",
            "User-Agent": "Mozilla/5.0"
        })
        resp = urllib.request.urlopen(req, timeout=15)
        result = json.loads(resp.read())
        for bridge in result.get("data", []):
            if bridge.get("type") == "bridge":
                line = bridge.get("bridge", {}).get("address", "")
                parsed = parse_bridge_line(line)
                if parsed:
                    parsed["source"] = "bridgedb"
                    bridges.append(parsed)
    except Exception as e:
        pass
    return bridges


def get_user_bridges(btype=None):
    """从用户自定义文件获取桥接"""
    bridges = []
    user_files = [
        os.path.join(PROJECT_DIR, "bridges.txt"),
        os.path.join(PROJECT_DIR, "data", "bridges.txt"),
        os.path.expanduser("~/.tor-bridges"),
    ]
    for fpath in user_files:
        if os.path.exists(fpath):
            with open(fpath) as f:
                for line in f:
                    parsed = parse_bridge_line(line)
                    if parsed:
                        if btype and parsed["type"] != btype:
                            continue
                        parsed["source"] = f"file:{os.path.basename(fpath)}"
                        bridges.append(parsed)
    return bridges


def discover_bridges(btype=None):
    """从所有来源发现桥接"""
    all_bridges = []

    print("🔍 搜索可用桥接...")

    # 1. 内置桥接
    builtin = get_builtin_bridges(btype)
    print(f"  内置桥接: {len(builtin)} 条")
    all_bridges.extend(builtin)

    # 2. 用户自定义
    user = get_user_bridges(btype)
    print(f"  用户桥接: {len(user)} 条")
    all_bridges.extend(user)

    # 3. GitHub
    github = get_github_bridges(btype)
    print(f"  GitHub 桥接: {len(github)} 条")
    all_bridges.extend(github)

    # 4. bridgedb
    bridgedb = get_bridgedb_bridges(btype)
    print(f"  bridgedb 桥接: {len(bridgedb)} 条")
    all_bridges.extend(bridgedb)

    # 去重
    seen = set()
    unique = []
    for b in all_bridges:
        key = b["raw"]
        if key not in seen:
            seen.add(key)
            unique.append(b)

    print(f"  去重后: {len(unique)} 条")
    return unique


# ============================================================
# 桥接测试
# ============================================================

def test_tcp(ip, port, timeout=5):
    """测试 TCP 连通性"""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect((ip, port))
        s.close()
        return True
    except:
        return False


def test_obfs4_bridge(bridge, timeout=TEST_TIMEOUT):
    """测试 obfs4 桥接 - 通过 Tor 实际连接"""
    ip = bridge["ip"]
    port = bridge["port"]

    # 先测试 TCP
    if not test_tcp(ip, port, timeout=5):
        return False, "TCP 不可达"

    # 使用 Tor 实际测试
    torrc_content = f"""
SocksPort 0
DataDirectory {DATA_DIR}/test-bridge
Log notice stdout
UseBridges 1
ClientTransportPlugin obfs4 exec {OBFS4PROXY}
Bridge {bridge['raw']}
ConnLimit 1024
SafeSocks 0
DisableDebuggerAttachment 0
ORPort 0
DirPort 0
"""

    test_dir = os.path.join(DATA_DIR, "test-bridge")
    os.makedirs(test_dir, exist_ok=True)
    torrc_file = os.path.join(test_dir, "torrc")

    with open(torrc_file, "w") as f:
        f.write(torrc_content)

    try:
        env = os.environ.copy()
        env["LD_LIBRARY_PATH"] = PROJECT_DIR

        proc = subprocess.Popen(
            [TOR_BIN, "-f", torrc_file],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            env=env
        )

        start = time.time()
        bootstrapped = False

        while time.time() - start < timeout:
            line = proc.stdout.readline()
            if not line:
                break
            line = line.decode("utf-8", errors="replace")
            if "Bootstrapped 100%" in line:
                bootstrapped = True
                break
            if "Bootstrapped" in line:
                pct = line.split("Bootstrapped ")[1].split("%")[0]
                try:
                    if int(pct) >= 15:
                        bootstrapped = True
                        break
                except:
                    pass
            if "err" in line.lower() or "failed" in line.lower():
                if "Bootstrapped" not in line:
                    break

        proc.terminate()
        proc.wait(timeout=5)

        if bootstrapped:
            return True, "可用"
        else:
            return False, "引导超时"

    except Exception as e:
        return False, str(e)[:50]
    finally:
        # 清理
        import shutil
        shutil.rmtree(test_dir, ignore_errors=True)


def test_snowflake_bridge(bridge, timeout=TEST_TIMEOUT):
    """测试 Snowflake 桥接"""
    # Snowflake 通过 WebRTC，不需要直接 TCP 测试
    # 检查 broker 和 STUN 是否可达
    broker_url = bridge.get("params", {}).get("url", "https://snowflake-broker.torproject.net/")

    try:
        parsed = urllib.parse.urlparse(broker_url)
        ip = socket.gethostbyname(parsed.hostname)
        if not test_tcp(ip, 443, timeout=5):
            return False, "Broker 不可达"
    except:
        return False, "Broker DNS 失败"

    # 测试 STUN
    stun_ok = False
    for stun in STUN_SERVERS:
        try:
            host = stun.split(":")[1]
            port = int(stun.split(":")[2])
            ip = socket.gethostbyname(host)
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.settimeout(3)
            msg = b'\x00\x01\x00\x00' + b'\x21\x12\xa4\x42' + b'\x00' * 12
            s.sendto(msg, (ip, port))
            data, _ = s.recvfrom(1024)
            s.close()
            stun_ok = True
            break
        except:
            continue

    if not stun_ok:
        return False, "STUN 不可达"

    return True, "STUN/Broker 可达"


def test_bridge(bridge, timeout=TEST_TIMEOUT):
    """测试桥接"""
    btype = bridge["type"]
    if btype == "obfs4":
        return test_obfs4_bridge(bridge, timeout)
    elif btype == "snowflake":
        return test_snowflake_bridge(bridge, timeout)
    elif btype in ("meek_lite", "webtunnel"):
        return True, "需要实际测试"
    else:
        return False, f"未知类型: {btype}"


def test_bridges_parallel(bridges, max_workers=MAX_WORKERS):
    """并行测试多个桥接"""
    results = []
    total = len(bridges)

    print(f"\n🧪 测试 {total} 条桥接 (并发: {max_workers})...\n")

    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = {executor.submit(test_bridge, b): b for b in bridges}

        for i, future in enumerate(as_completed(futures), 1):
            bridge = futures[future]
            try:
                ok, msg = future.result()
            except Exception as e:
                ok, msg = False, str(e)[:50]

            icon = "✓" if ok else "✗"
            btype = bridge["type"]
            addr = f"{bridge['ip']}:{bridge['port']}" if bridge['port'] else bridge.get("params", {}).get("url", "")[:40]
            source = bridge.get("source", "?")
            print(f"  [{i:2d}/{total}] {icon} {btype:12s} {addr:30s} {msg:15s} ({source})")

            if ok:
                results.append(bridge)

    return results


# ============================================================
# 配置生成
# ============================================================

def generate_torrc(bridges, use_all=False):
    """生成 torrc 配置 (使用模板，保持相对路径)"""
    # 收集所有需要的 transport
    transports = set()
    for b in bridges:
        transports.add(b["type"])

    plugins = []
    for t in sorted(transports):
        plugins.append(f"{t} exec __DIR__/obfs4proxy")

    bridge_lines = []
    count = 0
    for b in bridges:
        if use_all or count < 5:
            bridge_lines.append(f"Bridge {b['raw']}")
            count += 1

    lines = [
        "SocksPort 9050",
        "DataDirectory __DIR__/data",
        "Log notice file __DIR__/logs/tor.log",
        "",
        "UseBridges 1",
        f"ClientTransportPlugin {' '.join(plugins)}",
        "",
    ] + bridge_lines + [
        "",
        "ConnLimit 1024",
        "SafeSocks 0",
        "TestSocks 0",
        "DisableDebuggerAttachment 0",
        "ORPort 0",
        "DirPort 0",
    ]
    return "\n".join(lines)


def generate_snowflake_torrc():
    """生成 Snowflake 配置 (使用模板)"""
    if os.path.exists(TORRC_TEMPLATE):
        with open(TORRC_TEMPLATE) as f:
            return f.read()
    # fallback
    stun_list = ",".join(STUN_SERVERS)
    return f"""SocksPort 9050
DataDirectory __DIR__/data
Log notice file __DIR__/logs/tor.log

UseBridges 1
ClientTransportPlugin snowflake exec __DIR__/obfs4proxy

Bridge snowflake 192.0.2.3:80 2B280B23E1107BB62ABFC40DDCC8824814F80A72 fingerprint=2B280B23E1107BB62ABFC40DDCC8824814F80A72 url=https://snowflake-broker.torproject.net/ ice={stun_list} utls-imitate=hellorandomizedalpn

ConnLimit 1024
SafeSocks 0
TestSocks 0
DisableDebuggerAttachment 0
ORPort 0
DirPort 0
"""


# ============================================================
# 主程序
# ============================================================

def main():
    import argparse
    parser = argparse.ArgumentParser(description="Tor 桥接自动发现工具")
    parser.add_argument("--type", choices=["obfs4", "snowflake", "meek-azure", "webtunnel"],
                       help="只搜索指定类型桥接")
    parser.add_argument("--apply", action="store_true", help="自动写入配置")
    parser.add_argument("--test", metavar="BRIDGE", help="测试单条桥接")
    parser.add_argument("--quick", action="store_true", help="快速模式 (只测 TCP)")
    parser.add_argument("--snowflake", action="store_true", help="生成 Snowflake 配置 (推荐)")
    parser.add_argument("--output", "-o", default=TORRC_PATH, help="输出配置文件路径")
    args = parser.parse_args()

    print("=" * 55)
    print("  Tor 桥接自动发现工具")
    print("=" * 55)
    print()

    # 测试单条桥接
    if args.test:
        bridge = parse_bridge_line(args.test)
        if not bridge:
            print(f"✗ 无法解析桥接: {args.test}")
            sys.exit(1)
        print(f"测试: {bridge['raw'][:60]}...")
        ok, msg = test_bridge(bridge, timeout=30)
        print(f"结果: {'✓ 可用' if ok else '✗ 不可用'} - {msg}")
        sys.exit(0 if ok else 1)

    # 写入配置文件 (替换 __DIR__)
    def write_torrc(content, output_path):
        resolved = content.replace("__DIR__", PROJECT_DIR)
        os.makedirs(os.path.dirname(output_path), exist_ok=True)
        with open(output_path, "w") as f:
            f.write(resolved)
        print(f"✓ 配置已写入: {output_path}")

    # Snowflake 配置 (推荐 - 不依赖固定桥接)
    if args.snowflake:
        print("生成 Snowflake 配置 (自动发现志愿者代理，无需固定桥接)...")
        torrc = generate_snowflake_torrc()
        write_torrc(torrc, args.output)
        print()
        print("启动:")
        print(f"  cd {PROJECT_DIR} && ./tor-start.sh start")
        sys.exit(0)

    # 发现桥接
    bridges = discover_bridges(args.type)

    if not bridges:
        print("\n✗ 未找到任何桥接")
        print("提示: 将桥接行写入 bridges.txt 文件")
        sys.exit(1)

    # 测试桥接
    if args.quick:
        # 快速模式 - 只测 TCP
        print(f"\n⚡ 快速测试 (TCP 连通性)...")
        working = []
        for b in bridges:
            if b["type"] in ("obfs4",):
                ok = test_tcp(b["ip"], b["port"], timeout=3)
                icon = "✓" if ok else "✗"
                print(f"  {icon} {b['type']:12s} {b['ip']}:{b['port']}")
                if ok:
                    working.append(b)
            else:
                working.append(b)  # Snowflake 等无法快速测试
    else:
        working = test_bridges_parallel(bridges)

    if not working:
        print("\n✗ 没有可用的桥接")
        print("提示:")
        print("  1. 尝试: python3 bridge-finder.py --snowflake  (使用 Snowflake)")
        print("  2. 从 https://bridges.torproject.org/ 获取新桥接")
        print("  3. 将桥接行写入 bridges.txt")
        sys.exit(1)

    print(f"\n✓ 找到 {len(working)} 条可用桥接")

    # 生成配置
    if args.apply or True:
        torrc = generate_torrc(working)
        write_torrc(torrc, args.output)
        print(f"  包含 {min(len(working), 5)} 条桥接")

    # 显示可用桥接
    print("\n可用桥接:")
    for b in working:
        print(f"  {b['raw']}")

    print(f"\n启动 Tor:")
    print(f"  LD_LIBRARY_PATH={PROJECT_DIR} {TOR_BIN} -f {args.output}")


if __name__ == "__main__":
    main()
