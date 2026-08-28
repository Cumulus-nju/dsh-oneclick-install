<#
================================================================================
 DeepSeek Harness TUI 一键安装 / 配置脚本
--------------------------------------------------------------------------------
 对应 DeepSeek Harness 官方连接 DeepSeek API 的现有方式（TUI 版）：
   1. 检查 Node.js（要求 ^22.19 || >=24；缺失/过旧则自动安装最新 LTS 便携版）
   2. npm 全局安装 @deepseek-ai/dsh（官方 Harness CLI）与
      @deepseek-harness-tui/dsh-tui（官方公众号收录的 TUI 前端，v0.9+ 低资源占用）
   3. 检查 pnpm（>=10，dsh plugin 安装 profile 依赖需要）
   4. dsh plugin --profile dsh-tui add @deepseek-harness-tui/dsh-tui@latest
      （创建 dsh-tui profile；dsh-tui 命令 = dsh --profile dsh-tui）
   5. 用你填写的 API Key 调用 DeepSeek API 校验连通性
   6. 写入凭证 $DSH_HOME/.credentials.yaml 的 DEEPSEEK_API_KEY
      （dsh-llm-deepseek 每次请求实时解析，改完立即生效，无需重启）
   7. 可选写入 $DSH_HOME/settings.yaml 的 llm-deepseek 段（baseURL / 推理强度）
   8. 流畅模式：向 $DSH_HOME/profiles/dsh-tui/cordis.patch.yml 写入性能优化覆盖层
      （工作状态行刷新 500ms -> 1500ms、轻量动画帧，减少卡顿）
   9. 复制启动器、创建桌面快捷方式、启动 TUI

 用法：
   install.bat                     双击（图形窗口，填写 API Key 后一键安装）
   powershell -File install.ps1 -Headless -ApiKey sk-xxx ...  命令行模式
