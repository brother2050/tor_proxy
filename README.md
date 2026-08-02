# Tor Proxy - 轻量级 Tor 代理工具包

通过 **Snowflake** (WebRTC CDN 隧道) 连接 Tor 网络。**预缓存 19,888 条中继描述符，首次启动仅需 ~45 秒。**

## 启动速度

| 场景 | 耗时 | 命令 |
|------|------|------|
| 首次启动（预缓存） | **~45 秒** | `./tor-start.sh start` |
| 缓存重启 | **~30 秒** | `./tor-start.sh start` |
| 清除缓存重来 | 5-15 分钟 | `./tor-start.sh fresh` |

## 快速使用

```bash
cd tor-proxy

# 启动 (自动使用预缓存描述符)
./tor-start.sh start

# 使用代理
curl --socks5-hostname 127.0.0.1:9050 https://www.google.com
export ALL_PROXY=socks5h://127.0.0.1:9050

# 其他命令
./tor-start.sh stop      # 停止
./tor-start.sh restart   # 重启 (保留缓存)
./tor-start.sh status    # 状态
./tor-start.sh refresh   # 刷新描述符缓存
```

## 测试结果

```
  ✓ Google          10.9s  HTTP 200
  ✓ Wikipedia        2.9s  HTTP 301
  ✓ GitHub          40.0s  HTTP 200
  Exit IP: 192.42.116.94
```

## 描述符缓存机制

**核心优化：预缓存 Tor 描述符到项目中，首次启动也快。**

```
cache/descriptors/
├── cached-certs                  # 目录权威证书 (20KB)
├── cached-microdesc-consensus    # 网络共识 (3.4MB)
└── cached-microdescs             # 19,888 条中继描述符 (42MB)
```

工作流程：
1. `./tor-start.sh start` → 检测 `data/` 是否有有效缓存
2. 如果没有 → 从 `cache/descriptors/` 部署预缓存
3. Tor 启动 → 使用缓存快速引导 (~45秒)
4. Tor 运行时 → 自动更新描述符
5. 停止时 → 自动同步到 `cache/descriptors/`

自动刷新：
- Tor 运行时会自动更新描述符
- `./tor-refresh.sh --cron` 添加每2小时自动刷新
- `./tor-start.sh refresh` 手动刷新

## 项目结构

```
tor-proxy/
├── tor                    # Tor 0.4.8.14 (3.2MB)
├── obfs4proxy             # lyrebird 传输插件 (23MB)
├── libevent-2.1.so.7*     # Tor 依赖库
├── cache/
│   └── descriptors/       # 预缓存描述符 (46MB)
│       ├── cached-certs
│       ├── cached-microdesc-consensus
│       └── cached-microdescs
├── config/
│   └── torrc              # Tor 配置 (Snowflake)
├── src/
│   └── obfs4/             # obfs4proxy 完整源码
├── deps/
│   └── go-sdk/            # Go 1.22.5 SDK
├── tor-start.sh           # 启动脚本 (自动缓存)
├── tor-refresh.sh         # 描述符刷新脚本
├── bridge-finder.py       # 桥接自动发现
├── tor-benchmark.py       # 速度基准测试
├── setup-bridge.sh        # VPS 桥接部署
└── README.md
```

## 桥接管理

桥接会失效，工具内置自动发现：

```bash
# Snowflake (推荐 - 无需固定桥接)
python3 bridge-finder.py --snowflake

# 搜索所有来源的桥接
python3 bridge-finder.py

# 测试单条桥接
python3 bridge-finder.py --test "obfs4 1.2.3.4:443 FINGERPRINT cert=xxx iat-mode=0"

# 手动添加桥接到 bridges.txt
echo "obfs4 1.2.3.4:443 FINGERPRINT cert=xxx iat-mode=0" >> bridges.txt
python3 bridge-finder.py --apply
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

## 重新编译

```bash
export GOROOT="$(pwd)/deps/go-sdk/go"
export PATH="$GOROOT/bin:$PATH"
cd src/obfs4 && chmod -R u+w .
go build -o ../../obfs4proxy ./cmd/lyrebird/
```

## 故障排除

```bash
tail -f logs/tor.log           # 查看日志
./tor-start.sh restart         # 重启
./tor-start.sh fresh           # 清除缓存重来
./tor-start.sh status          # 查看状态
```
