<#
================================================================================
 DeepSeek Harness TUI 安装脚本（一键安装）/ 配置脚本
--------------------------------------------------------------------------------
 对应 DeepSeek Harness 官方连接 DeepSeek API 的现有方式（TUI 版）：
   1. 检查 Node.js（要求 ^22.19 || >=24；缺失/过旧则自动安装最新 LTS 便携版）
   2. npm 全局安装 @deepseek-ai/dsh（官方 Harness CLI）与
      @deepseek-harness-tui/dsh-tui（官方公众号收录的 TUI 前端；版本默认稳定版 0.9.3，
      可传 -TuiVersion latest 装尝鲜 beta，见参数说明）
   3. 检查 pnpm（>=10，dsh plugin 安装 profile 依赖需要）
   4. dsh plugin --profile dsh-tui add @deepseek-harness-tui/dsh-tui@latest
      （创建 dsh-tui profile；dsh-tui 命令 = dsh --profile dsh-tui）
   5. 用你填写的 API Key 调用 DeepSeek API 校验连通性
   6. 写入凭证 $DSH_HOME/.credentials.yaml 的 DEEPSEEK_API_KEY
      （dsh-llm-deepseek 每次请求实时解析，改完立即生效，无需重启）
   7. 可选写入 $DSH_HOME/settings.yaml 的 llm-deepseek 段（baseURL / 推理强度）
   8. 向 $DSH_HOME/profiles/dsh-tui/cordis.patch.yml 写入 TUI 覆盖层：
      默认模型 / 推理强度（独立于流畅模式勾选，configure.bat 也可修改）+
      流畅模式（工作状态行刷新 500ms -> 1500ms、轻量动画帧，减少卡顿）
   9. 复制启动器、创建桌面快捷方式、启动 TUI

 用法：
   install.bat                     双击（图形窗口，填写 API Key 后一键安装）
   powershell -File install.ps1 -Headless -ApiKey sk-xxx ...  命令行模式
   powershell -File install.ps1 -Headless -ApiKey sk-xxx -TuiVersion latest  尝鲜 dsh-tui beta
================================================================================
#>
[CmdletBinding()]
param(
    [switch]$Headless,          # 无图形窗口，日志输出到控制台
    [switch]$ConfigureOnly,     # 仅写入配置（不安装 Node/dsh/TUI、不建快捷方式）
    [string]$ApiKey = "",       # Headless 模式必须提供
    [string]$BaseUrl = "https://api.deepseek.com",
    [string]$ReasoningEffort = "",   # off|low|high|max；留空则不改动默认值
    [string]$Model = "",         # 默认模型：留空=deepseek-v4-flash；可填任意模型名（需在该接口的模型列表中，否则 TUI 会回落默认）
    [string]$TuiVersion = '0.9.3',  # dsh-tui 版本：'0.9.3'（稳定版，默认）或 'latest'（尝鲜 beta）。上游发新稳定版后此默认值同步更新
    [switch]$NoShortcut,        # 不创建桌面快捷方式
    [switch]$NoLaunch,          # 安装完成后不自动启动 TUI
    [switch]$SkipNodeCheck,     # 跳过 Node.js 检测/安装
    [switch]$SkipNpmInstall,    # 跳过 npm 全局安装
    [switch]$SkipTuiSetup,      # 跳过 pnpm 检查与 profile 安装（调试用）
    [switch]$NoValidate,        # 跳过 API Key 在线校验
    [bool]$SmoothMode = $true,  # 流畅模式：写入性能优化项（状态行刷新率/动画帧）；默认模型与推理强度不受此开关影响
    [string]$DshHome = "",      # 覆盖 DSH 家目录（默认 $env:DSH_HOME 或 ~/.dsh）
    [switch]$LibraryMode        # 内部使用：仅加载函数不进入入口（GUI 后台 runspace 点源调用）
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# Windows PowerShell 5.1 默认 TLS 1.0，https 请求会失败；显式启用 TLS 1.2
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

$PROFILE_NAME = 'dsh-tui'
$TUI_PACKAGE = '@deepseek-harness-tui/dsh-tui'
$DEFAULT_BASE_URL = 'https://api.deepseek.com'
# dsh-tui 默认（稳定）版本。上游 stable 线推进时更新这里 + param 默认值 + GUI 下拉文案 + README。
$DEFAULT_TUI_VERSION = '0.9.3'

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
    # 注意：GUI 后台线程（独立 runspace）里不能调 Write-Host——
    # 没有 runspace 的线程上会报"此线程中没有可用于运行脚本的运行空间"。
    # GUI 模式的终端镜像由 UI 定时器统一做（见 Show-ConfigWindow）。
}
$script:LogSink = $null

# ---- GUI 后台安装基础设施 --------------------------------------------------
# Windows PowerShell 5.1 的 BackgroundWorker 事件回调跑在没有 runspace 的
# 线程池线程上，脚本块一执行就抛 PSInvalidOperationException。因此 GUI 安装
# 改为：独立 runspace 跑安装流程 -> 日志进线程安全队列 -> UI 定时器刷新到
# 文本框并镜像到 install.bat 弹出的终端。
$script:LogQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$script:InstallState = [pscustomobject]@{ Done = $false; Ok = $false; Error = ''; Summary = ''; CredsPath = ''; DshHome = '' }
$script:InstallFinalized = $false
$script:InstallPs = $null
$script:InstallAsync = $null

# 安装进度（GUI 模式：安装流程写 Step/Percent，UI 定时器读；Headless 无 UI 时保持 $null，Set-Progress 空操作）
$script:InstallProgress = $null

function Set-Progress {
    param([string]$Step = '', [int]$Percent = -1)
    $p = $script:InstallProgress
    if ($null -eq $p) { return }
    if ($Step -ne '') { $p.Step = $Step }
    if ($Percent -ge 0) { $p.Percent = [Math]::Min(100, [Math]::Max(0, $Percent)) }
}

