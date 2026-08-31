<#
===============================================================================
 离线安装包生成工具（在联网的机器上运行一次）
===============================================================================
 生成仓库 offline/ 目录（绿色快照），包含：
   - Node.js 便携版（从官方 zip 解压）
   - npm 全局包（@deepseek-ai/dsh、@deepseek-harness-tui/dsh-tui、pnpm 及全部依赖）
   - dsh-tui profile（含 node_modules）
   - manifest.json（版本 + 文件数/字节数清单，安装时做完整性校验）

 用途：把生成的 offline/ 目录连同仓库一次性拷贝到无网电脑，即可完全离线安装。
 注意：
   - 必须在已安装好 dsh / dsh-tui / pnpm（npm 全局）的机器上运行；
   - 生成的 offline/ 约 500 MB，被 .gitignore 忽略，不会提交到仓库。

 用法：
   powershell -ExecutionPolicy Bypass -File tools\build-offline-package.ps1           # 生成到仓库 offline/
   powershell -ExecutionPolicy Bypass -File tools\build-offline-package.ps1 -NodeZip D:\node-v22.23.2-win-x64.zip
   powershell -ExecutionPolicy Bypass -File tools\build-offline-package.ps1 -Out C:\offline-out
===============================================================================
#>
[CmdletBinding()]
param(
    [string]$NodeZip = '',      # 已有 Node zip 时传入（跳过下载）；留空自动下载 v22 LTS
    [string]$Out = ''           # 输出目录；留空 = 仓库 offline/
)

$ErrorActionPreference = 'Stop'

# ---- 基础 -----
$RepoRoot = Split-Path $PSScriptRoot -Parent
$OfflineRoot = if ($Out -ne '') { $Out } else { Join-Path $RepoRoot 'offline' }
$NpmRoot = Join-Path $env:APPDATA 'npm'

# robocopy 帮助类：退出码 <8 视为成功
function Invoke-Robocopy {
    param([string]$Src, [string]$Dst, [string[]]$ExcludeFiles = @())
    if (-not (Test-Path $Src)) { throw "源目录不存在：$Src" }
    $argsList = @($Src, $Dst, '/E', '/COPY:DAT', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NP')
    if ($ExcludeFiles.Count -gt 0) {
        $argsList += @('/XF') + $ExcludeFiles
    }
    $p = Start-Process -FilePath 'robocopy.exe' -ArgumentList $argsList -Wait -PassThru -WindowStyle Hidden
    if ($p.ExitCode -ge 8) { throw "robocopy 失败（退出码 $($p.ExitCode)）：$Src -> $Dst" }
}

# 删除目录（长路径安全）
function Remove-Tree {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    $isFile = Test-Path $Path -PathType Leaf
    $cmd = if ($isFile) { 'del' } else { 'rmdir' }
    if ($isFile) {
        $p = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $cmd, '/f', '/s', '/q', "`"\\?\$Path`"") -Wait -PassThru -WindowStyle Hidden
    } else {
        $p = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $cmd, '/s', '/q', "`"\\?\$Path`"") -Wait -PassThru -WindowStyle Hidden
    }
    if ($p.ExitCode -ne 0) { throw "删除失败（退出码 $($p.ExitCode)）：$Path" }
}

function Get-TreeStats {
    param([string]$Path)
    $files = Get-ChildItem $Path -Recurse -File -ErrorAction SilentlyContinue
    $count = @($files).Count
    $size = [int64](($files | Measure-Object Length -Sum).Sum)
    return @{ count = $count; size = $size }
}

# ---- 1) Node.js 便携版 ----
Write-Host '== 1/4 Node.js 便携版 =='
$nodeDir = Join-Path $OfflineRoot 'node'
Remove-Tree $nodeDir
if ($NodeZip -ne '') {
    Write-Host "使用指定压缩包：$NodeZip"
} else {
    $ts = Get-Date -UFormat %s
    $index = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -TimeoutSec 30
    $pick = $index | Where-Object { $_.version -match '^v22\.' } | Select-Object -First 1
    if (-not $pick) { throw '未找到 Node v22 LTS' }
    $ver = $pick.version
    $NodeZip = Join-Path $env:TEMP "node-$ver-win-x64.zip"
    Write-Host "下载 $ver ..."
    Invoke-WebRequest -Uri "https://nodejs.org/dist/$ver/node-$ver-win-x64.zip" -OutFile $NodeZip -UseBasicParsing -TimeoutSec 300
}
$extract = Join-Path $env:TEMP ("node-extract-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $extract | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($NodeZip, $extract)
$inner = Get-ChildItem $extract -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'node.exe') } | Select-Object -First 1
if (-not $inner) { throw '压缩包内未找到 node.exe' }
New-Item -ItemType Directory -Force -Path (Split-Path $nodeDir -Parent) | Out-Null
Move-Item $inner.FullName $nodeDir
Remove-Tree $extract
$nodeVer = (& (Join-Path $nodeDir 'node.exe') --version).Trim()
Write-Host "Node $nodeVer 就绪"

