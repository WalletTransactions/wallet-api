#!/usr/bin/env bash
# Устанавливает wallet-api как systemd-сервис.
# Запуск: sudo ./install-service.sh [путь-к-бинарнику]
# По умолчанию ищет ./wallet_api рядом со скриптом (например, build/wallet_api,
# если запускать отсюда же).
set -euo pipefail

SERVICE_NAME="wallet-api"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_PATH="${1:-$SCRIPT_DIR/wallet_api}"
INSTALL_DIR="/opt/wallet-api"

if [ "$(id -u)" -ne 0 ]; then
    echo "Нужны права root. Запустите: sudo $0" >&2
    exit 1
fi

if [ ! -x "$BIN_PATH" ]; then
    echo "Не найден исполняемый файл: $BIN_PATH" >&2
    echo "Соберите проект (cmake --build build) или укажите путь первым аргументом:" >&2
    echo "  sudo $0 /path/to/build/wallet_api" >&2
    exit 1
fi

mkdir -p "$INSTALL_DIR"
cp "$BIN_PATH" "$INSTALL_DIR/wallet_api"
chmod +x "$INSTALL_DIR/wallet_api"

if [ -f "$SCRIPT_DIR/.env" ] && [ ! -f "$INSTALL_DIR/.env" ]; then
    cp "$SCRIPT_DIR/.env" "$INSTALL_DIR/.env"
fi
if [ ! -f "$INSTALL_DIR/.env" ]; then
    echo "ВНИМАНИЕ: $INSTALL_DIR/.env не найден — создайте его (см. .env.example)" >&2
    echo "перед первым запуском службы: sudo systemctl start $SERVICE_NAME" >&2
fi

cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=wallet-api (кошельки, своя БД)
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$INSTALL_DIR/.env
ExecStart=$INSTALL_DIR/wallet_api
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}"

echo "Установлено и запущено."
echo "Статус:  systemctl status ${SERVICE_NAME}"
echo "Логи:    journalctl -u ${SERVICE_NAME} -f"
echo "Файлы:   $INSTALL_DIR"