$script:InstallWorkerSb = {
    param($ScriptPath, $Key, $Base, $Effort, $Model, $MakeShortcut, $Launch, $Smooth, $OnlyConfig,
          $QueueRef, $StateRef, $TuiVer, $ProgressRef)
    try {
        # 点源自身脚本（-LibraryMode 只加载函数），复用全部安装逻辑
        . $ScriptPath -LibraryMode
        # 注意：install.ps1 顶层会初始化 $script:LogQueue / $script:InstallState /
        # $script:InstallProgress / $script:LogSink 等脚本作用域变量。点源后这些变量会被
        # 新建对象替换，因此本脚本块只使用带 Ref 后缀的参数名（不受点源影响），并在
        # 点源后把共享的队列 / 状态 / 进度对象写回脚本作用域变量，保证 GUI 能实时
        # 收到日志与安装进度（否则日志队列断链，安装期间界面看不到任何输出）。
        $script:LogQueue = $QueueRef
        $script:LogSink = { param($line) [void]$QueueRef.Enqueue($line) }
        $script:InstallState = $StateRef
        $script:InstallProgress = $ProgressRef
        $r = Invoke-InstallFlow -Key $Key -Base $Base -Effort $Effort -Model $Model `
            -MakeShortcut $MakeShortcut -Launch $Launch -Smooth $Smooth -OnlyConfig $OnlyConfig -TuiVersion $TuiVer
        $StateRef.Ok = $r.Ok
        if ($r.Ok) {
            $StateRef.Summary = $r.Summary
            $StateRef.CredsPath = $r.CredsPath
            $StateRef.DshHome = $r.DshHome
        } else {
            # 失败结果没有 Summary/CredsPath/DshHome 键：只在 Ok 时读取，
            # 否则会把真实错误信息覆盖成晦涩的属性访问异常
            $StateRef.Error = if ($r.Error -and $r.Error -ne '') { $r.Error } else { '安装失败，详见上方日志' }
        }
    } catch {
        $StateRef.Ok = $false
        $StateRef.Error = $_.Exception.Message
    } finally {
        $StateRef.Done = $true
    }
}

function Start-InstallWorker {
    param([string]$Key, [string]$Base, [string]$Effort, [string]$Model,
          [bool]$MakeShortcut, [bool]$Launch, [bool]$Smooth, [bool]$OnlyConfig, [string]$TuiVer)
    try {
        if ($script:InstallPs) {
            try { $null = $script:InstallPs.EndInvoke($script:InstallAsync) } catch { }
            $script:InstallPs.Dispose()
            $script:InstallPs.Runspace.Dispose()
        }
    } catch { }
    $script:InstallState.Done = $false
    $script:InstallState.Ok = $false
    $script:InstallState.Error = ''
    $script:InstallFinalized = $false
    $script:InstallProgress = [pscustomobject]@{ Step = ''; Percent = 0; Models = $null }
    $dummy = $null
    while ($script:LogQueue.TryDequeue([ref]$dummy)) { }
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = [System.Threading.ApartmentState]::STA
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript($script:InstallWorkerSb.ToString()).AddArgument($PSCommandPath).AddArgument($Key).AddArgument($Base).AddArgument($Effort).AddArgument($Model).AddArgument($MakeShortcut).AddArgument($Launch).AddArgument($Smooth).AddArgument($OnlyConfig).AddArgument($script:LogQueue).AddArgument($script:InstallState).AddArgument($TuiVer).AddArgument($script:InstallProgress)
    $script:InstallPs = $ps
    $script:InstallAsync = $ps.BeginInvoke()
}

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

    # 2) 在线下载最新 LTS 便携版（免管理员，最稳妥）。
    #    官方源失败（国内网络常见）自动切 npmmirror 的 node 二进制镜像重试。
    foreach ($base in @('https://nodejs.org/dist', 'https://registry.npmmirror.com/-/binary/node')) {
        try {
            Write-Log "正在查询 Node.js 最新 LTS 版本（$base）…"
            $idx = Invoke-RestMethod -Uri "$base/index.json" -TimeoutSec 30
            $latest = $idx | Where-Object { $_.lts } | Select-Object -First 1
            if ($latest) {
                $ver = $latest.version
                $url = "$base/$ver/node-$ver-win-x64.zip"
                $tmp = Join-Path $env:TEMP "node-$ver-win-x64.zip"
                Write-Log "正在下载 Node.js $ver 便携版（约 30MB）…"
                Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 300
                if (Expand-PortableNodeZip $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue; return $true }
            }
        } catch { Write-Log "从 $base 下载失败：$($_.Exception.Message)" }
    }

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

# npm 11（node 24 自带 11.12.x）安装含嵌套 protobufjs 的依赖树时，其
# postinstall 会报 "Cannot find module '...\protobufjs\scripts\postinstall'"
# 导致整个全局安装失败（包本身正常、单装 protobufjs 正常、--ignore-scripts
# 可装完，纯脚本阶段问题；npm 12 已修复）。识别特征：输出里同时出现
# protobufjs / postinstall / Cannot find module。
function Test-NpmProtobufjsFailure {
    param([string[]]$Lines)
    $joined = $Lines -join "`n"
    return (($joined -match 'protobufjs') -and ($joined -match 'postinstall') -and ($joined -match 'Cannot find module|MODULE_NOT_FOUND'))
}

# 升级 npm 到 12 并返回新的 npm.cmd 路径（升级产物在 prefix 下）；
# 失败返回 $null。升级不影响已装包，只在检测到 protobufjs 问题时触发。
# npm 12 的 allowScripts 机制默认阻止依赖的 install 脚本，node-pty/koffi/
# dsh-subprocess-local 的原生绑定需要执行——重试时用 --allow-scripts 显式放行。
$NPM12_ALLOW_SCRIPTS = '@deepseek-ai/dsh-subprocess-local,koffi,node-pty'
# 官方源失败（国内网络常见）时的 npm 镜像
$NPM_REGISTRY_FALLBACK = 'https://registry.npmmirror.com'
function Update-NpmTo12 {
    param([string]$NpmCmd)
    Write-Log '检测到 npm 11 的 protobufjs postinstall 已知问题，正在自动升级 npm 到 12…'
    Invoke-Native { & $NpmCmd install -g npm@12 --no-fund --no-audit 2>&1 } | ForEach-Object { Write-Log "npm: $_" }
    if ($LASTEXITCODE -ne 0) {
        # 国内网络常见：官方源失败 → npmmirror 镜像重试
        Write-Log 'npm 12 官方源升级失败，切换 npmmirror 镜像重试…'
        Invoke-Native { & $NpmCmd install -g npm@12 --no-fund --no-audit --registry=$NPM_REGISTRY_FALLBACK 2>&1 } | ForEach-Object { Write-Log "npm: $_" }
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Log 'npm 12 升级失败。可手动执行 npm install -g npm@12 后重跑安装器'
        return $null
    }
    # 重新定位 npm：升级产物装在 prefix（NPM_CONFIG_PREFIX 或 npm config get prefix）
    $prefix = if ($env:NPM_CONFIG_PREFIX -and $env:NPM_CONFIG_PREFIX.Trim() -ne '') { $env:NPM_CONFIG_PREFIX.Trim() } else { (& $NpmCmd config get prefix 2>$null).Trim() }
    $newNpm = Join-Path $prefix 'npm.cmd'
    if (-not (Test-Path $newNpm)) {
        Write-Log "npm 已升级，但未在 $prefix 找到 npm.cmd，仍使用原 npm"
        return $NpmCmd
    }
    # 确认新 npm 确实是 12.x（老 shim 或 PATH 干扰时避免误用）
    $ver = (& $newNpm --version 2>$null)
    if ($ver -and $ver -match '^12\.') {
        Write-Log "npm 已升级：$newNpm (v$ver)"
        return $newNpm
    }
    Write-Log "npm 升级产物版本异常（$ver），请手动执行 npm install -g npm@12 后重跑安装器"
    return $null
}

function Install-HarnessPackages {
    param([string]$TuiVersion)
    $npmCmd = (Resolve-NodeInfo).NpmCmd
    if (-not $npmCmd) {
        $npmCmd = Resolve-CmdShim 'npm'
    }
    if (-not $npmCmd) { return 'fail' }
    Write-Log "正在 npm 全局安装 @deepseek-ai/dsh@latest 与 $TUI_PACKAGE@$TuiVersion（首次约需下载 300MB，请耐心等待）…"
    $env:NPM_CONFIG_FUND = 'false'
    # 失败恢复顺序：protobufjs bug（npm 11）→ 升级 npm 12 → 镜像重试 → 降级仅装 TUI。
    # 官方源与 npmmirror 各试一次，protobufjs 特征在任何源下都先走 npm 12。
    $npmOut = @()
    Invoke-Native { & $npmCmd install -g @deepseek-ai/dsh@latest $TUI_PACKAGE@$TuiVersion --foreground-scripts --no-fund --no-audit 2>&1 } | ForEach-Object { $npmOut += $_; Write-Log "npm: $_" }
    if ($LASTEXITCODE -ne 0) {
        if (Test-NpmProtobufjsFailure $npmOut) {
            Write-Log '组合安装失败：npm 11 的 protobufjs postinstall 已知问题（MODULE_NOT_FOUND）'
            $newNpm = Update-NpmTo12 $npmCmd
            if ($newNpm) {
                $npmCmd = $newNpm
                Write-Log '使用 npm 12 重新尝试组合安装…'
                $npmOut = @()
                Invoke-Native { & $npmCmd install -g @deepseek-ai/dsh@latest $TUI_PACKAGE@$TuiVersion --foreground-scripts --no-fund --no-audit --allow-scripts=$NPM12_ALLOW_SCRIPTS 2>&1 } | ForEach-Object { $npmOut += $_; Write-Log "npm: $_" }
                if ($LASTEXITCODE -eq 0) {
                    Add-ToUserPath (Join-Path $env:APPDATA 'npm')
                    return 'ok'
                }
            }
        } else {
            # 网络原因（国内常见）→ npmmirror 镜像重试一次
            Write-Log 'npm 官方源安装失败，切换 npmmirror 镜像重试…'
            $npmOut = @()
            Invoke-Native { & $npmCmd install -g @deepseek-ai/dsh@latest $TUI_PACKAGE@$TuiVersion --foreground-scripts --no-fund --no-audit --registry=$NPM_REGISTRY_FALLBACK 2>&1 } | ForEach-Object { $npmOut += $_; Write-Log "npm: $_" }
            if ($LASTEXITCODE -eq 0) {
                Add-ToUserPath (Join-Path $env:APPDATA 'npm')
                return 'ok'
            }
            # 镜像下也可能撞 npm 11 的 protobufjs bug → npm 12 升级重试
            if (Test-NpmProtobufjsFailure $npmOut) {
                Write-Log '镜像源安装同样遇到 protobufjs postinstall 问题，升级 npm 12 后重试…'
                $newNpm = Update-NpmTo12 $npmCmd
                if ($newNpm) {
                    $npmCmd = $newNpm
                    $npmOut = @()
                    Invoke-Native { & $npmCmd install -g @deepseek-ai/dsh@latest $TUI_PACKAGE@$TuiVersion --foreground-scripts --no-fund --no-audit --allow-scripts=$NPM12_ALLOW_SCRIPTS --registry=$NPM_REGISTRY_FALLBACK 2>&1 } | ForEach-Object { $npmOut += $_; Write-Log "npm: $_" }
                    if ($LASTEXITCODE -eq 0) {
                        Add-ToUserPath (Join-Path $env:APPDATA 'npm')
                        return 'ok'
                    }
                }
            }
        }
        # 常见原因：DeepSeek Harness（TUI/Web）正在运行，全局 @deepseek-ai/dsh 目录被进程占用
        # （Windows 文件锁），npm 替换失败并回滚。降级：只装 TUI 包（不碰运行中的 dsh 树）。
        Write-Log '@deepseek-ai/dsh 安装未完成（常见原因：Harness 正在运行、全局目录被占用；或网络/镜像问题未解决）'
        Write-Log '降级方案：仅安装 TUI 包 @deepseek-harness-tui/dsh-tui…'
        $npmOut = @()
        Invoke-Native { & $npmCmd install -g $TUI_PACKAGE@$TuiVersion --foreground-scripts --no-fund --no-audit 2>&1 } | ForEach-Object { $npmOut += $_; Write-Log "npm: $_" }
        if ($LASTEXITCODE -ne 0) {
            if (Test-NpmProtobufjsFailure $npmOut) {
                # 降级也遇到 protobufjs bug → 同样升级 npm 12 重试
                Write-Log 'TUI 包安装同样遇到 protobufjs postinstall 问题，尝试升级 npm 12 后重试…'
                $newNpm = Update-NpmTo12 $npmCmd
                if ($newNpm) {
                    $npmCmd = $newNpm
                    $npmOut = @()
                    Invoke-Native { & $npmCmd install -g $TUI_PACKAGE@$TuiVersion --foreground-scripts --no-fund --no-audit --allow-scripts=$NPM12_ALLOW_SCRIPTS 2>&1 } | ForEach-Object { $npmOut += $_; Write-Log "npm: $_" }
                    if ($LASTEXITCODE -eq 0) {
                        Add-ToUserPath (Join-Path $env:APPDATA 'npm')
                        Write-Log 'TUI 包安装成功（npm 12）'
                        return 'tui-only'
                    }
                }
            } else {
                # 网络原因 → 镜像重试 TUI 包
                Write-Log 'TUI 包安装失败，切换 npmmirror 镜像重试…'
                $npmOut = @()
                Invoke-Native { & $npmCmd install -g $TUI_PACKAGE@$TuiVersion --foreground-scripts --no-fund --no-audit --registry=$NPM_REGISTRY_FALLBACK 2>&1 } | ForEach-Object { $npmOut += $_; Write-Log "npm: $_" }
                if ($LASTEXITCODE -eq 0) {
                    Add-ToUserPath (Join-Path $env:APPDATA 'npm')
                    Write-Log 'TUI 包安装成功（npmmirror 镜像）'
                    return 'tui-only'
                }
            }
            return 'fail'
        }
        Write-Log 'TUI 包安装成功。提示：关闭 TUI/Harness 后重新运行安装器即可更新 @deepseek-ai/dsh（不影响 TUI 使用）'
        Add-ToUserPath (Join-Path $env:APPDATA 'npm')
        return 'tui-only'
    }
    Add-ToUserPath (Join-Path $env:APPDATA 'npm')
    return 'ok'
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
        Invoke-Native { & $npmCmd install -g pnpm@latest --foreground-scripts --no-fund --no-audit 2>&1 } | ForEach-Object { Write-Log "npm: $_" }
        if ($LASTEXITCODE -ne 0) {
            # 国内网络常见：官方源失败 → npmmirror 镜像重试
            Write-Log 'pnpm 安装失败，切换 npmmirror 镜像重试…'
            Invoke-Native { & $npmCmd install -g pnpm@latest --foreground-scripts --no-fund --no-audit --registry=$NPM_REGISTRY_FALLBACK 2>&1 } | ForEach-Object { Write-Log "npm: $_" }
        }
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
    param([string]$DshHome, [string]$TuiVersion)
    $dshCmd = Resolve-CmdShim 'dsh'
    if (-not $dshCmd) { Write-Log '未找到 dsh 命令'; return $false }
    Write-Log "正在创建 profile '$PROFILE_NAME' 并安装 $TUI_PACKAGE（首次需联网下载，请耐心等待）…"
    $wsFile = Join-Path $DshHome "profiles\$PROFILE_NAME\pnpm-workspace.yaml"
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        Invoke-Native { & $dshCmd plugin --profile $PROFILE_NAME add "$TUI_PACKAGE@$TuiVersion" 2>&1 } | ForEach-Object { Write-Log "dsh: $_" }
        if ($LASTEXITCODE -eq 0) { break }
        Write-Log "dsh plugin 退出码 $LASTEXITCODE"
        if ($attempt -eq 0) {
            if (Test-Path $wsFile) { Fix-PnpmAllowBuilds -WsFile $wsFile }
            # 网络原因（国内常见）：第二次尝试让 pnpm 走 npmmirror 镜像
            # （pnpm 尊重 npm_config_registry 环境变量；allowBuilds 已在上一步修复）
            $env:npm_config_registry = $NPM_REGISTRY_FALLBACK
            Write-Log "第二次尝试使用 npmmirror 镜像（npm_config_registry=$NPM_REGISTRY_FALLBACK）…"
        }
    }
    if ($LASTEXITCODE -ne 0) { return $false }
    # 校验 bundle 层已包含 TUI 包（pnpm 失败时 reconcile 不会执行）
    $pkgJson = Join-Path $DshHome "profiles\$PROFILE_NAME\package.json"
    if (Test-Path $pkgJson) {
        $m = Get-Content $pkgJson -Raw | ConvertFrom-Json
        if ($m.dsh.profile.bundles -contains $TUI_PACKAGE) { return $true }
        Write-Log "profile bundle 层缺少 $TUI_PACKAGE，尝试再次同步…"
        Invoke-Native { & $dshCmd plugin --profile $PROFILE_NAME add "$TUI_PACKAGE@$TuiVersion" 2>&1 } | ForEach-Object { Write-Log "dsh: $_" }
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

# TUI 配置覆盖层：$DSH_HOME/profiles/dsh-tui/cordis.patch.yml
#  - 默认模型 / 推理强度：写入 dsh-tui 行的 config（不依赖流畅模式勾选）
#  - 流畅模式：working-activity.publishIntervalMs 500 -> 1500（工作状态行刷新率降为 ~0.7Hz）
#    + dsh-tui.activityFrames: claude -> dots（轻量动画帧）
# 覆盖层按 id 整块替换 config（patch 语义），因此必须重述包内默认键
# （fullscreen: true、effort: max、preset/workspace/sessionId 环境透传），
# 否则这些默认值会被悄悄丢掉（如 fullscreen 从 true 变 false、effort 从 max 变高）。
# 已存在的用户覆盖层（无本脚本标记）不覆盖，尊重用户自定义。
function Write-TuiOverlay {
    param([string]$DshHome, [string]$Effort, [string]$Model, [bool]$Smooth)
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
                Write-Log "检测到已有自定义覆盖层 $patchPath，跳过写入（尊重你的配置；本次选择的模型/推理强度/流畅模式未生效，如需修改请手动编辑该文件）"
                return $false
            }
        }
    }
    $lines = @(
        '# 由 dsh-oneclick-install 写入的覆盖层：默认模型 / 推理强度 / 流畅模式',
        '# 模型与推理强度在 dsh-tui 启动时生效；删除本文件即可恢复默认（dsh-tui 包自带配置）。'
    )
    if ($Smooth) {
        $lines += @(
            '- id: working-activity',
            '  config:',
            '    publishIntervalMs: 1500'
        )
    }
    # 覆盖层整块替换 dsh-tui 行的 config，必须重述包内默认键，避免丢默认值
    $tui = @(
        '- id: dsh-tui',
        '  config:',
        '    provider: deepseek-official',
        '    fullscreen: true',
        '    preset: !!js process.env.DSH_TUI_PRESET ?? undefined',
        '    workspace: !!js process.env.DSH_TUI_WORKSPACE_TARGET ?? undefined',
        '    sessionId: !!js process.env.DSH_TUI_RESUME_SESSION ?? process.env.DSH_CC_RESUME_SESSION ?? undefined'
    )
    # 默认模型：GUI 始终有值；Headless 留空 = 不改动（保持 dsh-tui 默认 deepseek-v4-flash）。
    # 注意：模型名需在该接口的模型列表中，否则 dsh-tui 会静默回退默认模型。
    if ($Model -match '^[A-Za-z0-9_\-\.:/+]+$') { $tui += "    model: $Model" }
    # 推理强度：用户显式选择 off/low/high/max；默认（不改动）时重述包内默认 max
    $effortVal = if ($Effort -in @('off', 'low', 'high', 'max')) { $Effort } else { 'max' }
    $tui += "    effort: $effortVal"
    if ($Smooth) {
        $tui += @(
            '    activity: true',
            '    activityFrames: dots',
            '    contextBar: true'
        )
    }
    $lines += $tui
    Write-YamlLines -Path $patchPath -Lines $lines
    Write-Log "已写入 TUI 配置覆盖层（模型/推理强度/流畅模式）：$patchPath"
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
        $models = @($resp.data | ForEach-Object { if ($_.id) { $_.id } elseif ($_.name) { $_.name } } | Where-Object { $_ -and $_ -ne '' })
        $count = $models.Count
        $msg = if ($count -gt 0) {
            "连接成功！API Key 有效，可用模型 $count 个"
        } else {
            '连接成功！API Key 有效（该接口未在 /models 响应中列出模型）'
        }
        return @{ Ok = $true; Message = $msg; Models = $models }
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
        if (-not (Test-Path $lnkPath)) { throw "快捷方式文件未生成：$lnkPath" }
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
        [string]$TuiVersion,
        [bool]$MakeShortcut,
        [bool]$Launch,
        [bool]$Smooth,
        [bool]$OnlyConfig
    )

    $dshHome = Get-DshHome
    $credsPath = Join-Path $dshHome '.credentials.yaml'
    $settingsPath = Join-Path $dshHome 'settings.yaml'
    $summary = @()

    # 版本格式白名单，防止任意字符串拼进 npm/pnpm 命令（latest 标签也在白名单内）
    if ($TuiVersion -notmatch '^[A-Za-z0-9][A-Za-z0-9\.\-]*$') {
        return @{ Ok = $false; Error = "TUI 版本格式非法：'$TuiVersion'（应为如 0.9.3 的版本号，或 latest）" }
    }

    Set-Progress '准备安装…' 5

    # 1) Node.js
    if (-not $OnlyConfig -and -not $SkipNodeCheck) {
        Set-Progress '检查 Node.js 环境…' 10
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
    Set-Progress 'Node.js 环境就绪' 12

    # 2) npm 全局安装 Harness + TUI
    if (-not $OnlyConfig -and -not $SkipNpmInstall) {
        Set-Progress '安装 dsh 与 dsh-tui（首次需下载数百 MB，请耐心等待）' 20
        $npmResult = Install-HarnessPackages -TuiVersion $TuiVersion
        if ($npmResult -eq 'fail') { return @{ Ok = $false; Error = '@deepseek-ai/dsh / @deepseek-harness-tui/dsh-tui 安装失败，请检查网络后重试' } }
        if ($npmResult -eq 'ok') { $summary += "dsh + dsh-tui@$TuiVersion 已安装" }
        else { $summary += "dsh-tui@$TuiVersion 已安装（@deepseek-ai/dsh 更新被跳过，见日志提示）" }
    }
    Set-Progress 'Harness 与 TUI 安装完成' 45

    # 3) pnpm + dsh-tui profile
    if (-not $OnlyConfig -and -not $SkipTuiSetup) {
        Set-Progress '创建 TUI profile（dsh-tui）' 50
        if (-not (Ensure-Pnpm)) { return @{ Ok = $false; Error = 'pnpm 安装失败，请手动执行 npm install -g pnpm 后重试' } }
        if (-not (Install-TuiProfile -DshHome $dshHome -TuiVersion $TuiVersion)) { return @{ Ok = $false; Error = 'dsh-tui profile 安装失败（详见上方日志）' } }
        $summary += "profile '$PROFILE_NAME' 已就绪"
    }

    # 4) 校验 API Key
    if (-not $NoValidate) {
        Set-Progress '校验 API Key' 72
        if ([string]::IsNullOrWhiteSpace($Key)) { return @{ Ok = $false; Error = '请填写 DeepSeek API Key（在 platform.deepseek.com 的 API Keys 页面创建）' } }
        Write-Log "正在校验 API Key（$Base）…"
        $test = Test-ApiKey -Key $Key.Trim() -Base $Base
        Write-Log $test.Message
        if (-not $test.Ok) { return @{ Ok = $false; Error = $test.Message } }
        # 把接口返回的真实模型列表补充到 GUI 的"默认模型"下拉（GUI 模式；Headless 时 $script:InstallProgress 为 $null）
        $prog = $script:InstallProgress
        if ($prog -and $test.Models -and @($test.Models).Count -gt 0 -and -not $prog.Models) {
            $prog.Models = @($test.Models)
        }
        $summary += 'API Key 校验通过'
    }

    Set-Progress '写入凭证与设置' 82

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

    Set-Progress '写入 TUI 配置（默认模型 / 推理强度 / 流畅模式）' 88

    # 7) TUI 覆盖层：默认模型 / 推理强度 / 流畅模式
    #    模型与推理强度不依赖流畅模式勾选（勾选只控制性能项）；
    #    configure.bat（-ConfigureOnly）同样写入，用于改模型/推理强度。
    $overlaySmooth = $Smooth
    if ($OnlyConfig) {
        # configure.bat 只改配置：保持已有流畅模式状态（配置窗口里该勾选框不可见）
        $existingPatch = Join-Path $dshHome "profiles\$PROFILE_NAME\cordis.patch.yml"
        if (Test-Path $existingPatch) {
            $overlaySmooth = ((Get-Content $existingPatch -Raw) -match 'publishIntervalMs')
        } else {
            $overlaySmooth = $false
        }
    }
    if (Write-TuiOverlay -DshHome $dshHome -Effort $Effort -Model $Model -Smooth $overlaySmooth) {
        if ($overlaySmooth) { $summary += '流畅模式已启用' }
        if ($Model -match '^[A-Za-z0-9_\-\.:/+]+$') { $summary += "默认模型 $Model" }
        if ($Effort -in @('off', 'low', 'high', 'max')) { $summary += "推理强度 $Effort" }
    }

    Set-Progress '创建启动器与快捷方式' 92

    # 8) 启动器 + 快捷方式
    if (-not $OnlyConfig) {
        Install-Launchers -DshHome $dshHome | Out-Null
        if ($MakeShortcut -and -not $NoShortcut) {
            if (New-DesktopShortcut -DshHome $dshHome) {
                $summary += "桌面快捷方式已创建"
            } else {
                $summary += '桌面快捷方式创建失败（不影响使用；可手动在桌面建一个指向 launchers\dsh-tui.bat 的快捷方式）'
            }
        }
    }

    # 9) 启动 TUI
    if ($Launch -and -not $NoLaunch -and -not $OnlyConfig) {
        Set-Progress '准备启动 TUI' 96
        Start-Tui -LauncherBat (Join-Path $dshHome 'launchers\dsh-tui.bat') | Out-Null
    }

    Set-Progress '安装完成' 100
    $summaryText = $summary -join '；'
    return @{ Ok = $true; Summary = $summaryText; DshHome = $dshHome; CredsPath = $credsPath }
}
#endregion

