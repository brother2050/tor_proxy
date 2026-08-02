#!/usr/bin/env python3
"""
tor-proxy.py - Lightweight Tor SOCKS5 Proxy Manager
====================================================
Simple tool to run Tor as a local SOCKS5 proxy for web access.

Usage:
    python3 tor-proxy.py start          # Start Tor proxy
    python3 tor-proxy.py stop           # Stop Tor proxy
    python3 tor-proxy.py status         # Check status
    python3 tor-proxy.py test           # Test connectivity
    python3 tor-proxy.py curl <url>     # Fetch URL via Tor
    python3 tor-proxy.py ip             # Show Tor exit IP
    python3 tor-proxy.py circuit        # Show current circuit
    python3 tor-proxy.py newcircuit     # Request new circuit
"""

import os
import sys
import time
import signal
import socket
import subprocess
import json
import struct
import urllib.request
import urllib.error
from pathlib import Path

# === Config ===
BASE_DIR = Path(__file__).parent.resolve()
TOR_BIN = BASE_DIR / "tor"
TOR_DATA = BASE_DIR / "data"
TOR_LOGS = BASE_DIR / "logs"
TOR_CONFIG = BASE_DIR / "config" / "torrc"
TOR_PID_FILE = TOR_DATA / "tor.pid"
SOCKS_PORT = 9050
CONTROL_PORT = 9051
LD_LIBRARY_PATH = str(BASE_DIR)

# Environment for running Tor
ENV = os.environ.copy()
ENV["LD_LIBRARY_PATH"] = LD_LIBRARY_PATH


def ensure_dirs():
    TOR_DATA.mkdir(parents=True, exist_ok=True)
    TOR_LOGS.mkdir(parents=True, exist_ok=True)


def get_pid():
    """Get Tor PID from pidfile or by finding the process."""
    if TOR_PID_FILE.exists():
        try:
            return int(TOR_PID_FILE.read_text().strip())
        except ValueError:
            pass
    # Fallback: find tor process
    try:
        result = subprocess.run(
            ["pgrep", "-f", f"tor.*{TOR_DATA}"],
            capture_output=True, text=True
        )
        if result.stdout.strip():
            return int(result.stdout.strip().split("\n")[0])
    except Exception:
        pass
    return None


def is_running():
    """Check if Tor is running."""
    pid = get_pid()
    if pid:
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            pass
    return False


def wait_for_socks(port=SOCKS_PORT, timeout=120):
    """Wait for SOCKS port to become available."""
    start = time.time()
    while time.time() - start < timeout:
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(2)
            s.connect(("127.0.0.1", port))
            s.close()
            return True
        except (ConnectionRefusedError, socket.timeout, OSError):
            pass
        finally:
            try:
                s.close()
            except Exception:
                pass
        time.sleep(1)
    return False


def wait_for_bootstrap(timeout=180):
    """Wait for Tor to finish bootstrapping."""
    log_file = TOR_LOGS / "tor.log"
    start = time.time()
    while time.time() - start < timeout:
        if log_file.exists():
            content = log_file.read_text()
            if "Bootstrapped 100%" in content:
                return True
            if "Bootstrapped" in content:
                # Get latest bootstrap percentage
                for line in content.split("\n"):
                    if "Bootstrapped" in line and "%" in line:
                        try:
                            pct = int(line.split("Bootstrapped ")[1].split("%")[0])
                            print(f"\r  Bootstrap: {pct}%", end="", flush=True)
                        except (ValueError, IndexError):
                            pass
        time.sleep(2)
    print()
    return False


def start_tor():
    """Start Tor daemon."""
    ensure_dirs()

    if is_running():
        print(f"✓ Tor is already running (PID: {get_pid()})")
        return True

    print("Starting Tor proxy...")
    print(f"  Config: {TOR_CONFIG}")
    print(f"  SOCKS port: {SOCKS_PORT}")

    # Clear old log
    log_file = TOR_LOGS / "tor.log"
    if log_file.exists():
        log_file.unlink()

    cmd = [
        str(TOR_BIN),
        "-f", str(TOR_CONFIG),
        "--RunAsDaemon", "1",
        "--PidFile", str(TOR_PID_FILE),
        "--Log", f"notice file {log_file}",
    ]

    try:
        result = subprocess.run(
            cmd, env=ENV, capture_output=True, text=True, timeout=10
        )
        if result.returncode != 0:
            print(f"✗ Failed to start Tor: {result.stderr}")
            return False
    except subprocess.TimeoutExpired:
        pass  # Tor daemonizes, timeout is expected

    # Wait for Tor to boot
    print("Waiting for Tor to bootstrap...")
    if wait_for_socks(timeout=30):
        print(f"  SOCKS port {SOCKS_PORT} ready")

    if wait_for_bootstrap(timeout=180):
        print("✓ Tor bootstrapped successfully!")
        print(f"  SOCKS5 proxy: socks5h://127.0.0.1:{SOCKS_PORT}")
        print(f"  PID: {get_pid()}")
        return True
    else:
        print("⚠ Tor started but bootstrap incomplete (may still work)")
        print(f"  Check logs: {log_file}")
        return True


