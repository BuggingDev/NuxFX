@echo off
rem SPDX-License-Identifier: GPL-3.0-or-later
rem Copyright (C) 2026 NuxFX contributors
rem Double-click installer for Windows: runs install.sh inside WSL2 (Ubuntu).
rem Needs NuxFX to be unpacked or cloned somewhere on this PC.
setlocal
where wsl.exe >nul 2>nul
if errorlevel 1 (
    echo WSL is not installed. Open PowerShell as administrator and run:
    echo     wsl --install -d Ubuntu-24.04
    echo Restart if asked, then double-click this file again.
    pause
    exit /b 1
)
wsl.exe -e true >nul 2>nul
if errorlevel 1 (
    echo No Linux distribution is installed in WSL. Open PowerShell as administrator and run:
    echo     wsl --install -d Ubuntu-24.04
    echo Finish the Ubuntu first-run setup, then double-click this file again.
    pause
    exit /b 1
)
rem The NuxFX folder, as a Linux path. install.sh asks for sudo and the After Effects folder.
set "HERE=%~dp0"
wsl.exe -e bash -lc "cd \"$(wslpath -u '%HERE:\=/%')\" && bash ./install.sh %*"
echo.
pause
