#!/usr/bin/env bash
# Минтит токены для нагрузочного контура wallet-api (см. README.md) — без
# отдельного C++ seed-инструмента: /sync/push сам провижинит леджер/устройство
# лениво (provisioning::ensure_identity) на первый же батч, так что сеять
# заранее нечего — k6-сценарии сами создадут иконку/валюту/счета один раз
# (см. setup() в scenario_push_*.js).
#
# Два файла на выходе, под два разных риска:
#   - data/independent_tokens.json — LOADTEST_USERS РАЗНЫХ пользователей
#     (разный sub), у каждого один device_id — независимые леджеры,
#     показывает выигрыш пула на параллельных, НЕ пересекающихся нагрузках.
#   - data/same_ledger_tokens.json — LOADTEST_RACE_DEVICES токенов ОДНОГО И
#     ТОГО ЖЕ пользователя (один sub — один леджер), но с РАЗНЫМИ device_id —
#     имитирует несколько устройств одного аккаунта, синкающихся в ОДИН
#     леджер одновременно (то самое offline-first многоустройство, см.
#     org/docs/TODO_mobile_sync.md) — именно здесь, а не на независимых
#     леджерах, реально проверяются гонки/дедлоки конкурентной записи в одни
#     и те же строки (change_stream, next_seq(ledger_id), account этого
#     леджера).
#
# Требует: mint_loadtest_token уже собран (см. ../../wallet-report/loadtest/
# run.sh — тот же бинарь, собирается один раз, переиспользуется отсюда) —
# если нет, соберёт сам.
set -euo pipefail

export MSYS_NO_PATHCONV=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
GA_DIR="$WORKSPACE_DIR/google-auth"
DATA_DIR="$SCRIPT_DIR/data"
mkdir -p "$DATA_DIR"

PEM_PATH="$GA_DIR/jwt_signing_key.pem"
if [[ ! -f "$PEM_PATH" ]]; then
    echo "Не найден $PEM_PATH — см. wallet-infra/README.md, шаг openssl genrsa." >&2
    exit 1
fi

# Движок контейнеров — podman (изначальная разработка) или docker (на этой
# машине podman не установлен вовсе) — берём тот, что реально есть в PATH.
if command -v podman >/dev/null 2>&1; then
    ENGINE=podman
elif command -v docker >/dev/null 2>&1; then
    ENGINE=docker
else
    echo "Не нашёл ни podman, ни docker в PATH." >&2
    exit 1
fi

# Тот же volume, что и ../../wallet-report/loadtest/run.sh (см. его
# комментарий про NTFS/exFAT/fuseblk и потерю exec-бита у бинарников,
# собранных прямо на смонтированный host-путь) — один и тот же
# mint_loadtest_token, собранный любым из двух скриптов, виден другому.
GA_BUILD_VOL="google_auth_loadtest_build"

need_build=1
if "$ENGINE" volume inspect "$GA_BUILD_VOL" >/dev/null 2>&1; then
    if "$ENGINE" run --rm -v "$GA_BUILD_VOL:/gabin" debian:bookworm-slim \
        test -x /gabin/mint_loadtest_token; then
        need_build=0
    fi
fi
[[ "${LOADTEST_FORCE_REBUILD:-}" == "1" ]] && need_build=1

if [[ "$need_build" == "1" ]]; then
    echo "==> Собираю mint_loadtest_token (первый раз — дольше, apt-get)"
    "$ENGINE" run --rm -v "$GA_DIR:/ga" -v "$GA_BUILD_VOL:/ga/build-loadtest" debian:bookworm-slim bash -c '
        set -e
        apt-get update -qq
        apt-get install -y --no-install-recommends -qq build-essential cmake libssl-dev libpq-dev pkg-config >/dev/null
        cd /ga
        cmake -B build-loadtest -DGOOGLE_AUTH_BUILD_TESTS=OFF -DGOOGLE_AUTH_BUILD_LOADTEST_TOOLS=ON >/tmp/ga_cfg.log 2>&1 \
            || { cat /tmp/ga_cfg.log; exit 1; }
        cmake --build build-loadtest --target mint_loadtest_token -j"$(nproc)"
        '
