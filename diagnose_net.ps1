#requires -Version 5.1
<#
.SYNOPSIS
    校园网环境 GitHub 连接诊断脚本（只读）
.DESCRIPTION
    检查五项：git 代理配置残留、hosts 覆写、DNS 解析真伪、
    api.github.com 与 github.com 连通性对比、TCP 握手。
    不修改任何系统设置、不写入文件。判读逻辑见 README「30 秒诊断三件套」。
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File diagnose_net.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"

$KnownGitHubPrefixes = @("140.82.", "20.205.", "20.27.", "143.55.", "192.30.")

function Write-Section {
    param([string]$t)
    Write-Host ""
    Write-Host "=== $t ===" -ForegroundColor Cyan
}

function Write-OK {
    param([string]$m)
    Write-Host "[OK] $m" -ForegroundColor Green
}

function Write-Bad {
    param([string]$m)
    Write-Host "[!!] $m" -ForegroundColor Yellow
}

function Write-Info {
    param([string]$m)
    Write-Host "[--] $m" -ForegroundColor Gray
}

Write-Section "1. git 代理配置残留"

$gitCmd = Get-Command git -ErrorAction SilentlyContinue
if (-not $gitCmd) {
    Write-Info "未找到 git，跳过本项"
}
else {
    $httpProxy = git config --global --get http.proxy
    $httpsProxy = git config --global --get https.proxy
    if ($httpProxy -or $httpsProxy) {
        Write-Bad "git 配置了代理: http=$httpProxy https=$httpsProxy"
        Write-Info "若代理客户端未在运行，这就是连不上的原因。取消配置："
        Write-Info "  git config --global --unset http.proxy"
        Write-Info "  git config --global --unset https.proxy"
    }
    else {
        Write-OK "git 未配置代理（直连模式）"
    }
}

Write-Section "2. hosts 文件是否覆写 GitHub"

$hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
$hits = Select-String -Path $hostsPath -Pattern "github" -SimpleMatch
if ($hits) {
    Write-Info "hosts 中存在 GitHub 相关条目（过期条目反而会导致连不上）："
    foreach ($h in $hits) {
        Write-Info ("  " + $h.Line.Trim())
    }
    Write-Info "清理后执行: ipconfig /flushdns"
}
else {
    Write-OK "hosts 未覆写 GitHub（无过期条目风险）"
}

Write-Section "3. DNS 解析真伪"

$dnsRecords = Resolve-DnsName github.com -Type A -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress }
if ($dnsRecords) {
    foreach ($d in $dnsRecords) {
        $ip = $d.IPAddress
        $isKnown = ($KnownGitHubPrefixes | Where-Object { $ip -like "$_*" }) -ne $null
        if ($isKnown) {
            Write-OK "github.com -> $ip（GitHub 真实 IP 段，DNS 无污染）"
        }
        else {
            Write-Bad "github.com -> $ip（非 GitHub 常见段，疑似 DNS 污染）"
        }
    }
}
else {
    Write-Bad "DNS 解析失败：先确认基础网络（校园网 Portal 认证是否过期）"
}

Write-Section "4. HTTPS 连通性对比（api 与主站）"

$apiCode = 0
$wwwCode = 0
try {
    $r = Invoke-WebRequest -Uri "https://api.github.com" -TimeoutSec 10 -UseBasicParsing
    $apiCode = $r.StatusCode
}
catch {
    $apiCode = 0
}
try {
    $r = Invoke-WebRequest -Uri "https://github.com" -TimeoutSec 10 -UseBasicParsing
    $wwwCode = $r.StatusCode
}
catch {
    $wwwCode = 0
}

if ($apiCode -gt 0) { Write-Info "api.github.com -> $apiCode" } else { Write-Info "api.github.com -> 失败" }
if ($wwwCode -gt 0) { Write-Info "github.com     -> $wwwCode" } else { Write-Info "github.com     -> 失败" }

if ($apiCode -eq 200 -and $wwwCode -eq 200) {
    Write-OK "两者都通：网络层正常。若 git 仍失败，检查第 1 步的代理残留或安全软件"
}
elseif ($apiCode -eq 200 -and $wwwCode -eq 0) {
    Write-Bad "api 通、主站不通：出口对 github.com 做 TCP 级封锁（静默丢包）"
    Write-Info "对策：手机热点直连，或 git 配置本地代理（需代理客户端在运行）"
}
elseif ($apiCode -eq 0 -and $wwwCode -eq 0) {
    Write-Bad "两者都不通：整体断网或 Portal 认证过期，先恢复基础上网"
}
else {
    Write-Info "其他组合：主站通而 api 不通较罕见，可重试一次排除偶发"
}

Write-Section "5. TCP 握手（github.com:443）"

$tcp = New-Object System.Net.Sockets.TcpClient
try {
    $async = $tcp.BeginConnect("github.com", 443, $null, $null)
    $finished = $async.AsyncWaitHandle.WaitOne(10000)
    if ($finished -and $tcp.Connected) {
        Write-OK "443 端口握手成功"
    }
    else {
        Write-Bad "443 端口握手失败（SYN 被丢弃或路由不通）——与 git push 超时互相印证"
    }
}
catch {
    Write-Bad "443 端口握手失败：$($_.Exception.Message)"
}
finally {
    $tcp.Close()
}

Write-Section "结论速查"

Write-Host @"
  DNS 污染        -> 改 hosts 或换 DNS（README 方案 3）
  api 通/主站不通 -> 手机热点 或 git 配置本地代理（README 方案 1/2）
  全部不通        -> 先恢复基础上网（Portal 认证）
  网络通 git 仍败 -> 查 git 代理残留（第 1 步）与安全软件
"@
