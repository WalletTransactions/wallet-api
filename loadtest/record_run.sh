#!/usr/bin/env bash
# Записывает один прогон wallet-api sync-сценария (scenario_push_saturation.js
# по умолчанию, см. k6/) в ТУ ЖЕ Grafana Perf History БД, что и
# ../../wallet-report/loadtest/record_run.sh (infra/db/migrations/perf/,
# дашборд infra/monitoring/grafana/dashboards/perf-history.json) — тем же
# приёмом (test_run + test_result), просто отдельным `scenario`-именем
# ("sync_push_saturation"/"sync_push_same_ledger_race"), чтобы не путать с
# отчётными сценариями wallet-report в том же дропдауне.
#
# В отличие от wallet-report/loadtest/record_run.sh — ОДИН уровень VUS за
# вызов, не несколько сразу: setup() каждого scenario_push_*.js провижинит
# ledger по каждому токену (иконка+валюта+2 счёта) заново при каждом запуске
# k6 — повторный вызов на ТЕХ ЖЕ токенах падает на duplicate_key
# (uq_icon_name_ledger). Чтобы сравнить несколько точек (например, разные
# DATABASE_POOL_SIZE), перевыпускайте токены (bash mint_tokens.sh) перед
# КАЖДЫМ вызовом этого скрипта — см. pool_sweep_wallet_api.sh рядом с этим
# файлом на момент прогона (см. историю сессии) для примера-обёртки.
#
# Использование:
#   bash record_run.sh
#   BRANCH="sync-pool-1" POOL_SIZE=1 VUS=20 DURATION_SECS=30 bash record_run.sh
#   SCENARIO_FILE=scenario_push_same_ledger_race.js TOKENS_FILE=same_ledger_tokens.json \
#     BRANCH="sync-race-pool-8" POOL_SIZE=8 VUS=30 DURATION_SECS=30 bash record_run.sh
set -euo pipefail

export MSYS_NO_PATHCONV=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
DATA_DIR="$SCRIPT_DIR/data"
mkdir -p "$DATA_DIR"

ENV_FILE="$WORKSPACE_DIR/wallet-infra/infra/db/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "Не найден $ENV_FILE — сначала: cp infra/db/.env.example infra/db/.env" >&2
    exit 1
fi
set -a
source "$ENV_FILE"
set +a

for bin in jq curl git; do
    command -v "$bin" >/dev/null 2>&1 || { echo "Нужен '$bin' на хосте." >&2; exit 1; }
done

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

SCENARIO_FILE="${SCENARIO_FILE:-scenario_push_saturation.js}"
# "scenario_push_saturation.js" -> "sync_push_saturation" (не
# "sync_scenario_push_saturation" — SCENARIO_FILE уже несёт префикс
# "scenario_", дублировать его в имени не нужно).
SCENARIO_NAME="sync_$(basename "$SCENARIO_FILE" .js | sed 's/^scenario_//')"
TOKENS_FILE="${TOKENS_FILE:-independent_tokens.json}"
TOKENS_PATH="$DATA_DIR/$(basename "$TOKENS_FILE")"
VUS="${VUS:-20}"
DURATION_SECS="${DURATION_SECS:-30}"
ENVIRONMENT="${ENVIRONMENT:-local-docker-compose}"
VERSION="${VERSION:-}"
POOL_SIZE="${POOL_SIZE:-}"

if [[ ! -f "$TOKENS_PATH" ]]; then
    echo "Не найден $TOKENS_PATH — сначала: bash mint_tokens.sh (см. README.md, Шаг 1)." >&2
    exit 1
fi

commit_sha="$(git -C "$SCRIPT_DIR" rev-parse HEAD)"
# BRANCH override — как и у wallet-report/loadtest/record_run.sh: без него
# все прогоны легли бы в Grafana под одним и тем же именем ветки и
# сравнивать было бы нечего.
branch="${BRANCH:-$(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD)}"

echo "==> commit=$commit_sha branch=$branch сценарий=$SCENARIO_FILE VUS=$VUS DURATION=${DURATION_SECS}s токены=$(basename "$TOKENS_PATH")"

