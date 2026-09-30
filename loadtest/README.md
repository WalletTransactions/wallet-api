# Нагрузочный контур wallet-api (через wallet-gateway)

Проверяет тот же переход, что уже сделан у wallet-report (`db::Pool`,
`DATABASE_POOL_SIZE`, см. `../src/db.hpp`) — с ДВУХ сторон:

1. **Пропускная способность** (`scenario_push_saturation.js`) — независимые
   леджеры, показывает тот же выигрыш пула, что и у wallet-report.
2. **Корректность под конкуренцией** (`scenario_push_same_ledger_race.js`) —
   по прямому запросу ("возможные дедлоки, делать через тесты"): несколько
   устройств ОДНОГО аккаунта пушут в ОДИН леджер одновременно — офлайн-first
   многоустройство, ради которого весь sync-протокол и существует
   (`org/docs/TODO_mobile_sync.md`). Это единственный сценарий, где
   конкурентная запись реально пересекается на одних и тех же строках
   (`change_stream`, `next_seq(ledger_id)`, `account` этого леджера), а не
   просто делит пул с чужими запросами — именно здесь мог бы проявиться
   Postgres-дедлок или зависание, если он есть.

Нагрузка идёт через `wallet-gateway` (порт `8090`), тем же путём, что и
реальный клиент — см. `../../wallet-report/loadtest/README.md`, "Разбор пути
запроса" (тот же путь, просто `/sync/*` вместо `/api/reports/*`).

## Почему без отдельного C++ seed-инструмента

В отличие от wallet-report (там read-only отчётам нужны заранее насеянные
операции), `POST /sync/push` **сам** лениво провижинит леджер/устройство
(`provisioning::ensure_identity`) на первый же батч — сеять заранее нечего.
Каждый k6-сценарий сам заводит план счетов (иконка + валюта + 2 счёта) ОДИН
раз в `setup()` настоящим протоколом (`POST /sync/blobs` + `POST
/sync/push`, см. `k6/lib/provision.js`), а дальше измеряемая фаза — только
`push` новых операций на уже готовую пару счетов, тот же трафик, что и у
реального устройства (план счетов не пересоздают на каждый синк).

## Шаг 1. Сминтить токены

```bash
bash mint_tokens.sh
```

Два файла (см. сам скрипт, зачем именно два):

- `data/independent_tokens.json` — `LOADTEST_USERS` (по умолчанию 8) разных
  пользователей, у каждого своё устройство и свой леджер.
- `data/same_ledger_tokens.json` — `LOADTEST_RACE_DEVICES` (по умолчанию 6)
  токенов ОДНОГО пользователя, разные `device_id` — один леджер на всех.

Требует `google-auth/jwt_signing_key.pem` (см. `wallet-infra/README.md`) — минтер
собирается сам при первом запуске (`LOADTEST_FORCE_REBUILD=1` — пересобрать).

## Шаг 2. Прогнать сценарии

```bash
# Ворота — 1 VU, 1 итерация:
GATEWAY_URL=http://localhost:8090 TOKENS_FILE=./data/independent_tokens.json \
  k6 run k6/scenario_push_smoke.js

# Пропускная способность (независимые леджеры):
GATEWAY_URL=http://localhost:8090 TOKENS_FILE=./data/independent_tokens.json \
  VUS=20 DURATION=2m k6 run k6/scenario_push_saturation.js

# Гонка на ОДНОМ леджере (дедлоки/конкурентная запись):
GATEWAY_URL=http://localhost:8090 TOKENS_FILE=./data/same_ledger_tokens.json \
  VUS=30 DURATION=1m k6 run k6/scenario_push_same_ledger_race.js
```

Контейнером (сеть compose, имя обычно `servers_wallet-net` — уточните через
`podman network ls`, если не совпадает):

```bash
podman run --rm --network servers_wallet-net \
  -v "$(pwd)/k6:/scripts:ro" -v "$(pwd)/data:/data:ro" \
  -e GATEWAY_URL=http://wallet-gateway:8090 -e TOKENS_FILE=/data/same_ledger_tokens.json \
  -e VUS=30 -e DURATION=1m \
  docker.io/grafana/k6 run /scripts/scenario_push_same_ledger_race.js
```

