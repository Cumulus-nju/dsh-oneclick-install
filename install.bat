@echo off
title DeepSeek Harness TUI Installer
rem Set Unicode window title "DeepSeek Harness TUI Installer" via base64 (keeps this file pure ASCII)
powershell.exe -NoProfile -EncodedCommand JABIAG8AcwB0AC4AVQBJAC4AUgBhAHcAVQBJAC4AVwBpAG4AZABvAHcAVABpAHQAbABlAD0AJwBEAGUAZQBwAFMAZQBlAGsAIABIAGEAcgBuAGUAcwBzACAAVABVAEkAIACJW8WIGoEsZycA >nul 2>&1
setlocal EnableExtensions
cd /d "%~dp0"

rem ============================================================
rem  DeepSeek Harness one-click installer (Windows)
rem  Double-click this file: a terminal opens, then a config
rem  window appears. Fill in your API key and click Install.
rem  Progress is mirrored to this terminal window.
rem ============================================================

rem --- install.ps1 must sit next to this file ---
if not exist "%~dp0install.ps1" (
    echo.
    echo [ERROR] install.ps1 not found next to install.bat.
    echo         Keep install.bat and install.ps1 in the same folder.
    echo.
    pause
    exit /b 1
)

rem --- Remove the "downloaded from the internet" block, if any ---
powershell.exe -NoProfile -Command "Unblock-File -Path '%~dp0install.ps1' -ErrorAction SilentlyContinue" >nul 2>&1

echo ================================================================
echo  DeepSeek Harness one-click installer
echo  Folder: %~dp0
echo  A configuration window will open. Progress is also shown here.
echo  Do NOT close this terminal until installation finishes.
echo ================================================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0install.ps1" %*
set "EXITCODE=%ERRORLEVEL%"

echo.
if "%EXITCODE%"=="0" (
    echo [OK] Installer finished. See the summary above.
) else (
    echo [ERROR] Installer exited with code %EXITCODE%. See log above.
    echo If the window closed instantly or nothing happened, try:
    echo   - right-click install.ps1 - Properties - Unblock
    echo   - temporarily disable antivirus, then retry
    echo   - open a cmd window in this folder and run: install.bat
)
echo.
pause
exit /b %EXITCODE%
