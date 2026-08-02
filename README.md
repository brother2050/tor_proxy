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
git clone https://ghfast.top/https://github.com/brother2050/tor_proxy.git
cd tor_proxy

# 启动 (自动使用预缓存描述符)
./tor-start.sh start

# 使用代理
curl --socks5-hostname 127.0.0.1:9050 https://www.google.com
export ALL_PROXY=socks5h://127.0.0.1:9050
```

## 管理命令

```bash
./tor-start.sh start     # 启动 (自动用缓存，~45秒)
./tor-start.sh stop      # 停止 (自动保存缓存)
./tor-start.sh restart   # 重启 (保留缓存，~30秒)
./tor-start.sh status    # 查看状态
./tor-start.sh refresh   # 刷新描述符缓存
./tor-start.sh fresh     # 清除缓存并启动 (首次用)
```

## 测试结果

```
  ✓ Google          10.9s  HTTP 200
  ✓ Wikipedia        2.9s  HTTP 301
  ✓ GitHub          40.0s  HTTP 200
  Exit IP: 192.42.116.94 (荷兰 Tor 出口)
```

## 工作原理

```
你的机器                Snowflake CDN            Tor 网络
  │                       │                       │
  ├─ Tor ──obfs4proxy─────┼── Cloudflare ─────────┼── Tor 中继
  │  (SOCKS5)  (WebRTC)   │  (CDN 隧道)           │  (出口)
  │                       │                       │
  └─ curl/browser ────────┴───────────────────────┴── Google
```

**Snowflake** 是 Tor 的抗审查传输协议：
1. obfs4proxy 通过 WebRTC 连接到志愿者运行的 Snowflake 代理
2. Snowflake 代理通过 Cloudflare CDN 转发流量到 Tor 中继
3. 网络只看到你和 Cloudflare 的 HTTPS 连接，无法识别 Tor 流量

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

## 桥接管理

桥接会失效，工具内置自动发现：

```bash
# Snowflake (推荐 - 无需固定桥接，自动发现志愿者代理)
python3 bridge-finder.py --snowflake

# 搜索所有来源的桥接 (GitHub/bridgedb/内置)
python3 bridge-finder.py

# 快速模式 (只测 TCP 连通性)
python3 bridge-finder.py --quick

# 测试单条桥接
python3 bridge-finder.py --test "obfs4 1.2.3.4:443 FINGERPRINT cert=xxx iat-mode=0"

# 找到后自动写入配置
python3 bridge-finder.py --apply
```

### 获取桥接的途径

1. **自动**: `python3 bridge-finder.py` (搜索 GitHub 仓库)
2. **官网**: https://bridges.torproject.org/
3. **邮件**: 发送到 bridges@torproject.org，主题 `get transport obfs4`
4. **Telegram**: @GetBridgesBot
5. **自建**: `bash setup-bridge.sh` (在 VPS 上部署)

### 手动添加桥接

将桥接行写入 `bridges.txt` (每行一条)：

```
obfs4 1.2.3.4:443 FINGERPRINT cert=xxx iat-mode=0
obfs4 5.6.7.8:9001 FINGERPRINT cert=yyy iat-mode=0
```

然后运行：`python3 bridge-finder.py --apply`

## 自建桥接

在有公网的 VPS 上部署桥接供自己使用：

```bash
bash setup-bridge.sh
# 输出: Bridge obfs4 1.2.3.4:54321 cert=xxx iat-mode=0
```

## 项目结构

```
tor-proxy/
├── tor                    # Tor 0.4.8.14 二进制 (3.2MB)
├── obfs4proxy             # lyrebird 传输插件 (23MB)
├── libevent-2.1.so.7*     # Tor 依赖库 (327KB)
├── cache/
│   └── descriptors/       # 预缓存描述符 (46MB)
│       ├── cached-certs
│       ├── cached-microdesc-consensus
│       └── cached-microdescs
├── config/
│   └── torrc              # Tor 配置 (Snowflake)
├── src/
│   └── obfs4/             # obfs4proxy 完整源码 (lyrebird)
│       ├── cmd/lyrebird/  # 主程序入口
│       ├── transports/    # 传输协议 (obfs4/snowflake/webtunnel/meek)
│       └── go.mod         # Go 模块定义
├── deps/
│   └── go-sdk/            # Go 1.22.5 SDK (216MB, 用于重编译)
├── tor-start.sh           # 启动脚本 (自动缓存管理)
├── tor-refresh.sh         # 描述符刷新脚本
├── bridge-finder.py       # 桥接自动发现工具
├── tor-benchmark.py       # 速度基准测试
├── tor-proxy.py           # Python 管理工具
├── tor-proxy.sh           # Shell 管理脚本
├── connect-bridge.sh      # 桥接连接脚本
├── setup-bridge.sh        # VPS 桥接部署脚本
├── deploy.sh              # 打包部署脚本
└── README.md
```

## 浏览器配置

### Firefox
1. 设置 → 常规 → 网络设置 → 设置
2. 手动代理配置 → SOCKS 主机: `127.0.0.1` 端口: `9050`
3. 选择 "SOCKS v5"

### Chrome
```bash
google-chrome --proxy-server="socks5://127.0.0.1:9050"
```

## Python 使用

```python
import requests

