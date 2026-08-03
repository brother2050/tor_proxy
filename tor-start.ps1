# tor-start.ps1 - Tor Proxy for Windows (PowerShell)
# ==================================================
# 用法:
#   .\tor-start.ps1 start     # 启动
#   .\tor-start.ps1 stop      # 停止
#   .\tor-start.ps1 status    # 状态
#   .\tor-start.ps1 setup     # 下载 Windows Tor

param(
    [Parameter(Position=0)]
    [ValidateSet("start","stop","restart","status","setup","fresh")]
    [string]$Action = "start"
)

$ErrorActionPreference = "Stop"
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path

# 平台检测
$PLATFORM = "windows-x86_64"
$BIN_DIR = Join-Path $SCRIPT_DIR "bin\$PLATFORM"

# 查找二进制
$TOR_BIN = $null
$OBFS4PROXY = $null

$torPath = Join-Path $BIN_DIR "tor.exe"
if (Test-Path $torPath) { $TOR_BIN = $torPath }

$obfs4Path = Join-Path $BIN_DIR "obfs4proxy.exe"
if (Test-Path $obfs4Path) { $OBFS4PROXY = $obfs4Path }

# 也检查根目录
if (-not $TOR_BIN) {
    $torRoot = Join-Path $SCRIPT_DIR "tor.exe"
    if (Test-Path $torRoot) { $TOR_BIN = $torRoot }
}
if (-not $OBFS4PROXY) {
    $obfs4Root = Join-Path $SCRIPT_DIR "obfs4proxy.exe"
    if (Test-Path $obfs4Root) { $OBFS4PROXY = $obfs4Root }
}

$DATA_DIR = Join-Path $SCRIPT_DIR "data"
$LOGS_DIR = Join-Path $SCRIPT_DIR "logs"
$CACHE_DIR = Join-Path $SCRIPT_DIR "cache\descriptors"
$CONFIG_TEMPLATE = Join-Path $SCRIPT_DIR "config\torrc.template"
$CONFIG = Join-Path $SCRIPT_DIR "config\torrc"
$PID_FILE = Join-Path $DATA_DIR "tor.pid"
$SOCKS_PORT = 9050

function Write-Log($msg) { Write-Host "[tor] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "[tor] $msg" -ForegroundColor Yellow }

# 从模板生成配置
function New-Config {
    if (-not (Test-Path $CONFIG_TEMPLATE)) {
        Write-Warn "Template not found: $CONFIG_TEMPLATE"
        return $false
    }
    $content = Get-Content $CONFIG_TEMPLATE -Raw
    $content = $content -replace "__DIR__", ($SCRIPT_DIR -replace '\\', '/')
    $content = $content -replace "__OBFS4PROXY__", ($OBFS4PROXY -replace '\\', '/')
    Set-Content -Path $CONFIG -Value $content
    return $true
}

# 部署缓存
function Install-Cache {
    if (-not (Test-Path "$CACHE_DIR\cached-microdesc-consensus")) {
        Write-Warn "No pre-cached descriptors"
        return
    }
    New-Item -ItemType Directory -Force -Path $DATA_DIR | Out-Null
    Copy-Item "$CACHE_DIR\cached-certs" $DATA_DIR -ErrorAction SilentlyContinue
    Copy-Item "$CACHE_DIR\cached-microdesc-consensus" $DATA_DIR -ErrorAction SilentlyContinue
    Copy-Item "$CACHE_DIR\cached-microdescs" $DATA_DIR -ErrorAction SilentlyContinue
    Write-Log "Cache deployed - boot should be fast (~45s)"
}

# 同步缓存
function Sync-Cache {
    New-Item -ItemType Directory -Force -Path $CACHE_DIR | Out-Null
    foreach ($f in @("cached-certs","cached-microdesc-consensus","cached-microdescs")) {
        $src = Join-Path $DATA_DIR $f
        if (Test-Path $src) { Copy-Item $src $CACHE_DIR -ErrorAction SilentlyContinue }
    }
}

# 检查运行状态
function Test-Running {
    if (Test-Path $PID_FILE) {
        $pid = Get-Content $PID_FILE -ErrorAction SilentlyContinue
        if ($pid) {
            $proc = Get-Process -Id $pid -ErrorAction SilentlyContinue
            if ($proc) { return $true }
        }
    }
    return $false
}

# 启动
function Start-Tor {
    if (Test-Running) {
        Write-Log "Already running"
        return
    }

    if (-not $TOR_BIN) {
        Write-Host "Tor not found for $PLATFORM" -ForegroundColor Red
        Write-Host "Run: .\tor-start.ps1 setup" -ForegroundColor Yellow
        return
    }

    if (-not $OBFS4PROXY) {
        Write-Warn "obfs4proxy not found - Snowflake may not work"
    }

    New-Config | Out-Null
    New-Item -ItemType Directory -Force -Path $DATA_DIR, $LOGS_DIR | Out-Null

    # 部署缓存
    if (-not (Test-Path "$DATA_DIR\cached-microdesc-consensus")) {
        Install-Cache
    }

    Write-Log "Starting Tor ($PLATFORM)..."

    $logFile = Join-Path $LOGS_DIR "tor.log"
    $proc = Start-Process -FilePath $TOR_BIN -ArgumentList "-f", $CONFIG `
        -RedirectStandardOutput (Join-Path $LOGS_DIR "startup.log") `
        -RedirectStandardError (Join-Path $LOGS_DIR "stderr.log") `
        -NoNewWindow -PassThru

    Set-Content -Path $PID_FILE -Value $proc.Id
    Write-Log "PID: $($proc.Id)"

    # 等待引导
    Write-Host "Waiting for bootstrap..." -NoNewline
    for ($i = 0; $i -lt 300; $i++) {
        Start-Sleep -Seconds 2
        if (-not (Test-Running)) {
            Write-Host ""
            Write-Warn "Tor died! Check logs"
            return
        }
        if (Test-Path $logFile) {
            $last = Get-Content $logFile | Select-String "Bootstrapped (\d+)%" | Select-Object -Last 1
            if ($last -match "Bootstrapped (\d+)%") {
                $pct = [int]$Matches[1]
                Write-Host "`r  Bootstrap: $pct%" -NoNewline
                if ($pct -eq 100) {
                    Write-Host ""
                    Write-Log "✓ Proxy ready! SOCKS5: 127.0.0.1:$SOCKS_PORT"
                    Sync-Cache
                    return
                }
            }
        }
    }
    Write-Host ""
    Write-Warn "Bootstrap timeout"
}