db_container="$("$ENGINE" ps --filter "label=io.podman.compose.service=db" --format '{{.Names}}' | head -n1)"
if [[ -z "$db_container" ]]; then
    db_container="$("$ENGINE" ps --filter "label=com.docker.compose.service=db" --format '{{.Names}}' | head -n1)"
fi
if [[ -z "$db_container" ]]; then
    echo "Не нашёл запущенный контейнер 'db'. Сначала: $ENGINE compose --env-file infra/db/.env up -d" >&2
    exit 1
fi
db_network="$("$ENGINE" inspect "$db_container" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}')"

summary_path="$DATA_DIR/perf_${SCENARIO_NAME}_vus${VUS}.json"

"$ENGINE" run --rm --network "$db_network" --user "$(id -u):$(id -g)" \
    -v "$SCRIPT_DIR/k6:/scripts:ro" -v "$DATA_DIR:/data" \
    -e GATEWAY_URL="http://wallet-gateway:8090" -e TOKENS_FILE="/data/$(basename "$TOKENS_PATH")" \
    -e VUS="$VUS" -e DURATION="${DURATION_SECS}s" \
    docker.io/grafana/k6 run --summary-export="/data/$(basename "$summary_path")" "/scripts/$SCENARIO_FILE"

if [[ ! -f "$summary_path" ]]; then
    echo "Не нашёл $summary_path после прогона — k6 упал раньше summary-export?" >&2
    exit 1
fi

requests="$(jq -r '.metrics.http_reqs.count // 0' "$summary_path")"
rps="$(jq -r '.metrics.http_reqs.rate // 0' "$summary_path")"
err="$(jq -r '.metrics.http_req_failed.rate // 0' "$summary_path")"
p50="$(jq -r '.metrics.http_req_duration."p(50)" // 0' "$summary_path")"
p90="$(jq -r '.metrics.http_req_duration."p(90)" // 0' "$summary_path")"
p95="$(jq -r '.metrics.http_req_duration."p(95)" // 0' "$summary_path")"
p99="$(jq -r '.metrics.http_req_duration."p(99)" // 0' "$summary_path")"

echo "    requests=$requests rps=$rps p50=$p50 p90=$p90 p95=$p95 p99=$p99 err=$err"

parameters_json="$(jq -n --arg scenario "$SCENARIO_FILE" --arg pool_size "$POOL_SIZE" \
    --argjson vus "$VUS" --argjson duration_secs "$DURATION_SECS" \
    '{scenario_file: $scenario, vus: $vus, duration_secs: $duration_secs}
      + (if $pool_size != "" then {database_pool_size: ($pool_size | tonumber)} else {} end)')"

SQL_FILE="$(mktemp)"
trap 'rm -f "$SQL_FILE"' EXIT
{
    echo "INSERT INTO test_run (commit_sha, branch, environment, version, scenario, parameters)"
    echo "VALUES (:'run_commit', :'run_branch', :'run_env', NULLIF(:'run_version', ''), :'run_scenario', :'run_params'::jsonb)"
    echo "RETURNING id \\gset run_"
    echo
    echo "INSERT INTO test_result (test_run_id, scenario, clients, duration_s, requests, rps, p50_ms, p90_ms, p95_ms, p99_ms, error_rate, avg_cpu_pct, avg_mem_bytes)"
    echo "VALUES (:'run_id', :'run_scenario', $VUS, $DURATION_SECS, $requests, $rps, $p50, $p90, $p95, $p99, $err, null, null);"
} > "$SQL_FILE"

echo "==> Пишу в perf_history"
"$ENGINE" exec -i "$db_container" psql -v ON_ERROR_STOP=1 \
    --username "$PERF_POSTGRES_USER" --dbname "$PERF_POSTGRES_DB" \
    -v run_commit="$commit_sha" -v run_branch="$branch" -v run_env="$ENVIRONMENT" \
    -v run_version="$VERSION" -v run_scenario="$SCENARIO_NAME" -v run_params="$parameters_json" \
    < "$SQL_FILE"

echo "==> Готово. Grafana: http://localhost:13000 -> дашборд \"Perf History\" (scenario=$SCENARIO_NAME, branch=$branch)."
