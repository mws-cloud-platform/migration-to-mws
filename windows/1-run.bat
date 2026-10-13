@echo off
chcp 65001 >nul
title MWS Migration Toolkit v4.1
cls

echo ====================================================================
echo  MWS Migration Toolkit v4.1
echo  VMware ESXi  ^>  KVM (MWS Cloud Platform)
echo ====================================================================
echo.
echo  Entry point: 1-run.bat
echo  This will launch 2-Orchestrator.ps1 which detects state and
echo  runs the appropriate scripts.
echo.
echo  Expected workflow:
echo    [STAGE 1 - VMware]  3-Diagnostic + 4-Migration
echo    [EXPORT]            export disk, upload to S3, get PreSigned URL
echo    [STAGE 2 - MWS]     import image, create VM, boot
echo    [STAGE 3 - KVM]     5-Post-Migration [+ optional 6, 7]
echo.
echo  NOTE: Run as Administrator. Without admin rights the script
echo  will exit with an error.
echo.

REM --- Check that we run with admin rights ---
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] This script must be run as Administrator.
    echo Right-click 1-run.bat  ^>  Run as administrator.
    echo.
    pause
    exit /b 1
)

echo [OK] Administrator rights confirmed.
echo.
echo Launching orchestrator...
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0\2-Orchestrator.ps1"

echo.
echo Orchestrator finished.
pause