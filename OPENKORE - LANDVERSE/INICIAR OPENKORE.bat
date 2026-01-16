@echo off

:: Enable delayed expansion for real-time variable updates inside loops
setlocal enabledelayedexpansion

:: Check for Admin rights
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting Administrator privileges...
    :: Re-launch this script as Administrator
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: Save current cwd
cd /d "%~dp0"

:: Run the Python launcher script
if exist launcher.py (
    python launcher.py
) else (
    echo launcher.py not found!
    echo Please make sure launcher.py is in the same folder.
    pause
)