## Шаг 3. Методика — DATABASE_POOL_SIZE=1 vs 8 vs другие

Тот же приём, что и у wallet-report (`Pool` при `size=1` — В ТОЧНОСТИ прежнее
поведение, один и тот же код, просто N=1):

```bash
# 1. "Как было" — servers/compose.loadtest-override.yaml уже держит
#    wallet-api DATABASE_POOL_SIZE=1 (см. этот файл) — применить:
podman compose --env-file infra/db/.env -f compose.yaml -f compose.loadtest-override.yaml \
  up -d --build wallet-api
VUS=30 DURATION=1m k6 run k6/scenario_push_same_ledger_race.js
VUS=20 DURATION=2m k6 run k6/scenario_push_saturation.js

# 2. "Как стало" — вернуть обычный compose.yaml (DATABASE_POOL_SIZE=8, дефолт):
podman compose --env-file infra/db/.env up -d --build wallet-api
# те же два прогона
```

Сравните: `http_req_failed` (должен остаться ~0 в ОБОИХ случаях — пул чинит
задержку/пропускную способность, не корректность данных), `p(95)`/`p(99)`
`http_req_duration`, req/s. Если `same_ledger_race` при `POOL=1` ощутимо
медленнее/с ошибками, чем при `POOL=8`, а НЕ статус-код `>=400` от самого
Postgres (реальный deadlock он всегда явно ошибает одну из транзакций, не
подвешивает её бесконечно, — `QueryError` в этом случае долетел бы клиенту
как `500`) — это ожидаемо: пул из 1 соединения сериализует все устройства
одного леджера друг за другом, из 8 — до 8 одновременно.

**Явный "завис" (не ошибка, не медленно, а НЕ ЗАВЕРШИЛОСЬ)** — единственный
признак НАСТОЯЩЕГО дедлока (в отличие от Postgres-конфликта, который сервер
всегда ошибает явным `QueryError`, C++-уровневый deadlock у `db::Pool`
структурно невозможен — см. комментарий к классу в `../src/db.hpp`: ни один
внутренний код `*_repo.cpp` сам `Pool::acquire()` не зовёт, только хендлеры
верхнего уровня, и ровно один раз на весь запрос, — но реальный тест дешевле
любого рассуждения). Если видите его — сначала проверьте логи `wallet-api`
(`{"event":"db_query_failed"}` или отсутствие `"request_finished"` для
"зависшего" запроса вовсе).

## Performance DB — история прогонов (Grafana)

`record_run.sh` гоняет ОДИН из двух write-сценариев (по умолчанию
`scenario_push_saturation.js`) ОДИН РАЗ с заданными `VUS`/`DURATION_SECS` и
пишет результат в ТУ ЖЕ `perf_history` Postgres-базу, что и
`../../wallet-report/loadtest/record_run.sh` (`../../infra/db/migrations/perf/`,
дашборд `../../infra/monitoring/grafana/dashboards/perf-history.json`) —
только под именем сценария с префиксом `sync_` (`sync_push_saturation` /
`sync_push_same_ledger_race`), чтобы не путать с отчётными сценариями
wallet-report в том же дропдауне Grafana. В отличие от wallet-report'овского
`record_run.sh` — НЕ sweep по нескольким уровням за один вызов: `POST
/sync/push` сам провижинит леджер на каждом использованном токене
(см. выше), повторный прогон на ТЕХ ЖЕ токенах падает на `duplicate_key` —
значит любой sweep потребовал бы `bash mint_tokens.sh` перед КАЖДЫМ уровнем,
а не один раз на весь sweep. Поэтому один вызов `record_run.sh` = одна
точка; несколько точек (например, разные `DATABASE_POOL_SIZE`) — несколько
вызовов, каждому своя пара свежих токенов:

