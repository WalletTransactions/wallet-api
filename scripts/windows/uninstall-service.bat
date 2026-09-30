@echo off
REM Stops and removes the "wallet-api" service (installed by install-service.bat).
REM Does not touch wallet_api.exe or .env.

set SERVICE_NAME=wallet-api

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Administrator rights required - relaunching elevated...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

where nssm >nul 2>&1
if %errorlevel% neq 0 (
    echo nssm.exe not found in PATH - can't remove the service without it.
    echo Install: winget install -e --id NSSM.NSSM
    pause
    exit /b 1
)

echo Stopping and removing service "%SERVICE_NAME%"...
nssm stop %SERVICE_NAME% >nul 2>&1
nssm remove %SERVICE_NAME% confirm

echo Done.
pause