================================================================================
#>
[CmdletBinding()]
param(
    [switch]$Headless,          # 无图形窗口，日志输出到控制台
    [switch]$ConfigureOnly,     # 仅写入配置（不安装 Node/dsh/TUI、不建快捷方式）
    [string]$ApiKey = "",       # Headless 模式必须提供
    [string]$BaseUrl = "https://api.deepseek.com",
    [string]$ReasoningEffort = "",   # off|low|high|max；留空则不改动默认值
    [string]$Model = "",         # 默认模型：留空=deepseek-v4-flash；可填任意模型名
    [switch]$NoShortcut,        # 不创建桌面快捷方式
    [switch]$NoLaunch,          # 安装完成后不自动启动 TUI
    [switch]$SkipNodeCheck,     # 跳过 Node.js 检测/安装
    [switch]$SkipNpmInstall,    # 跳过 npm 全局安装
    [switch]$SkipTuiSetup,      # 跳过 pnpm 检查与 profile 安装（调试用）
    [switch]$NoValidate,        # 跳过 API Key 在线校验
    [bool]$SmoothMode = $true,  # 流畅模式：写入性能优化覆盖层
    [string]$DshHome = ""       # 覆盖 DSH 家目录（默认 $env:DSH_HOME 或 ~/.dsh）
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# Windows PowerShell 5.1 默认 TLS 1.0，https 请求会失败；显式启用 TLS 1.2
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

$PROFILE_NAME = 'dsh-tui'
$TUI_PACKAGE = '@deepseek-harness-tui/dsh-tui'
$DEFAULT_BASE_URL = 'https://api.deepseek.com'

#region 基础工具
function Get-DshHome {
    if ($DshHome -ne "") { return $DshHome.TrimEnd('\') }
    if ($env:DSH_HOME -and $env:DSH_HOME.Trim() -ne "") { return $env:DSH_HOME.TrimEnd('\') }
    return Join-Path $HOME '.dsh'
}

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message
    if ($script:LogSink) { & $script:LogSink $line } else { Write-Host $line }
}
$script:LogSink = $null

# 包装原生命令调用：EAP=Stop 时 stderr 会抛 NativeCommandError，这里临时降级
function Invoke-Native {
    param([scriptblock]$Body)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Body } finally { $ErrorActionPreference = $prevEap }
}

# 解析 npm 全局命令（dsh / pnpm / npm / dsh-tui），优先 %APPDATA%\npm 下的 .cmd
function Resolve-CmdShim {
    param([string]$Name)
    $candidates = @(
        (Join-Path $env:APPDATA "npm\$Name.cmd"),
        (Join-Path $env:LOCALAPPDATA "Programs\node\$Name.cmd")
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    $g = Get-Command "$Name.cmd" -ErrorAction SilentlyContinue
    if ($g) { return $g.Source }
    return ""
}

function Resolve-NodeInfo {
    $info = @{ Found = $false; NodeDir = ''; NodeMajor = 0; NodeMinor = 0; NpmCmd = '' }
    $nodeCmd = Get-Command node.exe -ErrorAction SilentlyContinue
    if (-not $nodeCmd) { $nodeCmd = Get-Command node -ErrorAction SilentlyContinue }
    if ($nodeCmd) {
        $nodePath = $nodeCmd.Source
        $verLine = & $nodePath --version 2>$null
        if ($verLine -match 'v(\d+)\.(\d+)') {
            $info.Found = $true
            $info.NodeMajor = [int]$Matches[1]
            $info.NodeMinor = [int]$Matches[2]
            $info.NodeDir = Split-Path $nodePath -Parent
        }
    }
    if ($info.Found) {
        $npm = Resolve-CmdShim 'npm'
        if ($npm) { $info.NpmCmd = $npm }
        if (-not $info.NpmCmd -and (Test-Path (Join-Path $info.NodeDir 'npm.cmd'))) {
            $info.NpmCmd = Join-Path $info.NodeDir 'npm.cmd'
        }
    }
    return $info
}

# Node 版本是否满足 dsh-tui 的 engines：^22.19 || >=24
function Test-NodeSatisfies {
    param($Info)
    if (-not $Info.Found) { return $false }
    if ($Info.NodeMajor -gt 24) { return $true }
    if ($Info.NodeMajor -eq 24) { return $true }
    if ($Info.NodeMajor -eq 22) { return $Info.NodeMinor -ge 19 }
    return $false
}

function Add-ToUserPath {
    param([string]$Dir)
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $userPath) { $userPath = '' }
    if (($userPath -split ';') -notcontains $Dir) {
        $newPath = if ($userPath.Trim() -eq '') { $Dir } else { $userPath.TrimEnd(';') + ';' + $Dir }
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        Write-Log "已将 $Dir 加入用户 PATH"
        $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $env:Path = ($machine + ';' + [Environment]::GetEnvironmentVariable('Path', 'User'))
    }
}
#endregion

#region Node.js / pnpm / Harness 安装
function Install-Node {
    Write-Log '未检测到满足要求的 Node.js（需要 ^22.19 或 >=24），开始自动安装…'

    # 1) 仓库 tools/ 目录里的离线安装包
    $toolsDir = Join-Path $PSScriptRoot 'tools'
    if (Test-Path $toolsDir) {
        $zip = Get-ChildItem $toolsDir -Filter 'node*-win-x64.zip' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($zip) {
            Write-Log "发现离线安装包：$($zip.Name)，正在解压安装（免管理员权限）…"
            if (Expand-PortableNodeZip $zip.FullName) { return $true }
        }
        $msi = Get-ChildItem $toolsDir -Filter 'node*-x64.msi' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($msi) {
            Write-Log "发现离线安装包：$($msi.Name)，正在静默安装…"
            try {
                $p = Start-Process msiexec.exe -ArgumentList @('/i', "`"$($msi.FullName)`"", '/qn', '/norestart') -Wait -PassThru -ErrorAction Stop
                if ($p.ExitCode -eq 0) { Write-Log 'Node.js MSI 安装完成'; return $true }
                Write-Log "msiexec 退出码 $($p.ExitCode)，尝试其他方式…"
            } catch { Write-Log "MSI 安装失败：$($_.Exception.Message)" }
        }
    }

    # 2) 在线下载最新 LTS 便携版（免管理员，最稳妥）
    try {
        Write-Log '正在查询 Node.js 最新 LTS 版本…'
        $idx = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -TimeoutSec 30
        $latest = $idx | Where-Object { $_.lts } | Select-Object -First 1
        if ($latest) {
            $ver = $latest.version
            $url = "https://nodejs.org/dist/$ver/node-$ver-win-x64.zip"
            $tmp = Join-Path $env:TEMP "node-$ver-win-x64.zip"
            Write-Log "正在下载 Node.js $ver 便携版（约 30MB）…"
            Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 300
            if (Expand-PortableNodeZip $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue; return $true }
        }
    } catch { Write-Log "下载便携版失败：$($_.Exception.Message)" }

    # 3) winget 兜底
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($winget) {
        try {
            Write-Log '尝试通过 winget 安装 Node.js LTS…'
            Invoke-Native { & $winget.Source install --id OpenJS.NodeJS.LTS --silent --accept-package-agreements --accept-source-agreements 2>&1 } | ForEach-Object { Write-Log "winget: $_" }
            $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
            $env:Path = ($machine + ';' + [Environment]::GetEnvironmentVariable('Path', 'User'))
            $chk = Resolve-NodeInfo
            if ($chk.Found) { Write-Log 'Node.js 安装完成'; return $true }
        } catch { Write-Log "winget 安装失败：$($_.Exception.Message)" }
    }

    return $false
}

function Expand-PortableNodeZip {
    param([string]$ZipPath)
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $dest = Join-Path $env:LOCALAPPDATA 'Programs\node'
        $extract = Join-Path $env:TEMP ("node-extract-" + [guid]::NewGuid().ToString('N'))
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $extract)
        $inner = Get-ChildItem $extract -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'node.exe') } | Select-Object -First 1
        if (-not $inner) { Write-Log '压缩包内未找到 node.exe'; return $false }
        if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
        Move-Item $inner.FullName $dest
        Remove-Item $extract -Recurse -Force -ErrorAction SilentlyContinue
        $env:Path = "$dest;$env:Path"
        Add-ToUserPath $dest
        Write-Log "Node.js 便携版已安装到 $dest"
        return $true
    } catch {
        Write-Log "解压便携版失败：$($_.Exception.Message)"
        return $false
    }
}

function Install-HarnessPackages {
    $npmCmd = (Resolve-NodeInfo).NpmCmd
    if (-not $npmCmd) {
        $npmCmd = Resolve-CmdShim 'npm'
    }
    if (-not $npmCmd) { return $false }
    Write-Log '正在 npm 全局安装 @deepseek-ai/dsh 与 @deepseek-harness-tui/dsh-tui（首次约需下载 300MB，请耐心等待）…'
    $env:NPM_CONFIG_FUND = 'false'
    try {
        Invoke-Native { & $npmCmd install -g @deepseek-ai/dsh $TUI_PACKAGE --no-fund --no-audit 2>&1 } | ForEach-Object { Write-Log "npm: $_" }
        if ($LASTEXITCODE -ne 0) { return $false }
    } catch {
        Write-Log "npm 安装失败：$($_.Exception.Message)"
        return $false
    }
    Add-ToUserPath (Join-Path $env:APPDATA 'npm')
    return $true
}

function Ensure-Pnpm {
    $pnpm = Resolve-CmdShim 'pnpm'
    if ($pnpm) {
        $ver = (& $pnpm --version 2>$null)
        Write-Log "pnpm $ver 已就绪"
        if ($ver -and $ver -match '^(\d+)') {
            return ([int]$Matches[1] -ge 10)
        }
    }
    Write-Log '未检测到 pnpm（或版本过低，需要 >=10），正在安装…'
    $npmCmd = Resolve-CmdShim 'npm'
    if (-not $npmCmd) { return $false }
    try {
        Invoke-Native { & $npmCmd install -g pnpm@latest --no-fund --no-audit 2>&1 } | ForEach-Object { Write-Log "npm: $_" }
        return ($LASTEXITCODE -eq 0)
    } catch {
        Write-Log "pnpm 安装失败：$($_.Exception.Message)"
        return $false
    }
}

# pnpm 11 会因 ERR_PNPM_IGNORED_BUILDS（@google/genai、protobufjs 的构建脚本）
# 以非零退出码结束：把 profile 里 pnpm-workspace.yaml 的 allowBuilds 占位值
# 改为 false 后重试即可（上游文档的官方解法，忽略的脚本运行时用不到）。
function Fix-PnpmAllowBuilds {
    param([string]$WsFile)
    try {
        $lines = @(Get-Content $WsFile)
        $changed = $false
        $fixed = foreach ($l in $lines) {
            if ($l -match 'set this to true or false') {
                $changed = $true
                $l -replace 'set this to true or false', 'false'
            } else { $l }
        }
        if (($fixed -join "`n") -notmatch 'allowBuilds') {
            $fixed += @('allowBuilds:', "  '@google/genai': false", '  protobufjs: false')
            $changed = $true
        }
        if ($changed) {
            $enc = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllLines($WsFile, @($fixed), $enc)
            Write-Log '已修复 pnpm-workspace.yaml 的 allowBuilds（忽略无需运行的构建脚本）'
        }
    } catch {
        Write-Log "修复 pnpm-workspace.yaml 失败：$($_.Exception.Message)"
    }
}

function Install-TuiProfile {
    param([string]$DshHome)
    $dshCmd = Resolve-CmdShim 'dsh'
    if (-not $dshCmd) { Write-Log '未找到 dsh 命令'; return $false }
    Write-Log "正在创建 profile '$PROFILE_NAME' 并安装 $TUI_PACKAGE（首次需联网下载，请耐心等待）…"
    $wsFile = Join-Path $DshHome "profiles\$PROFILE_NAME\pnpm-workspace.yaml"
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        Invoke-Native { & $dshCmd plugin --profile $PROFILE_NAME add "$TUI_PACKAGE@latest" 2>&1 } | ForEach-Object { Write-Log "dsh: $_" }
        if ($LASTEXITCODE -eq 0) { break }
        Write-Log "dsh plugin 退出码 $LASTEXITCODE"
        if ($attempt -eq 0 -and (Test-Path $wsFile)) { Fix-PnpmAllowBuilds -WsFile $wsFile }
    }
    if ($LASTEXITCODE -ne 0) { return $false }
    # 校验 bundle 层已包含 TUI 包（pnpm 失败时 reconcile 不会执行）
    $pkgJson = Join-Path $DshHome "profiles\$PROFILE_NAME\package.json"
    if (Test-Path $pkgJson) {
        $m = Get-Content $pkgJson -Raw | ConvertFrom-Json
        if ($m.dsh.profile.bundles -contains $TUI_PACKAGE) { return $true }
        Write-Log "profile bundle 层缺少 $TUI_PACKAGE，尝试再次同步…"
        Invoke-Native { & $dshCmd plugin --profile $PROFILE_NAME add "$TUI_PACKAGE@latest" 2>&1 } | ForEach-Object { Write-Log "dsh: $_" }
        $m2 = Get-Content $pkgJson -Raw | ConvertFrom-Json
        if ($m2.dsh.profile.bundles -contains $TUI_PACKAGE) { return $true }
    }
    return $false
}
#endregion

#region 凭证 / 设置 / 优化覆盖层（YAML 保留式写入）
function Get-YamlScalar {
    param([string]$Value)
    if ($Value -match '^[A-Za-z0-9_\-\.\/:]+$') { return $Value }
    return "'" + ($Value -replace "'", "''") + "'"
}

function Write-YamlLines {
    param([string]$Path, [string[]]$Lines)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $enc = New-Object System.Text.UTF8Encoding($false)   # 无 BOM，兼容 yaml 解析
    [System.IO.File]::WriteAllLines($Path, $Lines, $enc)
}

function Set-CredentialEntry {
    param([string]$Path, [string]$Name, [string]$Value)
    $escaped = Get-YamlScalar $Value
    $lines = @()
    if (Test-Path $Path) { $lines = @(Get-Content $Path) }
    $found = $false
    $pat = '^\s*' + [regex]::Escape($Name) + '\s*:'
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $pat) {
            $indent = if ($lines[$i] -match '^(\s*)') { $Matches[1] } else { '' }
            $lines[$i] = $indent + $Name + ': ' + $escaped
            $found = $true
            break
        }
    }
    if (-not $found) { $lines += ($Name + ': ' + $escaped) }
    Write-YamlLines -Path $Path -Lines $lines
}

function Set-SettingsSection {
    param([string]$Path, [string]$Section, [hashtable]$Values, [string[]]$ManagedKeys = @())
    $lines = @()
    if (Test-Path $Path) { $lines = @(Get-Content $Path) }
    $secIdx = -1
    $secPat = '^' + [regex]::Escape($Section) + '\s*:\s*$'
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $secPat) { $secIdx = $i; break }
    }
    if ($secIdx -lt 0) {
        $lines += ($Section + ':')
        foreach ($k in $Values.Keys) { $lines += ('  ' + $k + ': ' + (Get-YamlScalar $Values[$k])) }
    } else {
        $end = $lines.Count
        for ($i = $secIdx + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\S') { $end = $i; break }
        }
        $block = @()
        if ($end - 1 -ge $secIdx + 1) { $block = @($lines[($secIdx + 1)..($end - 1)]) }
        foreach ($mk in $ManagedKeys) {
            if ($Values.Contains($mk)) { continue }
            $mkp = '^\s*' + [regex]::Escape($mk) + '\s*:'
            $block = @($block | Where-Object { $_ -notmatch $mkp })
        }
        foreach ($k in $Values.Keys) {
            $kp = '^\s*' + [regex]::Escape($k) + '\s*:'
            $hit = -1
            for ($j = 0; $j -lt $block.Count; $j++) {
                if ($block[$j] -match $kp) { $hit = $j; break }
            }
            if ($hit -ge 0) {
                $indent = if ($block[$hit] -match '^(\s*)') { $Matches[1] } else { '  ' }
                $block[$hit] = $indent + $k + ': ' + (Get-YamlScalar $Values[$k])
            } else {
                $block += ('  ' + $k + ': ' + (Get-YamlScalar $Values[$k]))
            }
        }
        $head = @()
        if ($secIdx -ge 0) { $head = @($lines[0..$secIdx]) }
        $tail = @()
        if ($end -lt $lines.Count) { $tail = @($lines[$end..($lines.Count - 1)]) }
        $lines = $head + $block + $tail
    }
    Write-YamlLines -Path $Path -Lines $lines
}

