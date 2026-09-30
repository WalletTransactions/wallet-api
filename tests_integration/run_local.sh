#!/bin/bash
# Прогоняет wallet_api_integration_tests (test_push_batch.cpp/
# test_invites.cpp/test_currency_pairs.cpp) — один рабочий процесс вместо
# ручных шагов из README.md, "Как запустить". Тот же приём, что у
# wallet-report/tests_integration/run_local.sh (сама база — общая, заведена
# один раз любым из двух скриптов, второй её просто переиспользует).
#
# База берётся НЕ отдельным одноразовым контейнером, а отдельной, специально
# заведённой базой (wallet_api_it) в ТОМ ЖЕ кластере Postgres, что уже
# поднят вашим dev-стеком (wallet-infra/compose.yaml, сервис "db") —
# переиспользуем сеть и сам контейнер, которые и так подняты. Настоящие
# данные (база wallet_api) эта тестовая база не трогает — CREATE DATABASE в
# том же кластере даёт полную изоляцию на уровне файлов/каталогов Postgres,
# разница только в том, что не нужно тянуть и поднимать второй Postgres.
#
# ВАЖНО: это по-прежнему тот же Postgres-ИНСТАНС (тот же процесс, тот же
# контейнер), что и у живого dev-стека — не изолированный тестовый контур.
# Совместное падение/перезапуск/апгрейд "db" задевает и тесты, и рабочие
# данные разом; тяжёлый прогон тестов делит с dev-стеком CPU/IO этого же
# процесса Postgres. См. org/docs/TODO_mobile_sync.md, "Открытые вопросы" —
# отдельный, полностью независимый тестовый контур (свой контейнер/сеть, а
# не общая база в общем инстансе) там записан как то, что стоило бы завести,
# но пока не заведено.
#
# Требования: `podman compose --env-file infra/db/.env up -d db` (или
# `docker compose ...` — см. ENGINE ниже) уже выполнен (см.
# wallet-infra/README.md). Первый запуск дольше — собирает тестовый образ;
# повторные быстрее (слои кэшируются, миграции идемпотентны, сами тесты не
# требуют очистки между запусками — см. README.md, "Изоляция" — только
# растёт число строк в wallet_api_it).
set -euo pipefail

# MSYS (Git Bash на Windows) переписывает абсолютные unix-пути в аргументах
# в Windows-пути ещё до того, как они попадут в движок контейнеров — тот же
# приём, что и в infra/db/migrate.sh.
export MSYS_NO_PATHCONV=1

# Движок контейнеров — podman (изначальная разработка) или docker (например,
# BuildPlatform/jenkins/Containerfile ставит только клиент docker, без
# podman — см. BuildPlatform/jobs/wallet-api-integration-tests/Jenkinsfile,
# который зовёт этот скрипт) — тот же приём, что
# wallet-api/loadtest/mint_tokens.sh.
if command -v podman >/dev/null 2>&1; then
    ENGINE=podman
elif command -v docker >/dev/null 2>&1; then
    ENGINE=docker
else
    echo "Не нашёл ни podman, ни docker в PATH." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

IT_DB_NAME=wallet_api_it
TEST_IMAGE=wallet-api-it-tests

ENV_FILE="$WORKSPACE_DIR/wallet-infra/infra/db/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "Не найден $ENV_FILE — сначала: cp infra/db/.env.example infra/db/.env" >&2
    exit 1
fi
set -a
source "$ENV_FILE"
set +a

# --- Найти запущенный контейнер "db" (тот же приём, что в migrate.sh: имя
#     контейнера зависит от имени папки проекта, лейбл — нет; лейбл зависит
#     от того, какой compose-provider реально исполнял `podman compose`/
#     `docker compose`). ---
db_container="$("$ENGINE" ps --filter "label=io.podman.compose.service=db" --format '{{.Names}}' | head -n1)"
if [[ -z "$db_container" ]]; then
    db_container="$("$ENGINE" ps --filter "label=com.docker.compose.service=db" --format '{{.Names}}' | head -n1)"
fi
if [[ -z "$db_container" ]]; then
    echo "Не нашёл запущенный контейнер 'db'. Сначала: $ENGINE compose --env-file infra/db/.env up -d db" >&2
    exit 1
fi
db_network="$("$ENGINE" inspect "$db_container" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}')"
if [[ -z "$db_network" ]]; then
    echo "Не нашёл сеть контейнера '$db_container'." >&2
    exit 1
fi

echo "==> База $IT_DB_NAME (заводим, если ещё нет)"
exists="$("$ENGINE" exec -e PGPASSWORD="$MIGRATOR_POSTGRES_PASSWORD" "$db_container" \
    psql -U "$MIGRATOR_POSTGRES_USER" -d postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname = '${IT_DB_NAME}'")"
if [[ "$exists" != "1" ]]; then
    "$ENGINE" exec -e PGPASSWORD="$MIGRATOR_POSTGRES_PASSWORD" "$db_container" \
        psql -U "$MIGRATOR_POSTGRES_USER" -d postgres -c \
        "CREATE DATABASE ${IT_DB_NAME} OWNER ${MIGRATOR_POSTGRES_USER}"
fi

echo "==> Миграции (идемпотентно — golang-migrate накатывает только новые)"
"$ENGINE" run --rm --network "$db_network" \
    -v "$WORKSPACE_DIR/wallet-api/migrations:/migrations:ro" \
    docker.io/migrate/migrate -path=/migrations \
    -database "postgres://${MIGRATOR_POSTGRES_USER}:${MIGRATOR_POSTGRES_PASSWORD}@db:5432/${IT_DB_NAME}?sslmode=disable" \
    up

echo "==> Сборка тестового образа (см. Containerfile рядом)"
# Здесь, в отличие от volume-спеков выше, аргументы — обычные host-пути без
# контейнерной половины, и их как раз НАДО отдать podman.exe/docker.exe в
# виде "D:/...", иначе он молча плюсует их к текущему диску
# ("D:\d\Docums\..."). Поэтому MSYS_NO_PATHCONV снят только для этого
# вызова — пусть Git Bash конвертирует их как обычно.
env -u MSYS_NO_PATHCONV "$ENGINE" build -t "$TEST_IMAGE" \
    -f "$SCRIPT_DIR/Containerfile" "$WORKSPACE_DIR/wallet-api"

echo "==> Тесты"
# JUNIT_XML_PATH — см. test_main.cpp: если задан, раннер пишет туда JUnit XML
# (для Jenkins "junit" step, см. ../../../jobs/wallet-api-integration-tests/Jenkinsfile
# в BuildPlatform). Контейнер образа тестов без USER (см. Containerfile
# рядом — root), поэтому запись в bind-mount не упирается в права.
"$ENGINE" run --rm --network "$db_network" \
    -v "$SCRIPT_DIR:/results" \
    -e DATABASE_URL="postgres://${MIGRATOR_POSTGRES_USER}:${MIGRATOR_POSTGRES_PASSWORD}@db:5432/${IT_DB_NAME}?sslmode=disable" \
    -e JUNIT_XML_PATH=/results/junit.xml \
    "$TEST_IMAGE"
