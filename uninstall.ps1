<#
================================================================================
 DeepSeek Harness TUI 一键安装器 - 卸载脚本
--------------------------------------------------------------------------------
  移除：
   1. 桌面快捷方式 "DeepSeek Harness TUI.lnk"
   2. $DSH_HOME/launchers/dsh-tui.bat（本安装器写入的启动器）
  可选（需确认）：
   3. npm 全局卸载 @deepseek-ai/dsh 与 @deepseek-harness-tui/dsh-tui
   4. 删除 dsh-tui profile（$DSH_HOME/profiles/dsh-tui）
   5. 删除整个 DSH 家目录（会连同凭证、会话一起删除！）
================================================================================
#>
[CmdletBinding()]
param(
    [switch]$RemoveAll,      # 跳过确认，执行全部卸载（含 npm 卸载与 profile 删除）
    [switch]$PurgeHome       # 连同 DSH 家目录一起删除（危险）
)

$dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HOME '.dsh' }
Write-Host "DSH 家目录: $dshHome"

# 1) 桌面快捷方式
$desktop = [Environment]::GetFolderPath('Desktop')
$lnk = Join-Path $desktop 'DeepSeek Harness TUI.lnk'
if (Test-Path $lnk) { Remove-Item $lnk -Force; Write-Host "已删除快捷方式: $lnk" }

# 2) 启动器（bat + 图标），并清理启动器目录
$launcherDir = Join-Path $dshHome 'launchers'
if (Test-Path $launcherDir) {
    foreach ($f in @('dsh-tui.bat', 'deepseek.ico')) {
        $fp = Join-Path $launcherDir $f
        if (Test-Path $fp) { Remove-Item $fp -Force; Write-Host "已删除: $fp" }
    }
    # 目录里若只剩用户自己的文件则保留；否则删除空目录
    Remove-Item $launcherDir -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $launcherDir)) { Write-Host "已清理启动器目录: $launcherDir" }
}

# 3) npm 卸载
if ($RemoveAll) {
    Write-Host '正在 npm 全局卸载 @deepseek-ai/dsh 与 @deepseek-harness-tui/dsh-tui ...'
    npm uninstall -g @deepseek-ai/dsh @deepseek-harness-tui/dsh-tui 2>$null
    Write-Host '已卸载全局包'
} else {
    Write-Host ''
    $ans = Read-Host '是否同时卸载 @deepseek-ai/dsh 与 @deepseek-harness-tui/dsh-tui 全局包？(y/N)'
    if ($ans -match '^[yY]') {
        npm uninstall -g @deepseek-ai/dsh @deepseek-harness-tui/dsh-tui 2>$null
        Write-Host '已卸载全局包'
    }
}

# 4) 删除 dsh-tui profile
$profile = Join-Path $dshHome 'profiles\dsh-tui'
if (Test-Path $profile) {
    if ($RemoveAll) {
        Remove-Item $profile -Recurse -Force
        Write-Host "已删除 profile: $profile"
    } else {
        Write-Host ''
        $ans = Read-Host "是否删除 TUI profile？($profile) (y/N)"
        if ($ans -match '^[yY]') {
            Remove-Item $profile -Recurse -Force
            Write-Host "已删除 profile: $profile"
        }
    }
}

# 5) 删除家目录
if ($PurgeHome -and (Test-Path $dshHome)) {
    Write-Host "警告：即将删除整个 $dshHome （包含 API Key 凭证与全部会话数据）！"
    $ans = Read-Host '确认删除？输入 DELETE 确认'
    if ($ans -eq 'DELETE') {
        Remove-Item $dshHome -Recurse -Force
        Write-Host '已删除 DSH 家目录'
    }
} else {
    Write-Host "凭证与配置保留在 $dshHome（如需彻底删除请加 -PurgeHome 参数）"
}

Write-Host ''
Write-Host '卸载完成。'
