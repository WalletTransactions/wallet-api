@echo off
REM Starts the already-installed "wallet-api" service.

net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

net start wallet-api
pause