```bash
bash ../../infra/db/migrate.sh perf up   # один раз, если ещё не накачена

bash mint_tokens.sh
bash record_run.sh   # VUS=20 DURATION_SECS=30 по умолчанию, scenario_push_saturation.js

bash mint_tokens.sh   # свежие токены — обязательно перед каждым следующим вызовом
SCENARIO_FILE=scenario_push_same_ledger_race.js TOKENS_FILE=same_ledger_tokens.json \
  VUS=30 DURATION_SECS=30 bash record_run.sh

# CI/сравнение по коммитам:
bash mint_tokens.sh
BRANCH="pool-size-1" POOL_SIZE=1 VUS=20 DURATION_SECS=30 bash record_run.sh
```

`p50_ms`/`p99_ms` в записи требуют `summaryTrendStats` с явными `p(50)`/
`p(99)` (k6 по умолчанию их не считает, см. `k6/lib/summary_options.js`,
буквальная копия `../../wallet-report/loadtest/k6/lib/summary_options.js`,
подключена в `scenario_push_saturation.js`/`scenario_push_same_ledger_race.js`
— без неё `record_run.sh` писал бы эти колонки нулями, ничего не ломая).

`avg_cpu_pct`/`avg_mem_bytes` здесь всегда `NULL` — в отличие от
wallet-report'овского `record_run.sh`, этот Prometheus не запрашивает
(не было запроса на CPU/RAM для write-пути, только throughput/latency).

## Jenkins — CI-прогон + запись в Perf History

Как и у wallet-report (`../../wallet-report/loadtest/README.md`, "Jenkins"),
контур автоматизирован в отдельном репозитории **BuildPlatform** —
`BuildPlatform/jobs/wallet-api-loadtest/Jenkinsfile`. Пайплайн минтит
токены, гоняет `scenario_push_smoke.js` (ворота), затем ПЕРЕМИНТИВАЕТ
токены и вызывает `record_run.sh` для каждого из двух сценариев (пишет
`perf_history` + сохраняет summary JSON), публикует HTML-отчёт и трендовые
графики (Plot Plugin) по каждому билду и сравнивает p95 с предыдущим
успешным билдом (`compare_results.sh`), помечая билд `UNSTABLE` при
регрессии — та же структура стадий, что у
`wallet-report-loadtest/Jenkinsfile`, только вместо read-only отчётов —
write-путь `/sync/push`, отсюда перевыпуск токенов между стадиями (см.
комментарии в самом Jenkinsfile).

`render_report.sh`/`extract_metrics.sh`/`compare_results.sh` в этом
каталоге — копии одноимённых скриптов из
`../../wallet-report/loadtest/` (генерические, принимают пути файлов
аргументами, ничего wallet-report-специфичного внутри) — продублированы,
не вынесены в общее место, тем же приёмом, что и `record_run.sh`/
`mint_tokens.sh` здесь: у loadtest-контура каждого сервиса свой независимый
набор инструментов.

## Файлы

```
loadtest/
  README.md              — этот файл
  mint_tokens.sh          — шаг 1: токены (независимые + один леджер на всех)
  record_run.sh           — Performance DB: одна точка на вызов -> perf_history (Postgres), см. раздел выше
  render_report.sh        — JSON -> статический HTML-отчёт (копия wallet-report/loadtest, см. раздел Jenkins)
  extract_metrics.sh      — JSON -> CSV для Jenkins Plot Plugin (копия wallet-report/loadtest)
  compare_results.sh      — сравнение двух --summary-export JSON -> код возврата (копия wallet-report/loadtest)
  .gitignore              — data/ не коммитится
  data/                    — independent_tokens.json, same_ledger_tokens.json, perf_*.json (record_run.sh)
  k6/
    lib/tokens.js          — SharedArray с токенами, round-robin по VU
    lib/provision.js       — провижининг леджера настоящим протоколом + push одной операции
    lib/summary_options.js — summaryTrendStats с p(50)/p(99) для record_run.sh (копия wallet-report/loadtest)
    scenario_push_smoke.js
    scenario_push_saturation.js
    scenario_push_same_ledger_race.js

../../infra/db/migrations/perf/                                    — та же perf_history, что и wallet-report
../../infra/monitoring/grafana/dashboards/perf-history.json        — тот же дашборд "Perf History"
BuildPlatform/jobs/wallet-api-loadtest/Jenkinsfile                 — CI-оркестровка (см. раздел Jenkins)
```