proxies = {
    'http': 'socks5h://127.0.0.1:9050',
    'https': 'socks5h://127.0.0.1:9050'
}

r = requests.get('https://api.ipify.org', proxies=proxies)
print(f"Tor exit IP: {r.text}")
```

需要安装: `pip install requests[socks]`

## 环境变量代理

```bash
export ALL_PROXY=socks5h://127.0.0.1:9050
export HTTP_PROXY=socks5h://127.0.0.1:9050
export HTTPS_PROXY=socks5h://127.0.0.1:9050

# 取消
unset ALL_PROXY HTTP_PROXY HTTPS_PROXY
```

## 性能测试

```bash
./tor-benchmark.py           # 完整测试
./tor-benchmark.py --quick   # 快速测试
./tor-benchmark.py --export  # 导出 JSON
```

## 重新编译 obfs4proxy

```bash
export GOROOT="$(pwd)/deps/go-sdk/go"
export PATH="$GOROOT/bin:$PATH"
export GOPATH="$(pwd)/deps/gopath"
export GO111MODULE=on
export GOPROXY=https://goproxy.cn,direct

cd src/obfs4 && chmod -R u+w .
go build -o ../../obfs4proxy ./cmd/lyrebird/
cd ../..
./obfs4proxy -version
```

## 故障排除

```bash
# 查看日志
tail -f logs/tor.log

# 前台启动 (调试)
LD_LIBRARY_PATH=. ./tor -f config/torrc --Log "notice stdout"

# 检查依赖
ldd tor
ldd obfs4proxy

# 重启
./tor-start.sh restart

# 清除缓存重来
./tor-start.sh fresh

# 查看状态
./tor-start.sh status
```

## 配置说明

`config/torrc` 关键参数：

```
UseBridges 1
ClientTransportPlugin snowflake exec ./obfs4proxy

Bridge snowflake 192.0.2.3:80 2B280B23E1107BB62ABFC40DDCC8824814F80A72 \
  fingerprint=2B280B23E1107BB62ABFC40DDCC8824814F80A72 \
  url=https://snowflake-broker.torproject.net/ \
  ice=stun:stun.antisip.com:3478,stun:stun.dus.net:3478 \
  utls-imitate=hellorandomizedalpn
```

- `url` - Snowflake broker 地址 (Tor 项目维护)
- `ice` - STUN 服务器 (用于 NAT 穿透)
- `utls-imitate` - TLS 指纹伪装

## 系统要求

- Linux x86_64
- glibc 2.38+
- OpenSSL 3.0+
- 网络: 需可达 STUN 服务器和 Snowflake broker

## 组件版本

| 组件 | 版本 | 来源 |
|------|------|------|
| Tor | 0.4.8.14 | Ubuntu Noble .deb |
| obfs4proxy (lyrebird) | devel | GitLab 源码编译 |
| Go | 1.22.5 | 阿里云镜像 |
| libevent | 2.1.12 | Ubuntu Noble .deb |

## 安全说明

- 此工具通过 Tor 网络匿名化流量
- Snowflake 使用 WebRTC + CDN 隧道，流量看起来像普通 HTTPS
- 出口节点可以看到你的请求内容 (HTTP 明文)
- 建议始终使用 HTTPS
- Tor 不等于绝对安全，请参考 https://support.torproject.org/
