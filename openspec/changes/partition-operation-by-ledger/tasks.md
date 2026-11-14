# Tasks

## 1. Замер «до»

- [x] 1.1 Снять базовую линию на test: нагрузочный прогон (`loadtest/`, сценарии sync и отчётов) и `EXPLAIN (ANALYZE, BUFFERS)` pull-выборки `operation`, ленты (`f_operations_for_period`) и каждой `f_balance_*`/`f_*_for_period` для одного леджера. Проверка: прогон записан в perf-историю (`record_run.sh`), планы сохранены в `openspec/changes/partition-operation-by-ledger/baseline/`
- [x] 1.2 Перечень зависимостей `operation`/`operation_link` из `pg_depend` на test (вьюхи, FK) и сверка с design.md. Проверка: список вьюх для пересоздания зафиксирован в design.md (Decisions, шаг 5)

## 2. Миграция

- [x] 2.1 `migrations/000040_partition_operation.up.sql` (номер 000040 — следующий свободный после default-reference-currencies) по порядку из design.md: lock_timeout, LOCK, новые секционированные таблицы по 16 секций, перелив, DROP вьюх и старых таблиц, RENAME, ограничения/индексы/триггеры/комментарии с прежними именами, вьюхи, GRANT, ANALYZE — в одной транзакции. Проверка: up на локальной копии test-дампа без ошибок; `\d+ operation` показывает `Partition key: HASH (ledger_id)` и 16 секций; `count(*)` и `md5(string_agg(t::text, '' ORDER BY ledger_id, uuid))` обеих таблиц совпадают с исходными
- [x] 2.2 `migrations/000040_partition_operation.down.sql`: обратно в обычные таблицы с DDL из `schema/table/*.sql` до изменения, перелив, вьюхи, права. Проверка: up → down → up на той же копии без ошибок, контрольные суммы совпадают на каждом шаге, после down `relkind` таблиц = `r`
- [x] 2.3 Проверка прав и DDL: под `wallet_api` — INSERT/UPDATE/DELETE в `operation` проходят, `CREATE TABLE x PARTITION OF operation ...` отклоняется; под `wallet_reader` — SELECT из `operation`, `v_operation`, `v_operation_eq` проходит. Проверка: psql-сессии под обеими ролями на локальной базе
- [x] 2.4 Синхронизировать справочный DDL: `schema/table/operation.sql`, `schema/table/operation_link.sql` (PARTITION BY HASH, секции, шапка со ссылкой на change), `schema/README.md` («Арендатор в ключе, а не в коде» — секционировано, как удваивать модуль). Проверка: `psql -v ON_ERROR_STOP=1 -f schema/apply.sql` на пустой базе проходит, `\d operation` совпадает с результатом миграции

## 3. Тесты

- [x] 3.1 Интеграционный тест `tests_integration/test_partitioning.cpp`: операции и связи двух леджеров лежат в секциях с одинаковым номером (`tableoid::regclass`); новый леджер с произвольным uuid принимает операцию; повторный push того же `(ledger_id, uuid)` не дублирует; чужой счёт → `409 missing_reference`; удаление леджера через `account_deletion_repo` чистит обе таблицы; `DELETE` операции каскадит связи. Проверка: `tests_integration/run_local.sh` — все тесты зелёные, новый тест в таблице «Что покрыто» `tests_integration/README.md`
- [x] 3.2 В том же тесте — pruning: `EXPLAIN` pull-выборки по `(ledger_id, seq)` показывает одну секцию, `EXPLAIN ANALYZE` вызова `f_balance_to_date` — `Subplans Removed`. Проверка: тест падает, если в плане больше одной секции `operation`
- [x] 3.3 Проверить, что ни `sync_repo.cpp`, ни android-wallet (`SyncEngine.parseMissingReference`) не завязаны на имя ссылающейся таблицы и на имя constraint для `operation`/`operation_link` (в 409 теперь будут имена секций). Проверка: существующие тесты `test_push_batch.cpp` зелёные; результат grep по android-wallet записан в design.md/Risks
- [x] 3.4 Юнит-тесты `tests/` прогнать без изменений (логика репозитория не меняется). Проверка: `ctest` в сборке wallet-api зелёный

## 4. Выкат на test

- [ ] 4.1 Выкат тега wallet-api на test штатным путём (`deploy.sh` катит миграцию). Проверка: в логе миграции время транзакции; `curl` через гейтвей `/api/health` — 200; `\d+ operation` на test — секционирована
- [ ] 4.2 Живой синк и отчёты: push+pull с телефона (android-wallet), операция через бота (wallet-telegram), отчёты и лента в wallet-web. Проверка: данные совпадают с до-выкатными, ошибок в логах wallet-api/wallet-report нет
- [ ] 4.3 Замер «после»: тот же нагрузочный прогон и те же `EXPLAIN`, сравнение `loadtest/compare_results.sh` с базовой линией из 1.1. Проверка: ни один сценарий не медленнее за пределами шума прогона; итог записан в design.md (Risks)

## 5. Prod

- [ ] 5.1 Выкат на prod штатным путём (дамп перед миграцией — `deploy.sh`). Проверка: дамп лежит в `${WALLET_BACKUP_DIR}/prod/wallet/`, smoke зелёный, `\d+ operation` на prod — секционирована, синк с телефона проходит

## Workflow follow-up

- Архивировать change после выката на prod (`/opsx:archive`), спека `ledger-data-storage` станет первой основной спекой wallet-api.
