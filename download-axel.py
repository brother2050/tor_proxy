#!/usr/bin/env python3
"""
download-axel.py - 多线程下载加速器
====================================
类似 aria2c 原理：分块 + 多线程 + 断点续传

用法:
  python3 download-axel.py <url> <output> [threads]

示例:
  python3 download-axel.py https://example.com/file.tar.gz file.tar.gz 8
"""

import sys
import os
import time
import threading
import urllib.request
import urllib.error
import ssl
import math

# ============================================================
# 配置
# ============================================================
DEFAULT_THREADS = 8
CHUNK_TIMEOUT = 60
MAX_RETRIES = 3
RETRY_DELAY = 2
MIN_CHUNK_SIZE = 512 * 1024  # 512KB
USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"


def make_ssl_context():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


class DownloadState:
    """线程安全的下载状态"""
    def __init__(self):
        self.lock = threading.Lock()
        self.chunk_progress = {}  # chunk_id -> downloaded bytes
        self.chunk_done = {}      # chunk_id -> bool
        self.chunk_error = {}     # chunk_id -> error string
        self.total_size = 0
        self.finished = False

    def update(self, chunk_id, downloaded):
        with self.lock:
            self.chunk_progress[chunk_id] = downloaded

    def mark_done(self, chunk_id):
        with self.lock:
            self.chunk_done[chunk_id] = True

    def mark_failed(self, chunk_id, error):
        with self.lock:
            self.chunk_error[chunk_id] = error

    def total_downloaded(self):
        with self.lock:
            return sum(self.chunk_progress.values())


def download_chunk(url, output_path, start, end, chunk_id, state):
    """下载单个分块"""
    tmp_file = f"{output_path}.part{chunk_id}"
    downloaded = 0

    # 检查已有的部分下载
    if os.path.exists(tmp_file):
        downloaded = os.path.getsize(tmp_file)
        state.update(chunk_id, downloaded)

    for retry in range(MAX_RETRIES):
        try:
            current_start = start + downloaded
            if current_start > end and end > 0:
                state.mark_done(chunk_id)
                return True

            req = urllib.request.Request(url)
            req.add_header("User-Agent", USER_AGENT)
            if end > 0:
                req.add_header("Range", f"bytes={current_start}-{end}")

            resp = urllib.request.urlopen(req, timeout=CHUNK_TIMEOUT, context=make_ssl_context())

            mode = "ab" if downloaded > 0 else "wb"
            with open(tmp_file, mode) as f:
                while True:
                    data = resp.read(65536)
                    if not data:
                        break
                    f.write(data)
                    downloaded += len(data)
                    state.update(chunk_id, downloaded)

            state.mark_done(chunk_id)
            return True

        except Exception as e:
            err_msg = str(e)[:60]
            state.mark_failed(chunk_id, err_msg)
            if retry < MAX_RETRIES - 1:
                time.sleep(RETRY_DELAY * (retry + 1))
                # 更新起始位置用于续传
                if os.path.exists(tmp_file):
                    downloaded = os.path.getsize(tmp_file)
                    state.update(chunk_id, downloaded)
            continue

    return False


def get_file_size(url):
    """获取文件大小"""
    ctx = make_ssl_context()

    # 方法1: HEAD 请求
    try:
        req = urllib.request.Request(url, method="HEAD")
        req.add_header("User-Agent", USER_AGENT)
        resp = urllib.request.urlopen(req, timeout=15, context=ctx)
        size = int(resp.headers.get("Content-Length", 0))
        if size > 0:
            return size, True
    except Exception:
        pass

    # 方法2: GET Range 请求
    try:
        req = urllib.request.Request(url)
        req.add_header("User-Agent", USER_AGENT)
        req.add_header("Range", "bytes=0-0")
        resp = urllib.request.urlopen(req, timeout=15, context=ctx)
        cr = resp.headers.get("Content-Range", "")
        resp.close()
        if "/" in cr:
            size = int(cr.split("/")[1])
            if size > 0:
                return size, True
    except Exception:
        pass

    return 0, False


def format_size(size):
    for unit in ["B", "KB", "MB", "GB"]:
        if size < 1024:
            return f"{size:.1f}{unit}"
        size /= 1024
    return f"{size:.1f}TB"


def format_speed(speed):
    if speed < 1024:
        return f"{speed:.0f}B/s"
    elif speed < 1024 * 1024:
        return f"{speed/1024:.1f}KB/s"
    else:
        return f"{speed/(1024*1024):.1f}MB/s"


def format_time(seconds):
    if seconds < 0:
        return "--"
    if seconds < 60:
        return f"{seconds:.0f}s"
    elif seconds < 3600:
        return f"{seconds/60:.1f}min"
    else:
        return f"{seconds/3600:.1f}h"