# 流畅模式优化覆盖层：$DSH_HOME/profiles/dsh-tui/cordis.patch.yml
#  - working-activity.publishIntervalMs: 500 -> 1500（工作状态行刷新率降为 ~0.7Hz）
#  - dsh-tui.activityFrames: claude -> dots（轻量动画帧）
# 已存在的用户覆盖层（无本脚本标记）不覆盖，尊重用户自定义。
function Write-PerfOverlay {
    param([string]$DshHome, [string]$Effort, [string]$Model)
    $patchPath = Join-Path $DshHome "profiles\$PROFILE_NAME\cordis.patch.yml"
    $dir = Split-Path $patchPath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    if (Test-Path $patchPath) {
        $existing = Get-Content $patchPath -Raw
        if ($existing -notmatch 'dsh-oneclick-install') {
            # 判断是否 profile 初始化的空模板（注释 + 空 []）：只有真实用户内容才跳过
            $body = ($existing -split "`n" | Where-Object {
                $t = $_.Trim(); $t -ne '' -and -not $t.StartsWith('#')
            }) -join "`n"
            if ($body.Trim() -ne '' -and $body.Trim() -ne '[]') {
                Write-Log "检测到已有自定义覆盖层 $patchPath，跳过流畅模式写入（尊重你的配置）"
                return $false
            }
        }
    }
    $effortLine = ''
    if ($Effort -in @('off', 'high', 'max')) { $effortLine = "    effort: $Effort" }
    $modelLine = ''
    if ($Model -match '^[A-Za-z0-9_\-\.:]+$') { $modelLine = "    model: $Model" }
    $lines = @(
        '# 由 dsh-oneclick-install 写入的性能优化覆盖层（流畅模式）',
        '# 降低工作状态行刷新率并使用轻量动画帧，减少终端重绘卡顿。',
        '# 删除本文件即可恢复默认（dsh-tui 包自带配置）。',
        '- id: working-activity',
        '  config:',
        '    publishIntervalMs: 1500',
        '- id: dsh-tui',
        '  config:',
        '    provider: deepseek-official'
    )
    if ($modelLine -ne '') { $lines += $modelLine }
    if ($effortLine -ne '') { $lines += $effortLine }
    $lines += @(
        '    activity: true',
        '    activityFrames: dots',
        '    contextBar: true',
        '    fullscreen: false'
    )
    Write-YamlLines -Path $patchPath -Lines $lines
    Write-Log "已写入流畅模式覆盖层：$patchPath"
    return $true
}
#endregion