def stop_tor():
    """Stop Tor daemon."""
    pid = get_pid()
    if not pid:
        print("Tor is not running")
        return

    print(f"Stopping Tor (PID: {pid})...")
    try:
        os.kill(pid, signal.SIGTERM)
        time.sleep(2)
        try:
            os.kill(pid, 0)
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        print("✓ Tor stopped")
    except ProcessLookupError:
        print("Tor was not running")


def show_status():
    """Show Tor status."""
    pid = get_pid()
    if pid and is_running():
        print(f"✓ Tor is running (PID: {pid})")
        print(f"  SOCKS proxy: socks5h://127.0.0.1:{SOCKS_PORT}")

        # Check bootstrap status
        log_file = TOR_LOGS / "tor.log"
        if log_file.exists():
            content = log_file.read_text()
            for line in reversed(content.split("\n")):
                if "Bootstrapped" in line:
                    print(f"  {line.strip()}")
                    break
    else:
        print("✗ Tor is not running")


def socks5_request(host, port, timeout=30):
    """Make a connection through SOCKS5 proxy."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)

    # Connect to SOCKS5 proxy
    s.connect(("127.0.0.1", SOCKS_PORT))

    # SOCKS5 greeting
    s.send(b"\x05\x01\x00")  # Version 5, 1 auth method, no auth
    resp = s.recv(2)
    if resp != b"\x05\x00":
        s.close()
        raise ConnectionError(f"SOCKS5 greeting failed: {resp.hex()}")

    # SOCKS5 connect request
    # CMD=0x01 (connect), RSV=0x00, ATYP=0x03 (domain)
    addr_bytes = host.encode("utf-8")
    req = b"\x05\x01\x00\x03" + bytes([len(addr_bytes)]) + addr_bytes + struct.pack(">H", port)
    s.send(req)

    # Read response
    resp = s.recv(10)
    if len(resp) < 10:
        s.close()
        raise ConnectionError(f"SOCKS5 response too short: {resp.hex()}")

    status = resp[1]
    if status != 0x00:
        errors = {
            0x01: "general failure",
            0x02: "connection not allowed",
            0x03: "network unreachable",
            0x04: "host unreachable",
            0x05: "connection refused",
            0x06: "TTL expired",
            0x07: "command not supported",
            0x08: "address type not supported",
        }
        s.close()
        raise ConnectionError(f"SOCKS5 connect failed: {errors.get(status, f'code {status}')}")

    return s


def fetch_via_tor(url, timeout=30):
    """Fetch a URL through Tor SOCKS5 proxy."""
    from urllib.parse import urlparse

    parsed = urlparse(url)
    host = parsed.hostname
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    use_ssl = parsed.scheme == "https"

    # Connect through SOCKS5
    sock = socks5_request(host, port, timeout)

    if use_ssl:
        import ssl
        ctx = ssl.create_default_context()
        sock = ctx.wrap_socket(sock, server_hostname=host)

    # Build HTTP request
    path = parsed.path or "/"
    if parsed.query:
        path += "?" + parsed.query

    request = f"GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\nUser-Agent: Mozilla/5.0\r\n\r\n"
    sock.send(request.encode())

    # Read response
    response = b""
    while True:
        try:
            chunk = sock.recv(4096)
            if not chunk:
                break
            response += chunk
        except socket.timeout:
            break
        except Exception:
            break

    sock.close()

    # Parse response
    if b"\r\n\r\n" in response:
        header, body = response.split(b"\r\n\r\n", 1)
        header_str = header.decode("utf-8", errors="replace")
        status_line = header_str.split("\r\n")[0]
        return status_line, body.decode("utf-8", errors="replace")
    return None, response.decode("utf-8", errors="replace")


def test_connectivity():
    """Test Tor connectivity to various services."""
    tests = [
        ("Tor Check", "http://check.torproject.org/", "Tor Project"),
        ("Google", "https://www.google.com/", "google"),
        ("Google (IPv6)", "https://ipv6.google.com/", "google"),
        ("Wikipedia", "https://en.wikipedia.org/wiki/Main_Page", "Wikipedia"),
        ("GitHub", "https://github.com/", "GitHub"),
        ("Cloudflare", "https://1.1.1.1/", "Cloudflare"),
        ("DuckDuckGo", "https://duckduckgo.com/", "DuckDuckGo"),
    ]

    print("=" * 60)
    print("Tor Connectivity Test")
    print("=" * 60)

    results = []
    for name, url, expected in tests:
        print(f"\n  Testing {name}...")
        print(f"    URL: {url}")
        try:
            start = time.time()
            status, body = fetch_via_tor(url, timeout=30)
            elapsed = time.time() - start

            if status:
                code = status.split(" ")[1] if " " in status else "?"
                found = expected.lower() in body.lower() if body else False
                result = "✓" if (code.startswith("2") or code == "301" or code == "302") else "⚠"
                print(f"    {result} Status: {status}")
                print(f"    Time: {elapsed:.2f}s")
                if found:
                    print(f"    Content: Found '{expected}'")
                results.append((name, True, elapsed, code))
            else:
                print(f"    ✗ No HTTP response")
                results.append((name, False, elapsed, "no response"))
        except Exception as e:
            elapsed = time.time() - start
            print(f"    ✗ Error: {e}")
            results.append((name, False, elapsed, str(e)[:50]))

    # Summary
    print("\n" + "=" * 60)
    print("Summary:")
    print("=" * 60)
    for name, ok, elapsed, detail in results:
        status = "✓" if ok else "✗"
        print(f"  {status} {name:20s} {elapsed:6.2f}s  {detail}")

    success = sum(1 for _, ok, _, _ in results if ok)
    print(f"\n  Result: {success}/{len(results)} tests passed")


def show_ip():
    """Show current Tor exit IP."""
    print("Fetching Tor exit IP...")
    try:
        status, body = fetch_via_tor("https://api.ipify.org?format=json", timeout=30)
        if status and "200" in status:
            data = json.loads(body)
            print(f"  Tor Exit IP: {data.get('ip', '?')}")
        else:
            # Fallback
            status, body = fetch_via_tor("https://httpbin.org/ip", timeout=30)
            if status and "200" in status:
                data = json.loads(body)
                print(f"  Tor Exit IP: {data.get('origin', '?')}")
            else:
                print(f"  Could not determine IP: {status}")
    except Exception as e:
        print(f"  Error: {e}")


def show_circuit():
    """Show current Tor circuit (requires ControlPort)."""
    print("Note: Circuit info requires ControlPort to be enabled.")
    print("Current configuration uses SOCKS proxy only.")
    print(f"  SOCKS proxy: socks5h://127.0.0.1:{SOCKS_PORT}")
    print("\nTo enable ControlPort, add to torrc:")
    print("  ControlPort 9051")
    print("  HashedControlPassword <generate with 'tor --hash-password <password>'>")


def new_circuit():
    """Request a new Tor circuit."""
    print("Requesting new circuit...")
    # Simple way: close and re-open connection
    # Better way: use ControlPort (not enabled by default)
    print("Note: For best results, restart Tor to get a new circuit")
    print("  python3 tor-proxy.py stop && python3 tor-proxy.py start")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return

    cmd = sys.argv[1].lower()

    if cmd == "start":
        start_tor()
    elif cmd == "stop":
        stop_tor()
    elif cmd == "restart":
        stop_tor()
        time.sleep(2)
        start_tor()
    elif cmd == "status":
        show_status()
    elif cmd == "test":
        if not is_running():
            print("Tor is not running. Start it first: python3 tor-proxy.py start")
            return
        test_connectivity()
    elif cmd == "curl" or cmd == "fetch":
        if len(sys.argv) < 3:
            print("Usage: python3 tor-proxy.py curl <url>")
            return
        url = sys.argv[2]
        print(f"Fetching {url} via Tor...")
        try:
            status, body = fetch_via_tor(url)
            print(f"Status: {status}")
            print("-" * 60)
            # Print first 2000 chars of body
            print(body[:2000])
            if len(body) > 2000:
                print(f"\n... ({len(body)} bytes total)")
        except Exception as e:
            print(f"Error: {e}")
    elif cmd == "ip":
        if not is_running():
            print("Tor is not running.")
            return
        show_ip()
    elif cmd == "circuit":
        show_circuit()
    elif cmd == "newcircuit":
        new_circuit()
    else:
        print(f"Unknown command: {cmd}")
        print(__doc__)


if __name__ == "__main__":
    main()
