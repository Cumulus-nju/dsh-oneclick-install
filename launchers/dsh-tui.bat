@echo off
title DeepSeek Harness TUI
rem --- One-click launcher for the DeepSeek Harness TUI (dsh-tui) ---
rem Usage: dsh-tui.bat [--resume]   (--resume resumes the last session)
if exist "%APPDATA%\npm\dsh-tui.cmd" (
  set "TUI_CMD=%APPDATA%\npm\dsh-tui.cmd"
) else (
  set "TUI_CMD=dsh-tui"
)
echo Starting DeepSeek Harness TUI... (Ctrl+C or /exit to quit)
"%TUI_CMD%" %*
pause
