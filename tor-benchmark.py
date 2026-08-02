#!/usr/bin/env python3
"""
tor-benchmark.py - Tor Proxy Speed Benchmark
=============================================
Tests connection speed, latency, and throughput through Tor proxy.

Usage:
    python3 tor-benchmark.py              # Full benchmark
    python3 tor-benchmark.py --quick      # Quick test
    python3 tor-benchmark.py --export     # Export results to JSON
"""

import socket
import struct
import ssl
import time
import json
import sys
import concurrent.futures
from urllib.parse import urlparse

SOCKS_PORT = 9050
TIMEOUT = 30


def socks5_connect(host, port, timeout=TIMEOUT):
    """Connect through SOCKS5 proxy."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(("127.0.0.1", SOCKS_PORT))

    # SOCKS5 handshake
    s.send(b"\x05\x01\x00")
    resp = s.recv(2)
    if resp != b"\x05\x00":
        raise ConnectionError(f"SOCKS5 handshake failed: {resp.hex()}")

    # Connect request
    addr = host.encode()
    req = b"\x05\x01\x00\x03" + bytes([len(addr)]) + addr + struct.pack(">H", port)
    s.send(req)
    resp = s.recv(10)
    if resp[1] != 0x00:
        raise ConnectionError(f"SOCKS5 connect failed: {resp[1]}")

    return s


def http_get(url, timeout=TIMEOUT):
    """HTTP GET through Tor SOCKS5 proxy. Returns (status_code, body_size, time_ms)."""
    parsed = urlparse(url)
    host = parsed.hostname
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    path = parsed.path or "/"
    if parsed.query:
        path += "?" + parsed.query

    start = time.time()

    # Connect through SOCKS5
    sock = socks5_connect(host, port, timeout)

    # TLS
    if parsed.scheme == "https":
        ctx = ssl.create_default_context()
        sock = ctx.wrap_socket(sock, server_hostname=host)

    # HTTP request
    req = f"GET {path} HTTP/1.1\r\nHost: {host}\rConnection: close\r\nUser-Agent: Mozilla/5.0\r\n\r\n"
    sock.send(req.encode())

    # Read response
    data = b""
    while True:
        try:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk
        except socket.timeout:
            break
        except Exception:
            break
    sock.close()

    elapsed = (time.time() - start) * 1000  # ms

    # Parse status
    status = 0
    if b"\r\n" in data:
        try:
            status = int(data.split(b"\r\n")[0].split(b" ")[1])
        except (IndexError, ValueError):
            pass

    return status, len(data), elapsed


def check_tor_running():
    """Check if Tor SOCKS port is open."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(3)
        s.connect(("127.0.0.1", SOCKS_PORT))
        s.close()
        return True
    except:
        return False


def get_exit_ip(timeout=TIMEOUT):
    """Get current Tor exit IP."""
    try:
        status, _, _ = http_get("https://api.ipify.org?format=json", timeout)
        if status == 200:
            return "fetched"
    except:
        pass
    return "unknown"


def benchmark_sequential(urls):
    """Test URLs sequentially."""
    results = []
    for name, url in urls:
        try:
            status, size, ms = http_get(url)
            ok = status in (200, 301, 302, 303)
            results.append({
                "name": name, "url": url, "status": status,
                "size": size, "time_ms": round(ms, 1), "ok": ok
            })
            icon = "✓" if ok else "⚠"
            print(f"  {icon} {name:20s}  {ms:7.0f}ms  HTTP {status}  ({size:,} bytes)")
        except Exception as e:
            results.append({
                "name": name, "url": url, "status": 0,
                "size": 0, "time_ms": 0, "ok": False, "error": str(e)[:80]
            })
            print(f"  ✗ {name:20s}  Error: {str(e)[:60]}")
    return results


def benchmark_parallel(urls, workers=4):
    """Test URLs in parallel."""
    results = []

    def do_test(item):
        name, url = item
        try:
            status, size, ms = http_get(url)
            return {"name": name, "url": url, "status": status,
                    "size": size, "time_ms": round(ms, 1), "ok": status in (200, 301, 302)}
        except Exception as e:
            return {"name": name, "url": url, "status": 0, "ok": False,
                    "time_ms": 0, "error": str(e)[:80]}

    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        futures = {executor.submit(do_test, item): item for item in urls}
        for future in concurrent.futures.as_completed(futures):
            r = future.result()
            results.append(r)
            icon = "✓" if r["ok"] else "✗"
            print(f"  {icon} {r['name']:20s}  {r['time_ms']:7.0f}ms  HTTP {r['status']}")

    return results


def main():
    quick = "--quick" in sys.argv
    export = "--export" in sys.argv

    print("=" * 60)
    print("  Tor Proxy Speed Benchmark")
    print("=" * 60)

    # Check proxy
    if not check_tor_running():
        print("\n✗ Tor SOCKS proxy not running on port", SOCKS_PORT)
        print("  Start with: ./tor-proxy.sh start")
        sys.exit(1)

    print(f"\n✓ Tor proxy running on port {SOCKS_PORT}")

    # Test URLs
    urls = [
        ("Google", "https://www.google.com/"),
        ("Wikipedia", "https://en.wikipedia.org/wiki/Main_Page"),
        ("GitHub", "https://github.com/"),
        ("DuckDuckGo", "https://duckduckgo.com/"),
        ("Reddit", "https://www.reddit.com/"),
        ("BBC", "https://www.bbc.com/"),
        ("Cloudflare", "https://1.1.1.1/"),
        ("Tor Project", "https://www.torproject.org/"),
    ]

    if quick:
        urls = urls[:4]

    # Sequential test
    print(f"\n--- Sequential Test ({len(urls)} URLs) ---")
    start = time.time()
    seq_results = benchmark_sequential(urls)
    seq_time = time.time() - start

    # Parallel test
    if not quick:
        print(f"\n--- Parallel Test ({len(urls)} URLs, 4 workers) ---")
        start = time.time()
        par_results = benchmark_parallel(urls, workers=4)
        par_time = time.time() - start

    # Summary
    print("\n" + "=" * 60)
    print("  Summary")
    print("=" * 60)

    ok_count = sum(1 for r in seq_results if r["ok"])
    times = [r["time_ms"] for r in seq_results if r["ok"]]

    print(f"  Success rate: {ok_count}/{len(seq_results)}")
    if times:
        print(f"  Avg latency:  {sum(times)/len(times):.0f}ms")
        print(f"  Min latency:  {min(times):.0f}ms")
        print(f"  Max latency:  {max(times):.0f}ms")
    print(f"  Total time:   {seq_time:.1f}s (sequential)")
    if not quick:
        print(f"  Parallel:     {par_time:.1f}s")

    if export:
        output = {
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "socks_port": SOCKS_PORT,
            "sequential": seq_results,
            "sequential_time_s": round(seq_time, 2),
        }
        if not quick:
            output["parallel"] = par_results
            output["parallel_time_s"] = round(par_time, 2)

        with open("benchmark-results.json", "w") as f:
            json.dump(output, f, indent=2)
        print(f"\n  Results exported to benchmark-results.json")


if __name__ == "__main__":
    main()