# 停止
function Stop-Tor {
    if (Test-Path $PID_FILE) {
        $pid = Get-Content $PID_FILE -ErrorAction SilentlyContinue
        if ($pid) {
            $proc = Get-Process -Id $pid -ErrorAction SilentlyContinue
            if ($proc) {
                Write-Log "Stopping Tor (PID: $pid)..."
                Sync-Cache
                Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
                Write-Log "Stopped"
            }
        }
        Remove-Item $PID_FILE -ErrorAction SilentlyContinue
    } else {
        Write-Warn "Not running"
    }
}

# 状态
function Get-Status {
    Write-Host "Platform: $PLATFORM"
    Write-Host "Tor: $(if ($TOR_BIN) { $TOR_BIN } else { 'NOT FOUND' })"
    Write-Host "obfs4proxy: $(if ($OBFS4PROXY) { $OBFS4PROXY } else { 'NOT FOUND' })"
    Write-Host ""

    if (Test-Running) {
        Write-Log "Running (PID: $(Get-Content $PID_FILE))"
        if (Test-Path "$LOGS_DIR\tor.log") {
            Get-Content "$LOGS_DIR\tor.log" | Select-String "Bootstrapped" | Select-Object -Last 1
        }
    } else {
        Write-Warn "Not running"
    }

    Write-Host ""
    if (Test-Path "$CACHE_DIR\cached-microdesc-consensus") {
        $size = (Get-ChildItem $CACHE_DIR -Recurse | Measure-Object -Property Length -Sum).Sum / 1MB
        Write-Host "Cache: $([math]::Round($size))MB"
    } else {
        Write-Host "No cache"
    }
}

# 下载 Windows Tor
function Install-Tor {
    if ($TOR_BIN) {
        Write-Log "Tor already exists: $TOR_BIN"
        return
    }

    Write-Log "Downloading Tor for Windows..."
    New-Item -ItemType Directory -Force -Path $BIN_DIR | Out-Null

    $versions = @("14.5", "14.0", "13.5")
    foreach ($ver in $versions) {
        $urls = @(
            "https://dist.torproject.org/torbrowser/$ver/tor-expert-bundle-windows-x86_64-$ver.tar.gz",
            "https://dist.torproject.org/torbrowser/$ver/tor-expert-bundle-windows-i686-$ver.tar.gz"
        )
        foreach ($url in $urls) {
            $tmpFile = Join-Path $env:TEMP "tor-windows-$ver.tar.gz"
            Write-Host "  Trying v$ver..." -NoNewline
            try {
                Invoke-WebRequest -Uri $url -OutFile $tmpFile -UseBasicParsing -TimeoutSec 120
                if ((Get-Item $tmpFile).Length -gt 1000) {
                    Write-Host " OK" -ForegroundColor Green
                    Write-Host "  Extracting..."
                    # tar on Windows 10+ can extract tar.gz
                    $extDir = Join-Path $env:TEMP "tor-extract"
                    New-Item -ItemType Directory -Force -Path $extDir | Out-Null
                    tar xzf $tmpFile -C $extDir 2>$null
                    $torBin = Get-ChildItem -Path $extDir -Filter "tor.exe" -Recurse | Select-Object -First 1
                    if ($torBin) {
                        Copy-Item $torBin.FullName "$BIN_DIR\tor.exe"
                        # Copy obfs4proxy if found
                        $obfs4Bin = Get-ChildItem -Path $extDir -Filter "obfs4proxy.exe" -Recurse | Select-Object -First 1
                        if ($obfs4Bin) { Copy-Item $obfs4Bin.FullName "$BIN_DIR\obfs4proxy.exe" }
                        Remove-Item $extDir -Recurse -Force -ErrorAction SilentlyContinue
                        Remove-Item $tmpFile -ErrorAction SilentlyContinue
                        Write-Log "✓ Tor v$ver installed"
                        return
                    }
                    Remove-Item $extDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            } catch {
                Write-Host " Failed" -ForegroundColor Red
            }
            Remove-Item $tmpFile -ErrorAction SilentlyContinue
        }
    }

    Write-Host "Failed to download Tor" -ForegroundColor Red
    Write-Host "Download manually from: https://www.torproject.org/download/tor/"
    Write-Host "Place tor.exe in: $BIN_DIR"
}

# 主逻辑
switch ($Action) {
    "start"   { Start-Tor }
    "stop"    { Stop-Tor }
    "restart" { Stop-Tor; Start-Sleep -Seconds 2; Start-Tor }
    "status"  { Get-Status }
    "setup"   { Install-Tor }
    "fresh"   {
        Stop-Tor
        Remove-Item "$DATA_DIR\*" -Recurse -Force -ErrorAction SilentlyContinue
        Start-Tor
    }
}
