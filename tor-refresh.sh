#!/bin/bash
# tor-refresh.sh - 自动刷新 Tor 描述符缓存
# ============================================
# 通过运行中的 Tor 代理下载最新描述符
# 可配合 cron 定时执行
#
# 用法:
#   ./tor-refresh.sh              # 刷新一次
#   ./tor-refresh.sh --cron       # 添加到 crontab (每2小时)
#   ./tor-refresh.sh --status     # 检查缓存状态

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="$SCRIPT_DIR/cache/descriptors"
DATA_DIR="$SCRIPT_DIR/data"
SOCKS_PORT=9050

log() { echo "[refresh] $*"; }

# 检查 Tor 是否运行
check_tor() {
    ss -tlnp 2>/dev/null | grep -q ":$SOCKS_PORT " && return 0
    return 1
}

# 检查 consensus 是否过期
is_expired() {
    local consensus="$CACHE_DIR/cached-microdesc-consensus"
    if [ ! -f "$consensus" ]; then
        return 0  # 不存在=过期
    fi

    # 获取 valid-until 时间
    local valid_until=$(grep "valid-until" "$consensus" | awk '{print $2, $3}')
    if [ -z "$valid_until" ]; then
        return 0
    fi

    # 转换为时间戳比较
    local until_ts=$(date -d "$valid_until" +%s 2>/dev/null)
    local now_ts=$(date +%s)
    local remaining=$(( (until_ts - now_ts) / 60 ))

    if [ "$remaining" -lt 30 ]; then
        log "Consensus expires in ${remaining}min - needs refresh"
        return 0
    fi

    log "Consensus valid for ${remaining}min - OK"
    return 1
}

# 从 data 目录复制到 cache
sync_cache() {
    mkdir -p "$CACHE_DIR"

    local copied=0
    for f in cached-certs cached-microdesc-consensus cached-microdescs; do
        if [ -f "$DATA_DIR/$f" ]; then
            local src_size=$(stat -c%s "$DATA_DIR/$f" 2>/dev/null || echo 0)
            local dst_size=$(stat -c%s "$CACHE_DIR/$f" 2>/dev/null || echo 0)
            if [ "$src_size" -gt "$dst_size" ] 2>/dev/null; then
                cp "$DATA_DIR/$f" "$CACHE_DIR/$f"
                copied=$((copied + 1))
            fi
        fi
    done

    if [ "$copied" -gt 0 ]; then
        log "Synced $copied files to cache"
    fi
}

# 从 cache 部署到 data
deploy_cache() {
    if [ ! -f "$CACHE_DIR/cached-microdesc-consensus" ]; then
        log "No cached descriptors available"
        return 1
    fi

    mkdir -p "$DATA_DIR"
    cp "$CACHE_DIR/cached-certs" "$DATA_DIR/" 2>/dev/null
    cp "$CACHE_DIR/cached-microdesc-consensus" "$DATA_DIR/" 2>/dev/null
    cp "$CACHE_DIR/cached-microdescs" "$DATA_DIR/" 2>/dev/null
    cp "$CACHE_DIR/state" "$DATA_DIR/" 2>/dev/null

    log "Deployed cached descriptors to data/"
}

# 通过 Tor 刷新描述符
refresh_via_tor() {
    if ! check_tor; then
        log "Tor not running - cannot refresh"
        return 1
    fi

    log "Fetching fresh descriptors via Tor..."

    # 触发 Tor 下载新 consensus
    # 通过 SOCKS 请求一个 .onion 地址会触发 Tor 建立电路
    # 电路建立过程会自动下载最新描述符
    curl --socks5-hostname 127.0.0.1:$SOCKS_PORT \
        -s --connect-timeout 10 --max-time 20 \
        "http://check.torproject.org/" >/dev/null 2>&1

    # 等待 Tor 更新描述符
    sleep 30

    # 同步到缓存
    sync_cache

    local count=$(grep -c "onion-key" "$CACHE_DIR/cached-microdescs" 2>/dev/null || echo 0)
    log "Cached $count relay descriptors"
}

# 显示状态
show_status() {
    echo "=== 描述符缓存状态 ==="
    echo ""

    if [ -f "$CACHE_DIR/cached-microdesc-consensus" ]; then
        local size=$(du -sh "$CACHE_DIR" | awk '{print $1}')
        local count=$(grep -c "onion-key" "$CACHE_DIR/cached-microdescs" 2>/dev/null || echo 0)
        local valid_until=$(grep "valid-until" "$CACHE_DIR/cached-microdesc-consensus" | awk '{print $2, $3}')
        local valid_after=$(grep "valid-after" "$CACHE_DIR/cached-microdesc-consensus" | awk '{print $2, $3}')

        echo "  缓存大小: $size"
        echo "  中继数量: $count"
        echo "  有效期始: $valid_after"
        echo "  有效期止: $valid_until"

        local until_ts=$(date -d "$valid_until" +%s 2>/dev/null)
        local now_ts=$(date +%s)
        local remaining=$(( (until_ts - now_ts) / 60 ))
        if [ "$remaining" -gt 0 ]; then
            echo "  剩余时间: ${remaining} 分钟"
        else
            echo "  状态: 已过期"
        fi
    else
        echo "  无缓存"
    fi
}

# 添加 cron 任务
add_cron() {
    local cron_line="0 */2 * * * cd $SCRIPT_DIR && ./tor-refresh.sh >> logs/refresh.log 2>&1"

    # 检查是否已存在
    crontab -l 2>/dev/null | grep -q "tor-refresh" && {
        log "Cron already exists"
        return 0
    }

    (crontab -l 2>/dev/null; echo "$cron_line") | crontab -
    log "Added cron job: every 2 hours"
    log "View: crontab -l"
}

case "${1:-}" in
    --cron)    add_cron ;;
    --status)  show_status ;;
    --deploy)  deploy_cache ;;
    *)
        if is_expired || [ ! -f "$CACHE_DIR/cached-microdesc-consensus" ]; then
            if check_tor; then
                refresh_via_tor
            else
                log "Tor not running and cache expired"
                log "Start Tor first: ./tor-start.sh start"
                log "Or use pre-cached: ./tor-start.sh start"
                exit 1
            fi
        else
            log "Cache is fresh, no refresh needed"
            # 即使不刷新也同步最新
            sync_cache
        fi
        ;;
esac