#region API Key 校验
function Test-ApiKey {
    param([string]$Key, [string]$Base)
    $base = $Base.Trim().TrimEnd('/')
    if ($base -eq '') { $base = $DEFAULT_BASE_URL }
    $url = if ($base -match '/models$') { $base } else { $base + '/models' }
    $headers = @{ Authorization = "Bearer $Key" }
    try {
        $resp = Invoke-RestMethod -Uri $url -Headers $headers -Method Get -TimeoutSec 25 -ErrorAction Stop
        $count = @($resp.data).Count
        return @{ Ok = $true; Message = "连接成功！API Key 有效，可用模型 $count 个" }
    } catch {
        $status = ''
        $body = ''
        try {
            if ($_.Exception.Response) {
                $status = [string][int]$_.Exception.Response.StatusCode
                $stream = $_.Exception.Response.GetResponseStream()
                if ($stream) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    $body = $reader.ReadToEnd()
                }
            }
        } catch { }
        $msg = "连接失败（HTTP $status）"
        if ($body) {
            try {
                $j = $body | ConvertFrom-Json
                if ($j.error.message) { $msg += "：$($j.error.message)" }
            } catch { $msg += "：$($body.Substring(0, [Math]::Min(160, $body.Length)))" }
        }
        return @{ Ok = $false; Message = $msg }
    }
}
#endregion

