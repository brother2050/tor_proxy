#!/bin/bash
# tor-refresh.sh - 自动刷新 Tor 描述符缓存
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="$SCRIPT_DIR/cache/descriptors"
DATA_DIR="$SCRIPT_DIR/data"
SOCKS_PORT=9050

log() { echo "[refresh] $*"; }

check_tor() {
    # macOS 用 nc, Linux 用 ss
    if command -v nc &>/dev/null; then
        nc -z 127.0.0.1 "$SOCKS_PORT" 2>/dev/null && return 0
    elif command -v ss &>/dev/null; then
        ss -tlnp 2>/dev/null | grep -q ":$SOCKS_PORT " && return 0
    else
        curl --socks5-hostname 127.0.0.1:"$SOCKS_PORT" -s --connect-timeout 3 "http://x.onion" >/dev/null 2>&1 && return 0
    fi
    return 1
}

is_expired() {
    local consensus="$CACHE_DIR/cached-microdesc-consensus"
    [ ! -f "$consensus" ] && return 0
    local valid_until=$(grep "valid-until" "$consensus" | awk '{print $2, $3}')
    [ -z "$valid_until" ] && return 0
    # 兼容 Linux 和 macOS 的 date 命令
    local until_ts=$(date -d "$valid_until" +%s 2>/dev/null || date -jf "%Y-%m-%d %H:%M:%S" "$valid_until" +%s 2>/dev/null)
    local now_ts=$(date +%s)
    local remaining=$(( (until_ts - now_ts) / 60 ))
    [ "$remaining" -lt 30 ] && return 0
    return 1
}

sync_cache() {
    mkdir -p "$CACHE_DIR"
    for f in cached-certs cached-microdesc-consensus cached-microdescs; do
        [ -f "$DATA_DIR/$f" ] && cp "$DATA_DIR/$f" "$CACHE_DIR/$f"
    done
}

refresh_via_tor() {
    check_tor || { log "Tor not running"; return 1; }
    log "Fetching fresh descriptors via Tor..."
    curl --socks5-hostname 127.0.0.1:$SOCKS_PORT -s --connect-timeout 10 --max-time 20 "http://check.torproject.org/" >/dev/null 2>&1
    sleep 30
    sync_cache
}

add_cron() {
    local cron_line="0 */2 * * * cd $SCRIPT_DIR && ./tor-refresh.sh >> logs/refresh.log 2>&1"
    crontab -l 2>/dev/null | grep -q "tor-refresh" && { log "Cron exists"; return 0; }
    (crontab -l 2>/dev/null; echo "$cron_line") | crontab -
    log "Added cron: every 2 hours"
}

case "${1:-}" in
    --cron)    add_cron ;;
    --status)
        if [ -f "$CACHE_DIR/cached-microdesc-consensus" ]; then
            local_size=$(du -sh "$CACHE_DIR" | awk '{print $1}')
            local_count=$(grep -c "onion-key" "$CACHE_DIR/cached-microdescs" 2>/dev/null || echo 0)
            echo "Cache: $local_size, $local_count relays"
        else echo "No cache"; fi
        ;;
    *)
        if is_expired || [ ! -f "$CACHE_DIR/cached-microdesc-consensus" ]; then
            check_tor && refresh_via_tor || log "Tor not running"
        else
            sync_cache
            log "Cache is fresh"
        fi
        ;;
esac
