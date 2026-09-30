@echo off
REM Installs wallet_api.exe as a Windows service via NSSM.
REM Run this from the folder where wallet_api.exe itself lives (with .env next to it).

setlocal
set SERVICE_NAME=wallet-api
set SCRIPT_DIR=%~dp0
set EXE_PATH=%SCRIPT_DIR%wallet_api.exe

REM --- need admin rights to manage services ---
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Administrator rights required - relaunching elevated...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

if not exist "%EXE_PATH%" (
    echo ERROR: %EXE_PATH% not found
    echo Put install-service.bat next to wallet_api.exe.
    pause
    exit /b 1
)

if not exist "%SCRIPT_DIR%.env" (
    echo WARNING: %SCRIPT_DIR%.env not found
    echo The service will install but crash on start until you create it
    echo (see .env.example in the repo).
    echo.
)

where nssm >nul 2>&1
if %errorlevel% neq 0 (
    echo nssm.exe not found in PATH.
    echo wallet_api.exe is a plain console program, not a Windows service by
    echo itself, so NSSM is needed to wrap it as one.
    echo.
    echo Install it one of these ways, then run install-service.bat again:
    echo   1^) winget install -e --id NSSM.NSSM   ^(open a NEW console window after^)
    echo   2^) download from https://nssm.cc/download and put nssm.exe in this folder
    pause
    exit /b 1
)

echo Installing service "%SERVICE_NAME%"...
nssm install %SERVICE_NAME% "%EXE_PATH%"
nssm set %SERVICE_NAME% AppDirectory "%SCRIPT_DIR%"
nssm set %SERVICE_NAME% DisplayName "wallet-api (кошельки, своя БД)"
nssm set %SERVICE_NAME% Description "Wallet service: create/delete wallets, own Postgres database"
nssm set %SERVICE_NAME% Start SERVICE_AUTO_START
nssm set %SERVICE_NAME% AppStdout "%SCRIPT_DIR%service-stdout.log"
nssm set %SERVICE_NAME% AppStderr "%SCRIPT_DIR%service-stderr.log"
nssm set %SERVICE_NAME% AppRotateFiles 1
nssm set %SERVICE_NAME% AppRotateOnline 1
nssm set %SERVICE_NAME% AppRotateBytes 1048576

echo Starting service...
nssm start %SERVICE_NAME%

echo.
echo Done. Service "%SERVICE_NAME%" installed and started.
echo App log: logs\YYYY-MM-DD-wallet-api.log next to the exe (see LOG_DIR in .env).
echo NSSM fallback logs: service-stdout.log / service-stderr.log
echo Manage it with: start-service.bat / stop-service.bat / uninstall-service.bat
pause