#region 快捷方式 / 启动
function Install-Launchers {
    param([string]$DshHome)
    $launcherDir = Join-Path $DshHome 'launchers'
    if (-not (Test-Path $launcherDir)) { New-Item -ItemType Directory -Force -Path $launcherDir | Out-Null }
    $srcBat = Join-Path $PSScriptRoot 'launchers\dsh-tui.bat'
    if (Test-Path $srcBat) { Copy-Item $srcBat (Join-Path $launcherDir 'dsh-tui.bat') -Force }
    $srcIco = Join-Path $PSScriptRoot 'assets\deepseek.ico'
    if (Test-Path $srcIco) { Copy-Item $srcIco (Join-Path $launcherDir 'deepseek.ico') -Force }
    return (Join-Path $launcherDir 'dsh-tui.bat')
}

function New-DesktopShortcut {
    param([string]$DshHome)
    try {
        $ws = New-Object -ComObject WScript.Shell
        $desktop = [Environment]::GetFolderPath('Desktop')
        $lnkPath = Join-Path $desktop 'DeepSeek Harness TUI.lnk'
        $lnk = $ws.CreateShortcut($lnkPath)
        $lnk.TargetPath = Join-Path $DshHome 'launchers\dsh-tui.bat'
        $lnk.WorkingDirectory = $DshHome
        $lnk.Description = 'DeepSeek Harness 终端 TUI (dsh-tui)'
        $ico = Join-Path $DshHome 'launchers\deepseek.ico'
        if (Test-Path $ico) { $lnk.IconLocation = "$ico,0" }
        $lnk.Save()
        Write-Log "已创建桌面快捷方式：$lnkPath"
        return $true
    } catch {
        Write-Log "创建桌面快捷方式失败：$($_.Exception.Message)"
        return $false
    }
}

function Start-Tui {
    param([string]$LauncherBat)
    try {
        if (Test-Path $LauncherBat) {
            Start-Process -FilePath $LauncherBat -WorkingDirectory (Split-Path $LauncherBat -Parent)
        } else {
            Start-Process -FilePath 'cmd.exe' -ArgumentList @('/k', 'dsh-tui')
        }
        Write-Log '正在启动 DeepSeek Harness TUI…'
        return $true
    } catch {
        Write-Log "启动 TUI 失败：$($_.Exception.Message)"
        return $false
    }
}
#endregion

#region 安装主流程
function Invoke-InstallFlow {
    param(
        [string]$Key,
        [string]$Base,
        [string]$Effort,
        [string]$Model,
        [bool]$MakeShortcut,
        [bool]$Launch,
        [bool]$Smooth,
        [bool]$OnlyConfig
    )

    $dshHome = Get-DshHome
    $credsPath = Join-Path $dshHome '.credentials.yaml'
    $settingsPath = Join-Path $dshHome 'settings.yaml'
    $summary = @()

    # 1) Node.js
    if (-not $OnlyConfig -and -not $SkipNodeCheck) {
        $node = Resolve-NodeInfo
        if (-not $node.Found -or -not (Test-NodeSatisfies $node)) {
            if ($node.Found) {
                Write-Log "检测到 Node.js v$($node.NodeMajor).$($node.NodeMinor)，dsh-tui 需要 ^22.19 或 >=24，自动安装最新 LTS 便携版（不影响现有 Node）"
            }
            if (-not (Install-Node)) { return @{ Ok = $false; Error = 'Node.js 安装失败，请手动安装 Node.js 22 LTS 后重试（https://nodejs.org）' } }
            $node = Resolve-NodeInfo
            if (-not (Test-NodeSatisfies $node)) { return @{ Ok = $false; Error = 'Node.js 安装后仍不满足要求（需要 ^22.19 或 >=24），请手动升级后重试' } }
        }
        Write-Log "Node.js v$($node.NodeMajor).$($node.NodeMinor) 已就绪"
        $summary += "Node.js v$($node.NodeMajor).$($node.NodeMinor)"
    }

    # 2) npm 全局安装 Harness + TUI
    if (-not $OnlyConfig -and -not $SkipNpmInstall) {
        if (-not (Install-HarnessPackages)) { return @{ Ok = $false; Error = '@deepseek-ai/dsh / @deepseek-harness-tui/dsh-tui 安装失败，请检查网络后重试' } }
        $summary += 'dsh + dsh-tui 已安装'
    }

    # 3) pnpm + dsh-tui profile
    if (-not $OnlyConfig -and -not $SkipTuiSetup) {
        if (-not (Ensure-Pnpm)) { return @{ Ok = $false; Error = 'pnpm 安装失败，请手动执行 npm install -g pnpm 后重试' } }
        if (-not (Install-TuiProfile -DshHome $dshHome)) { return @{ Ok = $false; Error = 'dsh-tui profile 安装失败（详见上方日志）' } }
        $summary += "profile '$PROFILE_NAME' 已就绪"
    }

    # 4) 校验 API Key
    if (-not $NoValidate) {
        if ([string]::IsNullOrWhiteSpace($Key)) { return @{ Ok = $false; Error = '请填写 DeepSeek API Key（在 platform.deepseek.com 的 API Keys 页面创建）' } }
        Write-Log "正在校验 API Key（$Base）…"
        $test = Test-ApiKey -Key $Key.Trim() -Base $Base
        Write-Log $test.Message
        if (-not $test.Ok) { return @{ Ok = $false; Error = $test.Message } }
        $summary += 'API Key 校验通过'
    }

    # 5) 写入凭证
    if ($Key.Trim() -ne '') {
        Set-CredentialEntry -Path $credsPath -Name 'DEEPSEEK_API_KEY' -Value $Key.Trim()
        Write-Log "已写入凭证：$credsPath"
        $summary += "凭证已写入 $credsPath"
    }

    # 6) 写入设置（baseURL / 推理强度）
    $needSettings = $false
    $section = [ordered]@{}
    if ($Base.Trim() -ne '' -and $Base.Trim() -ne $DEFAULT_BASE_URL) {
        $section['baseURL'] = $Base.Trim()
        $needSettings = $true
    }
    if ($Effort -in @('off', 'low', 'high', 'max')) {
        $section['reasoningEffort'] = $Effort
        $needSettings = $true
    }
    if ($needSettings) {
        Set-SettingsSection -Path $settingsPath -Section 'llm-deepseek' -Values $section -ManagedKeys @('baseURL', 'reasoningEffort')
        Write-Log "已写入设置：$settingsPath"
    }

    # 7) 流畅模式覆盖层
    if ($Smooth -and -not $OnlyConfig) {
        if (Write-PerfOverlay -DshHome $dshHome -Effort $Effort -Model $Model) {
            $summary += '流畅模式已启用'
        }
    }

    # 8) 启动器 + 快捷方式
    if (-not $OnlyConfig) {
        Install-Launchers -DshHome $dshHome | Out-Null
        if ($MakeShortcut -and -not $NoShortcut) {
            New-DesktopShortcut -DshHome $dshHome | Out-Null
        }
    }

    # 9) 启动 TUI
    if ($Launch -and -not $NoLaunch -and -not $OnlyConfig) {
        Start-Tui -LauncherBat (Join-Path $dshHome 'launchers\dsh-tui.bat') | Out-Null
    }

    $summaryText = $summary -join '；'
    return @{ Ok = $true; Summary = $summaryText; DshHome = $dshHome; CredsPath = $credsPath }
}
#endregion

