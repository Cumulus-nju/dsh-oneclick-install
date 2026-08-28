@echo off
title DeepSeek Harness - Configure
rem ============================================================
rem  重新打开配置窗口：修改 API Key / Base URL / 推理强度
rem  （dsh 每次请求实时解析凭证与设置，保存后立即生效）
rem ============================================================
powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0install.ps1" -ConfigureOnly %*
if errorlevel 1 pause
