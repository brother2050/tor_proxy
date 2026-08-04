# Tor Proxy - 跨平台 Tor 代理工具包

统一多桥接管理：**Snowflake → obfs4 → meek** 自动降级，不再各走各的。**预缓存 19,888 条中继描述符，首次启动 ~30-45 秒。**

## 支持平台

| 平台 | 架构 | tor | obfs4proxy | 优化 |
|------|------|-----|-----------|------|
| Linux | x86_64 | ✅ 内置 | ✅ 内置 | ✅ ulimit 优化 |
| macOS | x86_64 (Intel) | ✅ 内置 | ✅ 内置 | ✅ quarantine 修复 + UDP 缓冲区 |
| macOS | aarch64 (M1/M2/M3) | ✅ 内置 | ✅ 内置 | ✅ quarantine 修复 + UDP 缓冲区 |
| Windows | x86_64 | ✅ 内置 | ✅ 内置 | PowerShell 支持 |

## 快速开始

### Linux / macOS

```bash
git clone https://ghfast.top/https://github.com/brother2050/tor_proxy.git
cd tor_proxy

# 一键启动 (自动完成所有事情)
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
./tor-start.sh start     # 启动 (自动选最优桥接)
./tor-start.sh stop      # 停止
./tor-start.sh restart   # 重启
./tor-start.sh status    # 状态
./tor-start.sh fresh     # 清除缓存并启动
./tor-start.sh refresh   # 刷新描述符缓存
./tor-start.sh bridge    # 桥接管理
```

### 桥接管理
```bash
./tor-bridge.sh list              # 列出所有可用桥接
./tor-bridge.sh test              # 测试所有桥接连通性
./tor-bridge.sh auto              # 自动选择最快桥接
./tor-bridge.sh add <bridge-line> # 添加自定义桥接
./tor-bridge.sh fetch             # 从网络获取新桥接
./tor-bridge.sh reset             # 重置为默认配置
```

### Windows
```powershell
.\tor-start.ps1 start     # 启动
.\tor-start.ps1 stop      # 停止
.\tor-start.ps1 status    # 状态
.\tor-start.ps1 fresh     # 清除缓存并启动
```

## 架构改进 (v2)

### 统一多桥接 (不再各走各的)

之前：Snowflake、obfs4、meek 各自独立配置文件，手动切换
现在：**一个配置文件包含所有桥接类型，Tor 自动降级**

```
config/torrc.template
├── Snowflake (WebRTC CDN 隧道) ← 优先
├── obfs4 (内置公共桥接)         ← 备选
└── meek_lite (CDN 伪装)         ← 兜底
```

Tor 会按顺序尝试，第一个成功就用。无需手动干预。

### macOS 专属优化

- **Gatekeeper 修复**：自动移除 `com.apple.quarantine` 隔离标记
- **DYLD_LIBRARY_PATH**：正确设置动态库路径
- **UDP 缓冲区**：检测并提示优化 Snowflake WebRTC 所需的 UDP 缓冲区
- **libevent 软链接**：自动处理 macOS libevent 依赖

### Bootstrap 优化

- **智能超时**：60 秒无进度自动重启 Tor
- **更快的电路参数**：`CircuitBuildTimeout 20`、`MaxClientCircuitsPending 128`
- **并行描述符获取**：`FetchDirInfoEarly 1`、`FetchDirInfoExtraEarly 1`

## 测试结果

```
  ✓ Google          10s    HTTP 200
  ✓ Wikipedia       1.3s   HTTP 301
  ✓ GitHub          30s    HTTP 200
  Bootstrap:        17-31s (使用缓存)
  出口 IP:          185.220.101.17
```

## 工作原理

```
你的机器                桥接隧道                  Tor 网络
  │                       │                       │
  ├─ Tor ──obfs4proxy─────┼── Snowflake (WebRTC) ─┼── Tor 中继
  │  (SOCKS5)  (多协议)    ├── obfs4 (混淆)       │  (出口)
  │                       └── meek (CDN 伪装)     │
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
│   └── torrc.template          # 统一多桥接配置模板
├── cache/
│   └── descriptors/            # 预缓存描述符 (46MB, 19888 relay)
├── src/
│   └── obfs4/                  # obfs4proxy 完整源码
├── deps/
│   └── go-sdk/                 # Go 1.22.5 SDK (重编译用)
├── tor-start.sh                # 启动脚本 (Linux/macOS, 统一多桥接)
├── tor-bridge.sh               # 桥接管理器 (list/test/auto/add)
├── tor-start.ps1               # 启动脚本 (Windows)
├── bridge-finder.py            # 桥接自动发现
├── tor-benchmark.py            # 速度基准测试
├── download-all.sh             # 一键下载所有平台 Tor
├── setup.sh                    # 平台依赖安装 (含 macOS 优化)
└── README.md
```

## 描述符缓存

预缓存 19,888 条中继描述符：
- 首次启动 ~30-45 秒 (使用缓存)
- 后续重启 ~20-30 秒 (复用缓存)
- 停止时自动保存，重启自动加载

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

## 故障排除

```bash
./tor-start.sh status        # 查看平台和状态
./tor-bridge.sh test         # 测试桥接连通性
./tor-bridge.sh auto         # 自动选择最快桥接
tail -f logs/tor.log         # 查看日志
./tor-start.sh fresh         # 清除缓存重来
```

### macOS 特别提示

如果 Snowflake 连接慢 (卡在 10%)，尝试：
```bash
# 增大 UDP 缓冲区
sudo sysctl -w net.inet.udp.recvspace=524288
sudo sysctl -w net.inet.udp.maxdgram=524288

# 或切换到 obfs4 (更快)
./tor-bridge.sh auto
```