#region 图形窗口（WinForms）
function Show-ConfigWindow {
    param([bool]$OnlyConfig)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $script:workerBusy = $false

    $form = New-Object System.Windows.Forms.Form
    $form.Text = if ($OnlyConfig) { 'DeepSeek Harness TUI - 配置 API' } else { 'DeepSeek Harness TUI - 一键安装' }
    $form.Size = New-Object System.Drawing.Size(600, 730)
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = if ($OnlyConfig) { '修改 DeepSeek Harness TUI 连接配置' } else { 'DeepSeek Harness TUI 一键安装' }
    $lblTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 14, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = New-Object System.Drawing.Point(16, 14)
    $lblTitle.AutoSize = $true

    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Text = if ($OnlyConfig) {
        '填写以下信息保存即可，修改立即生效（dsh 每次请求实时解析凭证与设置，无需重启）。'
    } else {
        '只需填写 DeepSeek API Key。脚本自动安装 Node.js、dsh、dsh-tui（v0.9+ 低资源占用）、' +
        'pnpm 并创建 TUI profile，校验 Key 后启动终端界面。'
    }
    $lblHint.ForeColor = [System.Drawing.Color]::Gray
    $lblHint.Location = New-Object System.Drawing.Point(16, 46)
    $lblHint.Size = New-Object System.Drawing.Size(550, 42)

    $grpConn = New-Object System.Windows.Forms.GroupBox
    $grpConn.Text = '连接配置（对应 dsh-llm-deepseek 的凭证与设置）'
    $grpConn.Location = New-Object System.Drawing.Point(16, 98)
    $grpConn.Size = New-Object System.Drawing.Size(552, 205)

    $lblKey = New-Object System.Windows.Forms.Label
    $lblKey.Text = 'DeepSeek API Key *'
    $lblKey.Location = New-Object System.Drawing.Point(14, 30)
    $lblKey.AutoSize = $true
    $txtKey = New-Object System.Windows.Forms.TextBox
    $txtKey.Location = New-Object System.Drawing.Point(160, 26)
    $txtKey.Size = New-Object System.Drawing.Size(372, 23)
    $txtKey.PasswordChar = '●'
    $lblKeyNote = New-Object System.Windows.Forms.Label
    $lblKeyNote.Text = '在 platform.deepseek.com → API Keys 创建（sk- 开头）'
    $lblKeyNote.ForeColor = [System.Drawing.Color]::Gray
    $lblKeyNote.Location = New-Object System.Drawing.Point(160, 52)
    $lblKeyNote.AutoSize = $true

    $lblBase = New-Object System.Windows.Forms.Label
    $lblBase.Text = '接口地址 Base URL'
    $lblBase.Location = New-Object System.Drawing.Point(14, 82)
    $lblBase.AutoSize = $true
    $txtBase = New-Object System.Windows.Forms.TextBox
    $txtBase.Text = 'https://api.deepseek.com'
    $txtBase.Location = New-Object System.Drawing.Point(160, 78)
    $txtBase.Size = New-Object System.Drawing.Size(372, 23)
    $lblBaseNote = New-Object System.Windows.Forms.Label
    $lblBaseNote.Text = '默认官方接口；使用 OpenAI 兼容网关/中转时可改为自己的地址（如 .../v1）'
    $lblBaseNote.ForeColor = [System.Drawing.Color]::Gray
    $lblBaseNote.Location = New-Object System.Drawing.Point(160, 104)
    $lblBaseNote.AutoSize = $true

    $lblEffort = New-Object System.Windows.Forms.Label
    $lblEffort.Text = '推理强度 Reasoning Effort'
    $lblEffort.Location = New-Object System.Drawing.Point(14, 136)
    $lblEffort.AutoSize = $true
    $cmbEffort = New-Object System.Windows.Forms.ComboBox
    $cmbEffort.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $cmbEffort.Location = New-Object System.Drawing.Point(160, 132)
    $cmbEffort.Size = New-Object System.Drawing.Size(150, 23)
    foreach ($it in @('默认（不改动）', 'off', 'low', 'high', 'max')) { [void]$cmbEffort.Items.Add($it) }
    $cmbEffort.SelectedIndex = 0

    $lblModel = New-Object System.Windows.Forms.Label
    $lblModel.Text = '默认模型 Model'
    $lblModel.Location = New-Object System.Drawing.Point(14, 176)
    $lblModel.AutoSize = $true
    $cmbModel = New-Object System.Windows.Forms.ComboBox
    $cmbModel.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown   # 可编辑，支持自定义模型名
    $cmbModel.Location = New-Object System.Drawing.Point(160, 172)
    $cmbModel.Size = New-Object System.Drawing.Size(372, 23)
    foreach ($it in @('deepseek-v4-flash', 'deepseek-v4-pro', 'deepseek-v4-flash-vision-exp')) { [void]$cmbModel.Items.Add($it) }
    $cmbModel.Text = 'deepseek-v4-flash'

    $grpOpt = New-Object System.Windows.Forms.GroupBox
    $grpOpt.Text = '安装选项'
    $grpOpt.Location = New-Object System.Drawing.Point(16, 311)
    $grpOpt.Size = New-Object System.Drawing.Size(552, 102)
    $chkSmooth = New-Object System.Windows.Forms.CheckBox
    $chkSmooth.Text = '流畅模式（降低状态行刷新率 500ms→1500ms、轻量动画帧，减少卡顿）'
    $chkSmooth.Location = New-Object System.Drawing.Point(14, 20)
    $chkSmooth.Size = New-Object System.Drawing.Size(520, 20)
    $chkSmooth.Checked = $true
    $chkShortcut = New-Object System.Windows.Forms.CheckBox
    $chkShortcut.Text = '创建桌面快捷方式（一键启动终端 TUI）'
    $chkShortcut.Location = New-Object System.Drawing.Point(14, 48)
    $chkShortcut.AutoSize = $true
    $chkShortcut.Checked = $true
    $chkLaunch = New-Object System.Windows.Forms.CheckBox
    $chkLaunch.Text = '安装完成后自动启动 TUI'
    $chkLaunch.Location = New-Object System.Drawing.Point(14, 74)
    $chkLaunch.AutoSize = $true
    $chkLaunch.Checked = $true
    if ($OnlyConfig) { $grpOpt.Visible = $false }

    $lblLogTitle = New-Object System.Windows.Forms.Label
    $lblLogTitle.Text = '安装日志'
    $lblLogTitle.Location = New-Object System.Drawing.Point(16, 421)
    $lblLogTitle.AutoSize = $true
    $txtLog = New-Object System.Windows.Forms.RichTextBox
    $txtLog.Location = New-Object System.Drawing.Point(16, 445)
    $txtLog.Size = New-Object System.Drawing.Size(552, 175)
    $txtLog.ReadOnly = $true
    $txtLog.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $txtLog.ForeColor = [System.Drawing.Color]::FromArgb(200, 230, 200)
    $txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
    $txtLog.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Location = New-Object System.Drawing.Point(16, 630)
    $progress.Size = New-Object System.Drawing.Size(552, 14)
    $progress.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $progress.Visible = $false

    $btnInstall = New-Object System.Windows.Forms.Button
    $btnInstall.Text = if ($OnlyConfig) { '保存配置' } else { '一键安装' }
    $btnInstall.Location = New-Object System.Drawing.Point(180, 656)
    $btnInstall.Size = New-Object System.Drawing.Size(110, 32)
    $btnInstall.BackColor = [System.Drawing.Color]::FromArgb(77, 171, 247)
    $btnInstall.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat

    $btnTest = New-Object System.Windows.Forms.Button
    $btnTest.Text = '仅测试连接'
    $btnTest.Location = New-Object System.Drawing.Point(300, 656)
    $btnTest.Size = New-Object System.Drawing.Size(110, 32)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '取消'
    $btnCancel.Location = New-Object System.Drawing.Point(420, 656)
    $btnCancel.Size = New-Object System.Drawing.Size(90, 32)

    $form.Controls.AddRange(@($lblTitle, $lblHint, $grpConn, $grpOpt, $lblLogTitle, $txtLog, $progress, $btnInstall, $btnTest, $btnCancel))
    $grpConn.Controls.AddRange(@($lblKey, $txtKey, $lblKeyNote, $lblBase, $txtBase, $lblBaseNote, $lblEffort, $cmbEffort, $lblModel, $cmbModel))
    $grpOpt.Controls.AddRange(@($chkSmooth, $chkShortcut, $chkLaunch))

    $script:LogSink = { param($line)
        $txtLog.AppendText($line + "`r`n")
        $txtLog.SelectionStart = $txtLog.TextLength
        $txtLog.ScrollToCaret()
    }

    function Set-Busy([bool]$busy) {
        $script:workerBusy = $busy
        $btnInstall.Enabled = -not $busy
        $btnTest.Enabled = -not $busy
        $btnCancel.Enabled = -not $busy
        $progress.Visible = $busy
        $form.Cursor = if ($busy) { [System.Windows.Forms.Cursors]::WaitCursor } else { [System.Windows.Forms.Cursors]::Default }
    }

    $worker = New-Object System.ComponentModel.BackgroundWorker
    $worker.WorkerReportsProgress = $true

    $worker.Add_DoWork({
        param($s, $e)
        $w = $s
        $script:LogSink = { param($line) $w.ReportProgress(0, $line) }
        $result = Invoke-InstallFlow -Key $txtKey.Text -Base $txtBase.Text `
            -Effort $(if ($cmbEffort.SelectedIndex -gt 0) { $cmbEffort.SelectedItem } else { '' }) `
            -Model $cmbModel.Text `
            -MakeShortcut $chkShortcut.Checked -Launch $chkLaunch.Checked -Smooth $chkSmooth.Checked -OnlyConfig $OnlyConfig
        $e.Result = $result
    })
    $worker.Add_ProgressChanged({
        param($s, $e)
        $txtLog.AppendText([string]$e.UserState + "`r`n")
        $txtLog.SelectionStart = $txtLog.TextLength
        $txtLog.ScrollToCaret()
    })
    $worker.Add_RunWorkerCompleted({
        param($s, $e)
        $script:LogSink = { param($line) $txtLog.AppendText($line + "`r`n"); $txtLog.SelectionStart = $txtLog.TextLength; $txtLog.ScrollToCaret() }
        Set-Busy $false
        if ($e.Error) {
            [System.Windows.Forms.MessageBox]::Show($form, $e.Error.Message, '安装出错', 'OK', 'Error') | Out-Null
            return
        }
        $result = $e.Result
        if (-not $result.Ok) {
            [System.Windows.Forms.MessageBox]::Show($form, $result.Error, '未能完成', 'OK', 'Warning') | Out-Null
            return
        }
        $msg = "安装完成！`n`n$($result.Summary)`n`n" +
               "启动方式：双击桌面快捷方式，或在终端运行 dsh-tui（恢复上次会话：dsh-tui --resume）`n" +
               "凭证文件: $($result.CredsPath)`n`n" +
               "使用说明（/btw 等指令速查）：仓库 docs/使用说明.md`n" +
               "提示：以后改 API Key 可重新运行 install.bat，或双击 configure.bat。"
        [System.Windows.Forms.MessageBox]::Show($form, $msg, 'DeepSeek Harness TUI 一键安装', 'OK', 'Information') | Out-Null
        if ($chkLaunch.Checked -and -not $OnlyConfig) {
            $bat = Join-Path $result.DshHome 'launchers\dsh-tui.bat'
            if (Test-Path $bat) { Start-Process -FilePath $bat }
        }
        $form.Close()
    })

    $btnInstall.Add_Click({
        if ($script:workerBusy) { return }
        if ([string]::IsNullOrWhiteSpace($txtKey.Text)) {
            [System.Windows.Forms.MessageBox]::Show($form, '请先填写 DeepSeek API Key', '提示', 'OK', 'Warning') | Out-Null
            return
        }
        Set-Busy $true
        $txtLog.Clear()
        $worker.RunWorkerAsync()
    })

    $btnTest.Add_Click({
        if ($script:workerBusy) { return }
        if ([string]::IsNullOrWhiteSpace($txtKey.Text)) {
            [System.Windows.Forms.MessageBox]::Show($form, '请先填写 DeepSeek API Key', '提示', 'OK', 'Warning') | Out-Null
            return
        }
        Set-Busy $true
        $txtLog.Clear()
        $txtLog.AppendText('正在测试连接…' + "`r`n")
        $form.Refresh()
        $r = Test-ApiKey -Key $txtKey.Text.Trim() -Base $txtBase.Text
        $txtLog.AppendText($r.Message + "`r`n")
        Set-Busy $false
        [System.Windows.Forms.MessageBox]::Show($form, $r.Message, '连接测试', 'OK', $(if ($r.Ok) { 'Information' } else { 'Error' })) | Out-Null
    })

    $btnCancel.Add_Click({ $form.Close() })
    $form.Add_Shown({ $form.Activate(); $txtKey.Focus() })
    [void]$form.ShowDialog()
}
#endregion