#region 图形窗口（WinForms）
function Show-ConfigWindow {
    param([bool]$OnlyConfig, [string]$TuiVersion)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # "TUI 版本"下拉的选项模型（显示名 / 实际值分离），同一进程只定义一次
    if (-not ('DshOneClick.TuiVersionItem' -as [type])) {
        Add-Type -TypeDefinition @'
namespace DshOneClick {
    public class TuiVersionItem {
        public string Label;
        public string Value;
        public TuiVersionItem(string label, string value) { Label = label; Value = value; }
        public override string ToString() { return Label; }
    }
}
'@
    }

    $script:workerBusy = $false

    $form = New-Object System.Windows.Forms.Form
    $form.Text = if ($OnlyConfig) { 'DeepSeek Harness TUI - 配置脚本' } else { 'DeepSeek Harness TUI - 安装脚本' }
    $form.Size = New-Object System.Drawing.Size(600, 620)
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = if ($OnlyConfig) { 'DeepSeek Harness TUI 配置脚本' } else { 'DeepSeek Harness TUI 安装脚本' }
    $lblTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 14, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = New-Object System.Drawing.Point(16, 14)
    $lblTitle.AutoSize = $true

    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Text = if ($OnlyConfig) {
        '修改配置立即生效（dsh 每次请求实时解析凭证与设置，无需重启）。'
    } else {
        '只需填写 DeepSeek API Key，其余全部自动完成。'
    }
    $lblHint.ForeColor = [System.Drawing.Color]::Gray
    $lblHint.Location = New-Object System.Drawing.Point(16, 40)
    $lblHint.AutoSize = $true

    $grpConn = New-Object System.Windows.Forms.GroupBox
    $grpConn.Text = '连接配置（对应 dsh-llm-deepseek 的凭证与设置）'
    $grpConn.Location = New-Object System.Drawing.Point(16, 68)
    $grpConn.Size = New-Object System.Drawing.Size(552, 158)

    $lblKey = New-Object System.Windows.Forms.Label
    $lblKey.Text = 'DeepSeek API Key *'
    $lblKey.Location = New-Object System.Drawing.Point(14, 26)
    $lblKey.AutoSize = $true
    $txtKey = New-Object System.Windows.Forms.TextBox
    $txtKey.Location = New-Object System.Drawing.Point(160, 22)
    $txtKey.Size = New-Object System.Drawing.Size(372, 23)
    $txtKey.PasswordChar = '●'

    $lblBase = New-Object System.Windows.Forms.Label
    $lblBase.Text = '接口地址 Base URL'
    $lblBase.Location = New-Object System.Drawing.Point(14, 56)
    $lblBase.AutoSize = $true
    $txtBase = New-Object System.Windows.Forms.TextBox
    $txtBase.Text = 'https://api.deepseek.com'
    $txtBase.Location = New-Object System.Drawing.Point(160, 52)
    $txtBase.Size = New-Object System.Drawing.Size(372, 23)

    $lblEffort = New-Object System.Windows.Forms.Label
    $lblEffort.Text = '推理强度 Reasoning Effort'
    $lblEffort.Location = New-Object System.Drawing.Point(14, 86)
    $lblEffort.AutoSize = $true
    $cmbEffort = New-Object System.Windows.Forms.ComboBox
    $cmbEffort.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $cmbEffort.Location = New-Object System.Drawing.Point(160, 82)
    $cmbEffort.Size = New-Object System.Drawing.Size(150, 23)
    foreach ($it in @('默认（不改动）', 'off', 'low', 'high', 'max')) { [void]$cmbEffort.Items.Add($it) }
    $cmbEffort.SelectedIndex = 0

    $lblModel = New-Object System.Windows.Forms.Label
    $lblModel.Text = '默认模型 Model'
    $lblModel.Location = New-Object System.Drawing.Point(14, 116)
    $lblModel.AutoSize = $true
    $cmbModel = New-Object System.Windows.Forms.ComboBox
    $cmbModel.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown   # 可编辑，支持自定义模型名
    $cmbModel.Location = New-Object System.Drawing.Point(160, 112)
    $cmbModel.Size = New-Object System.Drawing.Size(372, 23)
    foreach ($it in @('deepseek-v4-flash', 'deepseek-v4-pro', 'deepseek-v4-flash-vision-exp')) { [void]$cmbModel.Items.Add($it) }
    $cmbModel.Text = 'deepseek-v4-flash'

    $grpOpt = New-Object System.Windows.Forms.GroupBox
    $grpOpt.Text = '安装选项'
    $grpOpt.Location = New-Object System.Drawing.Point(16, 234)
    $grpOpt.Size = New-Object System.Drawing.Size(552, 132)
    $lblTuiVer = New-Object System.Windows.Forms.Label
    $lblTuiVer.Text = 'TUI 版本'
    $lblTuiVer.Location = New-Object System.Drawing.Point(14, 24)
    $lblTuiVer.AutoSize = $true
    $cmbTuiVer = New-Object System.Windows.Forms.ComboBox
    $cmbTuiVer.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $cmbTuiVer.Location = New-Object System.Drawing.Point(110, 20)
    $cmbTuiVer.Size = New-Object System.Drawing.Size(260, 23)
    [void]$cmbTuiVer.Items.Add((New-Object DshOneClick.TuiVersionItem -ArgumentList @("稳定版 0.9.3（推荐）", "0.9.3")))
    [void]$cmbTuiVer.Items.Add((New-Object DshOneClick.TuiVersionItem -ArgumentList @("尝鲜版 latest（beta 预览）", "latest")))
    $cmbTuiVer.SelectedIndex = if ($TuiVersion -eq 'latest') { 1 } else { 0 }
    $chkSmooth = New-Object System.Windows.Forms.CheckBox
    $chkSmooth.Text = '流畅模式（降低状态行刷新率，减少卡顿）'
    $chkSmooth.Location = New-Object System.Drawing.Point(14, 46)
    $chkSmooth.Size = New-Object System.Drawing.Size(520, 20)
    $chkSmooth.Checked = $true
    $chkShortcut = New-Object System.Windows.Forms.CheckBox
    $chkShortcut.Text = '创建桌面快捷方式'
    $chkShortcut.Location = New-Object System.Drawing.Point(14, 68)
    $chkShortcut.AutoSize = $true
    $chkShortcut.Checked = $true
    $chkLaunch = New-Object System.Windows.Forms.CheckBox
    $chkLaunch.Text = '安装完成后自动启动 TUI'
    $chkLaunch.Location = New-Object System.Drawing.Point(14, 90)
    $chkLaunch.AutoSize = $true
    $chkLaunch.Checked = $true
    if ($OnlyConfig) { $grpOpt.Visible = $false }

    $lblLogTitle = New-Object System.Windows.Forms.Label
    $lblLogTitle.Text = '安装日志'
    $lblLogTitle.Location = New-Object System.Drawing.Point(16, 374)
    $lblLogTitle.AutoSize = $true
    $txtLog = New-Object System.Windows.Forms.RichTextBox
    $txtLog.Location = New-Object System.Drawing.Point(16, 396)
    $txtLog.Size = New-Object System.Drawing.Size(552, 92)
    $txtLog.ReadOnly = $true
    $txtLog.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $txtLog.ForeColor = [System.Drawing.Color]::FromArgb(200, 230, 200)
    $txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
    $txtLog.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = '就绪'
    $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(60, 120, 200)
    $lblStatus.Location = New-Object System.Drawing.Point(16, 494)
    $lblStatus.AutoSize = $true

    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Location = New-Object System.Drawing.Point(16, 514)
    $progress.Size = New-Object System.Drawing.Size(552, 12)
    $progress.Style = [System.Windows.Forms.ProgressBarStyle]::Blocks   # 确定进度条：随安装步骤填充
    $progress.Minimum = 0
    $progress.Maximum = 100
    $progress.Value = 0
    $progress.Visible = $false

    $btnInstall = New-Object System.Windows.Forms.Button
    $btnInstall.Text = if ($OnlyConfig) { '保存配置' } else { '一键安装' }
    $btnInstall.Location = New-Object System.Drawing.Point(180, 536)
    $btnInstall.Size = New-Object System.Drawing.Size(110, 30)
    $btnInstall.BackColor = [System.Drawing.Color]::FromArgb(77, 171, 247)
    $btnInstall.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat

    $btnTest = New-Object System.Windows.Forms.Button
    $btnTest.Text = '仅测试连接'
    $btnTest.Location = New-Object System.Drawing.Point(300, 536)
    $btnTest.Size = New-Object System.Drawing.Size(110, 30)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '取消'
    $btnCancel.Location = New-Object System.Drawing.Point(420, 536)
    $btnCancel.Size = New-Object System.Drawing.Size(90, 30)

    $form.Controls.AddRange(@($lblTitle, $lblHint, $grpConn, $grpOpt, $lblLogTitle, $txtLog, $lblStatus, $progress, $btnInstall, $btnTest, $btnCancel))
    $grpConn.Controls.AddRange(@($lblKey, $txtKey, $lblBase, $txtBase, $lblEffort, $cmbEffort, $lblModel, $cmbModel))
    $grpOpt.Controls.AddRange(@($lblTuiVer, $cmbTuiVer, $chkSmooth, $chkShortcut, $chkLaunch))

    # 悬停提示：替代被压缩掉的灰色说明行，不占窗口空间
    $tip = New-Object System.Windows.Forms.ToolTip
    $tip.SetToolTip($txtKey, '在 platform.deepseek.com → API Keys 创建（sk- 开头）')
    $tip.SetToolTip($txtBase, '默认官方接口；使用 OpenAI 兼容网关/中转时改为自己的地址（如 https://api.deepseek.com/v1）')
    $tip.SetToolTip($cmbTuiVer, '稳定版 0.9.3 低风险；latest 为上游 beta 预览（版本以 npm latest 标签为准），含 /vim、/resume 大改等新特性')
    $tip.SetToolTip($cmbModel, '默认 deepseek-v4-flash；可直接输入任意模型名（需在该接口的模型列表中，否则 TUI 会回落默认模型）')

    # ---- 预载现有配置：configure.bat 重开时不显示成默认值，避免保存时把已有的
    #      默认模型 / 推理强度 / 接口地址悄悄改回默认 ----
    $preLoadHome = Get-DshHome
    $prePatch = Join-Path $preLoadHome "profiles\$PROFILE_NAME\cordis.patch.yml"
    if (Test-Path $prePatch) {
        $preTxt = Get-Content $prePatch -Raw
        if ($preTxt -match '(?m)^\s*model:\s*([^\s#]+)') { $cmbModel.Text = $Matches[1].Trim("'", '"') }
        if ($preTxt -match '(?m)^\s*effort:\s*([^\s#]+)') {
            $preEffIdx = $cmbEffort.Items.IndexOf($Matches[1].Trim("'", '"'))
            if ($preEffIdx -gt 0) { $cmbEffort.SelectedIndex = $preEffIdx }
        }
    }
    $preSettings = Join-Path $preLoadHome 'settings.yaml'
    if (Test-Path $preSettings) {
        $preSTxt = Get-Content $preSettings -Raw
        if ($preSTxt -match '(?m)^\s*baseURL:\s*([^\s#]+)') { $txtBase.Text = $Matches[1].Trim("'", '"') }
    }

    # 用接口返回的真实模型列表补充"默认模型"下拉（保留用户手输值）
    function Update-ModelList {
        param([object[]]$Models)
        if (-not $Models -or $Models.Count -eq 0) { return }
        $keep = $cmbModel.Text
        $cmbModel.Items.Clear()
        foreach ($mm in $Models) { [void]$cmbModel.Items.Add($mm) }
        if ($keep -eq '') { $cmbModel.Text = $Models[0] }
        elseif ($keep -eq 'deepseek-v4-flash' -and -not ($Models -contains $keep)) { $cmbModel.Text = $Models[0] }
        else { $cmbModel.Text = $keep }
    }

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

    # ---- 安装进度刷新（替代 BackgroundWorker，PS 5.1 下后台线程无 runspace）----
    # 独立 runspace 的日志进入线程安全队列，UI 定时器在这里刷新到文本框，
    # 并镜像到 install.bat 弹出的终端窗口（[Console]::WriteLine 任意线程安全）。
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 150
    $timer.Add_Tick({
        $line = $null
        while ($script:LogQueue.TryDequeue([ref]$line)) {
            $txtLog.AppendText($line + "`r`n")
            $txtLog.SelectionStart = $txtLog.TextLength
            $txtLog.ScrollToCaret()
            try { [Console]::WriteLine($line) } catch { }
        }
        # 实时步骤状态 + 确定进度（安装流程通过 Set-Progress 写入共享对象）
        if ($script:InstallProgress -and $script:InstallProgress.Step -ne '') {
            $lblStatus.Text = $script:InstallProgress.Step
            $v = $script:InstallProgress.Percent
            if ($v -gt $progress.Value) { $progress.Value = $v }
            # 校验通过后把接口返回的真实模型列表补充到"默认模型"下拉（只填一次）
            if ($script:InstallProgress.Models -and @($script:InstallProgress.Models).Count -gt 0) {
                Update-ModelList @($script:InstallProgress.Models)
                $txtLog.AppendText('已按接口返回更新模型下拉' + "`r`n")
                $script:InstallProgress.Models = $null
            }
        }

        if ($script:InstallState.Done -and -not $script:InstallFinalized) {
            $script:InstallFinalized = $true
            $timer.Stop()
            Set-Busy $false
            $st = $script:InstallState
            if ($st.Ok) {
                $msg = "安装完成！`n`n$($st.Summary)`n`n" +
                       "启动方式：双击桌面快捷方式，或在终端运行 dsh-tui（恢复上次会话：dsh-tui --resume）`n" +
                       "凭证文件: $($st.CredsPath)`n`n" +
                       "使用说明（/btw 等指令速查）：仓库 docs/使用说明.md`n" +
                       "提示：以后改 API Key 可重新运行 install.bat，或双击 configure.bat。"
                # 汇总同时镜像到终端：install.bat 窗口里也能看到安装结果与快捷方式位置
                try {
                    [Console]::WriteLine('')
                    [Console]::WriteLine('==== 安装完成 ====')
                    [Console]::WriteLine($st.Summary)
                    [Console]::WriteLine("DSH 家目录: $($st.DshHome)")
                    [Console]::WriteLine("桌面快捷方式: $(Join-Path ([Environment]::GetFolderPath('Desktop')) 'DeepSeek Harness TUI.lnk')（若不存在，请看上方日志中的快捷方式相关行）")
                } catch { }
                [System.Windows.Forms.MessageBox]::Show($form, $msg, 'DeepSeek Harness TUI 安装脚本', 'OK', 'Information') | Out-Null
                if ($chkLaunch.Checked -and -not $OnlyConfig -and $st.DshHome) {
                    $bat = Join-Path $st.DshHome 'launchers\dsh-tui.bat'
                    if (Test-Path $bat) { Start-Process -FilePath $bat }
                }
                $form.Close()
            } else {
                [System.Windows.Forms.MessageBox]::Show($form, $st.Error, '未能完成', 'OK', 'Warning') | Out-Null
            }
            try {
                if ($script:InstallPs) {
                    $null = $script:InstallPs.EndInvoke($script:InstallAsync)
                    $script:InstallPs.Dispose()
                    $script:InstallPs.Runspace.Dispose()
                    $script:InstallPs = $null
                }
            } catch { }
        }
    })
    $timer.Start()

    $btnInstall.Add_Click({
        if ($script:workerBusy) { return }
        if ([string]::IsNullOrWhiteSpace($txtKey.Text)) {
            [System.Windows.Forms.MessageBox]::Show($form, '请先填写 DeepSeek API Key', '提示', 'OK', 'Warning') | Out-Null
            return
        }
        Set-Busy $true
        $txtLog.Clear()
        if ($script:InstallProgress) { $script:InstallProgress.Step = '准备安装…'; $script:InstallProgress.Percent = 0 }
        $lblStatus.Text = '准备安装…'
        $progress.Value = 0
        Start-InstallWorker -Key $txtKey.Text -Base $txtBase.Text `
            -Effort $(if ($cmbEffort.SelectedIndex -gt 0) { $cmbEffort.SelectedItem } else { '' }) `
            -Model $cmbModel.Text `
            -TuiVer $(if ($cmbTuiVer.SelectedItem) { $cmbTuiVer.SelectedItem.Value } else { $DEFAULT_TUI_VERSION }) `
            -MakeShortcut $chkShortcut.Checked -Launch $chkLaunch.Checked -Smooth $chkSmooth.Checked -OnlyConfig $OnlyConfig
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
        $lblStatus.Text = '正在测试连接…'
        $form.Refresh()
        $r = Test-ApiKey -Key $txtKey.Text.Trim() -Base $txtBase.Text
        $txtLog.AppendText($r.Message + "`r`n")
        $lblStatus.Text = if ($r.Ok) { '连接成功' } else { '连接失败' }
        if ($r.Ok -and $r.Models -and @($r.Models).Count -gt 0) {
            Update-ModelList @($r.Models)
            $shownModels = @($r.Models | Select-Object -First 8) -join ', '
            if (@($r.Models).Count -gt 8) { $shownModels += '…' }
            $txtLog.AppendText(('已按接口返回更新模型下拉：' + $shownModels) + "`r`n")
        }
        Set-Busy $false
        [System.Windows.Forms.MessageBox]::Show($form, $r.Message, '连接测试', 'OK', $(if ($r.Ok) { 'Information' } else { 'Error' })) | Out-Null
    })

    $btnCancel.Add_Click({ $form.Close() })
    $form.Add_Shown({ $form.Activate(); $txtKey.Focus() })
    [void]$form.ShowDialog()
}
#endregion

#region 入口
if (-not $LibraryMode) {
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
        $result = Invoke-InstallFlow -Key $ApiKey -Base $BaseUrl -Effort $ReasoningEffort -Model $Model -TuiVersion $TuiVersion `
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

    Show-ConfigWindow -OnlyConfig $ConfigureOnly -TuiVersion $TuiVersion
}
#endregion