# ---- 2) npm 全局包 ----
Write-Host '== 2/4 npm 全局包 =='
$gn = Join-Path $OfflineRoot 'global-npm'
Remove-Tree $gn
New-Item -ItemType Directory -Force -Path (Join-Path $gn 'node_modules') | Out-Null
foreach ($pkg in @('@deepseek-ai\dsh', '@deepseek-harness-tui\dsh-tui', 'pnpm')) {
    $src = Join-Path $NpmRoot "node_modules\$pkg"
    if (-not (Test-Path (Join-Path $src 'package.json'))) { throw "本机未安装 $pkg（请先 npm install -g @deepseek-ai/dsh @deepseek-harness-tui/dsh-tui pnpm）" }
    Invoke-Robocopy -Src $src -Dst (Join-Path $gn "node_modules\$pkg")
}
foreach ($name in @('dsh', 'dsh-tui', 'pnpm')) {
    foreach ($ext in @('.cmd', '.ps1', '')) {
        $f = Join-Path $NpmRoot ($name + $ext)
        if (Test-Path $f) { Copy-Item $f $gn -Force }
    }
}

# ---- 3) dsh-tui profile ----
Write-Host '== 3/4 dsh-tui profile =='
$dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HOME '.dsh' }
$srcProf = Join-Path $dshHome 'profiles\dsh-tui'
if (-not (Test-Path (Join-Path $srcProf 'package.json'))) {
    throw "本机没有 dsh-tui profile（$srcProf）。请先运行 install.ps1 或 dsh plugin --profile dsh-tui add @deepseek-harness-tui/dsh-tui"
}
$dstProf = Join-Path $OfflineRoot 'profile\dsh-tui'
Remove-Tree $dstProf
New-Item -ItemType Directory -Force -Path $dstProf | Out-Null
# 只复制快照必要文件（不含用户覆盖层 cordis.patch.yml 等）
foreach ($f in @('package.json', 'pnpm-lock.yaml', 'pnpm-workspace.yaml')) {
    $s = Join-Path $srcProf $f
    if (Test-Path $s) { Copy-Item $s $dstProf -Force }
}
Invoke-Robocopy -Src (Join-Path $srcProf 'node_modules') -Dst (Join-Path $dstProf 'node_modules')

# ---- 4) manifest ----
Write-Host '== 4/4 manifest =='
$stats = @{}
foreach ($sec in @('node', 'global-npm', 'profile')) {
    $stats[$sec] = Get-TreeStats (Join-Path $OfflineRoot $sec)
}
$dshPkg = Get-Content (Join-Path $NpmRoot 'node_modules\@deepseek-ai\dsh\package.json') -Raw | ConvertFrom-Json
$tuiPkg = Get-Content (Join-Path $NpmRoot 'node_modules\@deepseek-harness-tui\dsh-tui\package.json') -Raw | ConvertFrom-Json
$pnpmPkg = Get-Content (Join-Path $NpmRoot 'node_modules\pnpm\package.json') -Raw | ConvertFrom-Json
$manifest = [ordered]@{
    format   = 1
    node     = $nodeVer
    packages = [ordered]@{
        '@deepseek-harness-tui/dsh-tui' = $tuiPkg.version
        '@deepseek-ai/dsh'              = $dshPkg.version
        'pnpm'                          = $pnpmPkg.version
    }
    platform = 'win32-x64'
    built    = (Get-Date -Format 'yyyy-MM-dd')
    files    = [ordered]@{
        'node'       = [ordered]@{ count = $stats.node.count; size = $stats.node.size }
        'global-npm' = [ordered]@{ count = $stats.'global-npm'.count; size = $stats.'global-npm'.size }
        'profile'    = [ordered]@{ count = $stats.profile.count; size = $stats.profile.size }
    }
}
$manifestPath = Join-Path $OfflineRoot 'manifest.json'
$manifest | ConvertTo-Json -Depth 5 | Set-Content $manifestPath -Encoding UTF8

$total = (Get-ChildItem $OfflineRoot -Recurse -File | Measure-Object Length -Sum).Sum
Write-Host ''
Write-Host "完成：$OfflineRoot"
Write-Host ("  文件数：{0:N0}    总大小：{1:N1} MB" -f ((Get-ChildItem $OfflineRoot -Recurse -File).Count), ($total/1MB))
Write-Host "  把整个 $OfflineRoot 目录连同仓库主文件拷贝到无网电脑即可完全离线安装。"
