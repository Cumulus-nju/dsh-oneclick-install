@echo off
title DeepSeek Harness TUI Configure
rem Set Unicode window title "DeepSeek Harness TUI Configure" via base64 (keeps this file pure ASCII)
powershell.exe -NoProfile -EncodedCommand JABIAG8AcwB0AC4AVQBJAC4AUgBhAHcAVQBJAC4AVwBpAG4AZABvAHcAVABpAHQAbABlAD0AJwBEAGUAZQBwAFMAZQBlAGsAIABIAGEAcgBuAGUAcwBzACAAVABVAEkAIABNkW5/GoEsZycA >nul 2>&1
setlocal EnableExtensions
cd /d "%~dp0"

rem ============================================================
rem  Re-open the config window: change API key / base URL /
rem  reasoning effort / model. Settings take effect immediately.
rem ============================================================

if not exist "%~dp0install.ps1" (
    echo.
    echo [ERROR] install.ps1 not found next to configure.bat.
    echo         Keep configure.bat and install.ps1 in the same folder.
    echo.
    pause
    exit /b 1
)

rem --- Remove the "downloaded from the internet" block, if any ---
powershell.exe -NoProfile -Command "Unblock-File -Path '%~dp0install.ps1' -ErrorAction SilentlyContinue" >nul 2>&1

echo ================================================================
echo  DeepSeek Harness - configure existing installation
echo  Folder: %~dp0
echo ================================================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0install.ps1" -ConfigureOnly %*
set "EXITCODE=%ERRORLEVEL%"

echo.
if "%EXITCODE%"=="0" (
    echo [OK] Configuration saved.
) else (
    echo [ERROR] Configure exited with code %EXITCODE%. See log above.
)
echo.
pause
exit /b %EXITCODE%
