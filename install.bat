@echo off
title DeepSeek Harness - One-Click Installer
rem ============================================================
rem  DeepSeek Harness 一键安装入口
rem  双击本文件即可：弹出配置窗口 -> 填写 API Key -> 一键安装
rem ============================================================
powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0install.ps1" %*
if errorlevel 1 (
  echo.
  echo 安装未完成，请查看上方日志。
  pause
)