def progress_printer(state, total_size, num_threads):
    """进度显示线程"""
    start_time = time.time()

    while not state.finished:
        total_dl = state.total_downloaded()
        elapsed = time.time() - start_time
        speed = total_dl / elapsed if elapsed > 0 else 0

        if total_size > 0:
            pct = min(100.0, total_dl * 100 / total_size)
            bar_len = 36
            filled = int(bar_len * pct / 100)
            bar = "█" * filled + "░" * (bar_len - filled)
            remaining = (total_size - total_dl) / speed if speed > 0 else 0
            sys.stderr.write(
                f"\r  {bar} {pct:5.1f}% "
                f"{format_size(total_dl)}/{format_size(total_size)} "
                f"{format_speed(speed)} "
                f"ETA:{format_time(remaining)} "
                f"[{num_threads}T]"
            )
        else:
            sys.stderr.write(
                f"\r  {'░' * 36} "
                f"{format_size(total_dl)} "
                f"{format_speed(speed)} "
                f"耗时:{format_time(elapsed)} "
                f"[{num_threads}T]"
            )
        sys.stderr.flush()

        # 检查所有分块是否完成
        all_done = True
        for i in range(num_threads):
            with state.lock:
                if i not in state.chunk_done:
                    all_done = False
                    break
        if all_done:
            break

        time.sleep(0.5)

    # 最终输出
    total_dl = state.total_downloaded()
    elapsed = time.time() - start_time
    speed = total_dl / elapsed if elapsed > 0 else 0
    sys.stderr.write(
        f"\r  {'█' * 36} 100.0% "
        f"{format_size(total_dl)}"
        f"{'/' + format_size(total_size) if total_size > 0 else ''} "
        f"{format_speed(speed)} "
        f"{' ' * 20}\n"
    )
    sys.stderr.flush()


def merge_chunks(output, num_chunks):
    """合并分块文件"""
    with open(output, "wb") as out_f:
        for i in range(num_chunks):
            part = f"{output}.part{i}"
            if os.path.exists(part):
                with open(part, "rb") as in_f:
                    while True:
                        data = in_f.read(65536)
                        if not data:
                            break
                        out_f.write(data)
                os.remove(part)


def cleanup_parts(output, num_chunks):
    """清理分块文件"""
    for i in range(num_chunks):
        part = f"{output}.part{i}"
        if os.path.exists(part):
            os.remove(part)


def main():
    if len(sys.argv) < 3:
        sys.stderr.write("用法: python3 download-axel.py <url> <output> [threads]\n")
        sys.exit(1)

    url = sys.argv[1]
    output = sys.argv[2]
    num_threads = int(sys.argv[3]) if len(sys.argv) > 3 else DEFAULT_THREADS

    sys.stderr.write(f"  获取文件信息...\n")

    # 获取文件大小
    file_size, support_range = get_file_size(url)

    # 根据文件大小调整线程数
    if not support_range or file_size <= 0:
        num_threads = 1
    elif file_size < 512 * 1024:
        num_threads = 1
    elif file_size < 2 * 1024 * 1024:
        num_threads = min(num_threads, 2)
    elif file_size < 10 * 1024 * 1024:
        num_threads = min(num_threads, 4)
    elif file_size < 50 * 1024 * 1024:
        num_threads = min(num_threads, 8)
    else:
        num_threads = min(num_threads, 16)

    sys.stderr.write(
        f"  文件大小: {format_size(file_size) if file_size > 0 else '未知'}, "
        f"线程数: {num_threads}, "
        f"断点续传: {'是' if support_range else '否'}\n"
    )

    # 清理旧分块
    cleanup_parts(output, 32)

    # 创建状态
    state = DownloadState()
    state.total_size = file_size

    # 规划分块
    chunks = []
    if num_threads == 1:
        chunks.append((0, 0))  # 0 表示到文件末尾
    else:
        chunk_size = math.ceil(file_size / num_threads)
        for i in range(num_threads):
            start = i * chunk_size
            end = min((i + 1) * chunk_size - 1, file_size - 1)
            chunks.append((start, end))

    # 启动进度线程
    progress_thread = threading.Thread(
        target=progress_printer,
        args=(state, file_size, num_threads),
        daemon=True
    )
    progress_thread.start()

    # 启动下载线程
    start_time = time.time()
    threads = []
    for i, (start, end) in enumerate(chunks):
        t = threading.Thread(
            target=download_chunk,
            args=(url, output, start, end, i, state)
        )
        t.daemon = True
        t.start()
        threads.append(t)

    # 等待完成
    for t in threads:
        t.join(timeout=600)

    state.finished = True
    time.sleep(0.5)

    # 检查结果
    failed = []
    with state.lock:
        for i in range(num_threads):
            if i not in state.chunk_done:
                failed.append(i)
            elif not state.chunk_done[i]:
                failed.append(i)

    if failed:
        sys.stderr.write(f"  ✗ {len(failed)} 个分块下载失败\n")
        for i in failed:
            err = state.chunk_error.get(i, "未知错误")
            sys.stderr.write(f"    分块{i}: {err}\n")
        cleanup_parts(output, num_threads)
        sys.exit(1)

    # 合并分块
    if num_threads > 1:
        sys.stderr.write(f"  合并 {num_threads} 个分块...\n")
        merge_chunks(output, num_threads)
    else:
        part = f"{output}.part0"
        if os.path.exists(part):
            os.rename(part, output)

    # 验证
    if os.path.exists(output):
        actual = os.path.getsize(output)
        elapsed = time.time() - start_time
        speed = actual / elapsed if elapsed > 0 else 0

        if file_size > 0 and actual < file_size * 0.99:
            sys.stderr.write(
                f"  ⚠ 文件不完整: {format_size(actual)} vs {format_size(file_size)}\n"
            )
            sys.exit(1)

        sys.stderr.write(
            f"  ✓ 下载完成: {format_size(actual)} "
            f"耗时 {format_time(elapsed)} "
            f"平均 {format_speed(speed)}\n"
        )
        sys.exit(0)
    else:
        sys.stderr.write(f"  ✗ 文件不存在\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
