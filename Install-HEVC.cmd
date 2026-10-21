@echo off
setlocal
chcp 65001 >nul 2>&1
set "SCRIPT=%~dp0Install-HEVC.ps1"
if not exist "%SCRIPT%" (
    echo Install-HEVC.ps1 was not found next to this file.
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "RC=%ERRORLEVEL%"
if "%~1"=="" pause
exit /b %RC%