else
    echo "==> mint_loadtest_token уже собран (docker volume) — LOADTEST_FORCE_REBUILD=1 для пересборки"
fi

# uuidgen отсутствует на голом Git Bash (Windows) и на нём же нет
# /proc/sys/kernel/random/uuid (это Linux-путь) — python3 как переносимый
# запасной вариант, чистый bash — последний резерв (не криптографически
# случаен, но для уникальности логинов/устройств нагрузочного теста и не
# нужно).
gen_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import uuid; print(uuid.uuid4())"
    else
        printf '%04x%04x-%04x-4%03x-%04x-%04x%04x%04x\n' \
            "$RANDOM" "$RANDOM" "$RANDOM" "$((RANDOM % 4096))" \
            "$((RANDOM % 16384 + 32768))" "$RANDOM" "$RANDOM" "$RANDOM"
    fi
}

LOADTEST_USERS="${LOADTEST_USERS:-8}"
LOADTEST_RACE_DEVICES="${LOADTEST_RACE_DEVICES:-6}"
TTL_SECS="${TTL_SECS:-86400}"

mint_one() {
    # $1=sub $2=email $3=device_id
    "$ENGINE" run --rm -v "$GA_DIR:/ga" -v "$GA_BUILD_VOL:/ga/build-loadtest" -e TTL_SECS="$TTL_SECS" \
        -e SUB="$1" -e EMAIL="$2" -e DEV="$3" debian:bookworm-slim bash -c '
        apt-get update -qq && apt-get install -y --no-install-recommends -qq libssl3 >/dev/null
        /ga/build-loadtest/mint_loadtest_token --pem /ga/jwt_signing_key.pem \
            --sub "$SUB" --email "$EMAIL" --device-id "$DEV" --platform other --ttl-secs "$TTL_SECS"
        ' 2>/dev/null
}

echo "==> Независимые пользователи (LOADTEST_USERS=$LOADTEST_USERS, каждый — своё устройство/леджер)"
out="$DATA_DIR/independent_tokens.json"
echo "[" > "$out.tmp"
for i in $(seq 1 "$LOADTEST_USERS"); do
    sub="$(gen_uuid)"
    email="loadtest-api-$i@loadtest.example.com"
    device="$(gen_uuid)"
    token=$(mint_one "$sub" "$email" "$device")
    sep=$([ "$i" -lt "$LOADTEST_USERS" ] && echo "," || echo "")
    printf '  {"user_id": "%s", "token": "%s"}%s\n' "$sub" "$token" "$sep" >> "$out.tmp"
    echo "  токен $i/$LOADTEST_USERS готов"
done
echo "]" >> "$out.tmp"
mv "$out.tmp" "$out"

echo "==> Одна и та же учётка, разные устройства (LOADTEST_RACE_DEVICES=$LOADTEST_RACE_DEVICES, ОДИН леджер)"
race_sub="$(gen_uuid)"
race_email="loadtest-api-race@loadtest.example.com"
out2="$DATA_DIR/same_ledger_tokens.json"
echo "[" > "$out2.tmp"
for i in $(seq 1 "$LOADTEST_RACE_DEVICES"); do
    device="$(gen_uuid)"
    token=$(mint_one "$race_sub" "$race_email" "$device")
    sep=$([ "$i" -lt "$LOADTEST_RACE_DEVICES" ] && echo "," || echo "")
    printf '  {"user_id": "%s", "token": "%s"}%s\n' "$race_sub" "$token" "$sep" >> "$out2.tmp"
    echo "  race-токен $i/$LOADTEST_RACE_DEVICES готов"
done
echo "]" >> "$out2.tmp"
mv "$out2.tmp" "$out2"

echo "==> Готово: $out, $out2"
echo "==> Дальше: k6 (см. README.md, Шаг 2)"
