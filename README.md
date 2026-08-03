# Tor Proxy - 跨平台 Tor 代理工具包

通过 **Snowflake** (WebRTC CDN 隧道) 连接 Tor 网络。**预缓存 19,888 条中继描述符，首次启动仅需 ~45 秒。**

## 支持平台

| 平台 | 架构 | tor | obfs4proxy |
|------|------|-----|-----------|
| Linux | x86_64 | ✅ 内置 | ✅ 内置 |
| macOS | x86_64 (Intel) | ✅ 内置 | ✅ 内置 |
| macOS | aarch64 (M1/M2/M3) | ✅ 内置 | ✅ 内置 |
| Windows | x86_64 | ✅ 内置 | ✅ 内置 |

## 快速开始

### Linux / macOS

```bash
git clone https://ghfast.top/https://github.com/brother2050/tor_proxy.git
cd tor_proxy

# 启动 (自动检测平台，使用对应二进制)
./tor-start.sh start

# 使用代理
curl --socks5-hostname 127.0.0.1:9050 https://www.google.com
export ALL_PROXY=socks5h://127.0.0.1:9050
```

### Windows (PowerShell)

```powershell
git clone https://ghfast.top/https://github.com/brother2050/tor_proxy.git
cd tor_proxy

# 启动
.\tor-start.ps1 start
```

Windows 浏览器：Firefox → 设置 → 网络 → SOCKS 代理 `127.0.0.1:9050`

## 管理命令

### Linux / macOS
```bash
./tor-start.sh start     # 启动
./tor-start.sh stop      # 停止
./tor-start.sh restart   # 重启
./tor-start.sh status    # 状态
./tor-start.sh fresh     # 清除缓存并启动
./tor-start.sh refresh   # 刷新描述符缓存
```

### Windows
```powershell
.\tor-start.ps1 start     # 启动
.\tor-start.ps1 stop      # 停止
.\tor-start.ps1 status    # 状态
.\tor-start.ps1 fresh     # 清除缓存并启动
```

## 测试结果

```
  ✓ Google          10.9s  HTTP 200
  ✓ Wikipedia        2.9s  HTTP 301
  ✓ GitHub          40.0s  HTTP 200
  Exit IP: 192.42.116.94
```

## 工作原理

```
你的机器                Snowflake CDN            Tor 网络
  │                       │                       │
  ├─ Tor ──obfs4proxy─────┼── Cloudflare ─────────┼── Tor 中继
  │  (SOCKS5)  (WebRTC)   │  (CDN 隧道)           │  (出口)
  └─ curl/browser ────────┴───────────────────────┴── Google
```

## 项目结构

```
tor-proxy/
├── bin/                         # 所有平台二进制 (即开即用)
│   ├── linux-x86_64/           # tor + obfs4proxy + libevent
│   ├── macos-x86_64/           # tor + obfs4proxy (Intel)
│   ├── macos-aarch64/          # tor + obfs4proxy (Apple Silicon)
│   ├── windows-x86_64/         # tor.exe + obfs4proxy.exe
│   └── current -> linux-x86_64 # 当前平台符号链接
├── config/
│   └── torrc.template          # 配置模板
├── cache/
│   └── descriptors/            # 预缓存描述符 (46MB, 19888 relay)
├── src/
│   └── obfs4/                  # obfs4proxy 完整源码
├── deps/
│   └── go-sdk/                 # Go 1.22.5 SDK (重编译用)
├── tor-start.sh                # 启动脚本 (Linux/macOS)
├── tor-start.ps1               # 启动脚本 (Windows)
├── bridge-finder.py            # 桥接自动发现
├── tor-benchmark.py            # 速度基准测试
├── download-all.sh             # 一键下载所有平台 Tor
└── README.md
```

## 描述符缓存

预缓存 19,888 条中继描述符：
- 首次启动 ~45 秒 (使用缓存)
- 后续重启 ~30 秒 (复用缓存)
- 停止时自动保存，重启自动加载

## 桥接管理

```bash
# Snowflake (推荐 - 自动发现志愿者代理)
python3 bridge-finder.py --snowflake

# 搜索所有来源
python3 bridge-finder.py

# 测试桥接
python3 bridge-finder.py --test "obfs4 1.2.3.4:443 cert=xxx iat-mode=0"
```

## 浏览器配置

**Firefox:** 设置 → 网络设置 → SOCKS 主机: `127.0.0.1` 端口: `9050`

**Chrome:** `google-chrome --proxy-server="socks5://127.0.0.1:9050"`

## Python 使用

```python
import requests
proxies = {'http': 'socks5h://127.0.0.1:9050', 'https': 'socks5h://127.0.0.1:9050'}
r = requests.get('https://www.google.com', proxies=proxies)
```

## 更新二进制

```bash
# 下载最新版 Tor (所有平台)
bash download-all.sh

# 提交
git add bin/
git commit -m "update: Tor binaries"
git push
```

## 重新编译 obfs4proxy

```bash
# 当前平台
export GOROOT="$(pwd)/deps/go-sdk/go"
export PATH="$GOROOT/bin:$PATH"
cd src/obfs4 && go build -o ../../bin/$(../bin/current)/obfs4proxy ./cmd/lyrebird/
```

## 故障排除

```bash
./tor-start.sh status    # 查看平台和状态
tail -f logs/tor.log     # 查看日志
./tor-start.sh fresh     # 清除缓存重来
```
