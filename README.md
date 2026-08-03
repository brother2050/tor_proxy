# Tor Proxy - 跨平台 Tor 代理工具包

通过 **Snowflake** (WebRTC CDN 隧道) 连接 Tor 网络。**预缓存 19,888 条中继描述符，首次启动仅需 ~45 秒。**

## 支持平台

| 平台 | 架构 | 状态 |
|------|------|------|
| Linux | x86_64 | ✅ 内置 |
| macOS | x86_64 (Intel) | ✅ 自动下载 |
| macOS | aarch64 (M1/M2/M3) | ✅ 自动下载 |

## 快速开始

```bash
git clone https://ghfast.top/https://github.com/brother2050/tor_proxy.git
cd tor_proxy

# 首次使用：下载当前平台的 Tor (自动检测)
bash setup.sh

# 启动
./tor-start.sh start

# 使用代理
curl --socks5-hostname 127.0.0.1:9050 https://www.google.com
export ALL_PROXY=socks5h://127.0.0.1:9050
```

## 管理命令

```bash
./tor-start.sh start     # 启动 (自动用缓存)
./tor-start.sh stop      # 停止
./tor-start.sh restart   # 重启
./tor-start.sh status    # 状态 (显示平台信息)
./tor-start.sh refresh   # 刷新描述符缓存
./tor-start.sh fresh     # 清除缓存并启动
./tor-start.sh setup     # 下载/编译当前平台依赖
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
├── bin/                         # 平台专属二进制
│   ├── linux-x86_64/           # Linux x86_64
│   │   ├── tor
│   │   └── obfs4proxy
│   ├── macos-x86_64/           # macOS Intel
│   │   ├── tor
│   │   └── obfs4proxy
│   ├── macos-aarch64/          # macOS M1/M2/M3
│   │   ├── tor
│   │   └── obfs4proxy
│   └── current -> macos-aarch64  # 当前平台符号链接
├── config/
│   └── torrc.template          # 配置模板 (__DIR__ 占位符)
├── cache/
│   └── descriptors/            # 预缓存描述符 (46MB)
├── src/
│   └── obfs4/                  # obfs4proxy 源码
├── deps/
│   └── go-sdk/                 # Go 1.22.5 SDK (用于重编译)
├── setup.sh                    # 平台依赖安装脚本
├── tor-start.sh                # 启动脚本 (自动检测平台)
├── tor-refresh.sh              # 描述符刷新脚本
├── bridge-finder.py            # 桥接自动发现
├── tor-benchmark.py            # 速度基准测试
└── README.md
```

## 首次使用流程

1. `bash setup.sh` — 自动检测平台，下载对应 Tor 二进制
2. `./tor-start.sh start` — 使用预缓存描述符启动 (~45秒)
3. 代理地址: `socks5h://127.0.0.1:9050`

## 描述符缓存机制

预缓存 19,888 条中继描述符，首次启动也快：
- `cache/descriptors/` — 项目内置缓存
- `data/` — 运行时缓存 (自动同步)
- 停止时自动保存，重启复用 (~30秒)

## 桥接管理

```bash
# Snowflake (推荐 - 无需固定桥接)
python3 bridge-finder.py --snowflake

# 搜索所有来源
python3 bridge-finder.py

# 测试单条桥接
python3 bridge-finder.py --test "obfs4 1.2.3.4:443 FINGERPRINT cert=xxx iat-mode=0"
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

## 重新编译 obfs4proxy

```bash
bash setup.sh  # 自动编译当前平台版本
```

## 故障排除

```bash
./tor-start.sh status    # 查看平台和状态
tail -f logs/tor.log     # 查看日志
./tor-start.sh fresh     # 清除缓存重来
```