#region 入口
$dshHome = Get-DshHome
Write-Log "DSH 家目录：$dshHome"

if ($Headless) {
    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        # 支持用环境变量传入 Key（避免出现在命令行/进程参数里）
        if ($env:DSH_INSTALL_API_KEY -and $env:DSH_INSTALL_API_KEY.Trim() -ne '') {
            $ApiKey = $env:DSH_INSTALL_API_KEY.Trim()
        }
    }
    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        Write-Host 'Headless 模式必须提供 -ApiKey 参数（或用环境变量 DSH_INSTALL_API_KEY）'
        exit 2
    }
    $result = Invoke-InstallFlow -Key $ApiKey -Base $BaseUrl -Effort $ReasoningEffort -Model $Model `
        -MakeShortcut (-not $NoShortcut) -Launch (-not $NoLaunch) -Smooth $SmoothMode -OnlyConfig $ConfigureOnly
    if (-not $result.Ok) {
        Write-Host "失败：$($result.Error)"
        exit 1
    }
    Write-Host ''
    Write-Host '==== 安装完成 ===='
    Write-Host $result.Summary
    Write-Host "DSH 家目录: $($result.DshHome)"
    Write-Host '启动: dsh-tui（恢复上次会话: dsh-tui --resume）'
    Write-Host '使用说明（/btw 等指令速查）: 仓库 docs/使用说明.md'
    exit 0
}

Show-ConfigWindow -OnlyConfig $ConfigureOnly
#endregion
