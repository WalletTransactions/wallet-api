@echo off
REM Stops the "wallet-api" service (does not remove it).

net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

net stop wallet-api
pause
