@echo off
REM Runs wallet_api.exe directly in the console, no service install -
REM handy for a quick check. Needs .env next to it (see .env.example).

cd /d "%~dp0"
if not exist ".env" (
    echo WARNING: .env not found in %~dp0
    echo Copy .env.example to .env and fill it in before running.
    echo.
)
wallet_api.exe
pause
