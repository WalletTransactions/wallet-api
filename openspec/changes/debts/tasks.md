# Tasks

## 1. Сверка с параллельными changes

- [x] 1.1 Выбрать номер миграции — следующий свободный в `migrations/` (сейчас после `000035`) с учётом `partition-operation-by-ledger`; взять текущие определения `v_account_operating`, `f_balance_to_date`, `f_balance_to_dates`, `f_balance_series`, `f_operations_for_period` из последней миграции, которая их задавала. Проверка: в описании PR перечислены номер и миграции-источники каждого определения.

## 2. Схема: таблицы и признак

- [x] 2.1 В миграции `0000NN_debts.up.sql`: `CREATE TABLE counterparty` (колонки синка, `name`, `comment`, `icon_uuid NULL`, `is_archived`, PK `(ledger_id, uuid)`, индекс `(ledger_id, seq)`, `set_updated_at`, уникальный индекс по `lower(btrim(name))` среди живых, `COMMENT ON`) и `CREATE TABLE account_debt` (колонки синка, `counterparty_uuid` с составным FK, `comment`, `due_date date NULL`, PK, FK на `account_operating ON DELETE CASCADE`, индексы, триггер, `COMMENT ON`), без уникальности «контрагент + валюта». Проверка: `migrate up` на чистой базе test проходит, `\d counterparty` и `\d account_debt` совпадают с design D1/D2.
- [x] 2.2 `.down.sql`: вернуть прежние определения вида и функций, `DROP TABLE account_debt, counterparty`. Проверка: `up → down → up` на базе без строк в новых таблицах проходит без ошибок.
- [x] 2.3 Зеркала: `schema/table/counterparty.sql`, `schema/table/account_debt.sql`, разделы в `schema/table/README.md`, строки в `schema/apply.sql`. Проверка: `schema/apply.sql` на пустой базе даёт ту же схему, что миграции (сравнение `pg_dump --schema-only`).
- [x] 2.4 В миграции явный `GRANT SELECT` на обе таблицы роли `wallet_reader` (нужен wallet-report для `LEFT JOIN`); строки и комментарий в `schema/role/wallet_reader.sql`. Проверка: `SET ROLE wallet_reader; SELECT * FROM account_debt` на test проходит, `INSERT` — отказ.
- [x] 2.5 Каскад tombstone: мягкое удаление кошелька гасит его `account_debt` (по образцу `000035` для `account_asset`, включая разовую чистку уже осиротевших строк). Проверка: интеграционный тест — после мягкого удаления кошелька `account_debt` отдаётся в pull с `deleted_at`.

## 3. Синк

- [x] 3.1 `src/sync_repo.cpp`: `counterparty` (`name`, `comment`, `is_archived`, необязательная `icon_uuid`) и `account_debt` (`counterparty_uuid`, `comment`, необязательная `due_date`) в `push_tables()`; `counterparty`, `account_debt` после `account_asset` в `kApplyOrder`; обновить комментарий шапки `sync_repo.hpp`. Проверка: `tests/test_sync_repo.cpp` — таблицы в списке LedgerOnly, порядок применения проверен юнит-тестом.
- [x] 3.2 Дубль имени контрагента → `409 duplicate_name` тем же обработчиком, что у `account`. Проверка: интеграционный тест `Вася` / `вася`.
- [x] 3.3 Удаление контрагента с живым `account_debt` → `409 counterparty_in_use` (проверка в конце транзакции, батч «снять долг и удалить контрагента» проходит). Проверка: интеграционные тесты на оба случая в `tests_integration/test_push_batch.cpp`.
- [x] 3.4 Интеграционные тесты на сценарии `specs/debts` и `specs/sync-push`: новый долг одним батчем в любом порядке ключей — `200`; долг на категории — `409 missing_reference`; долг на несуществующего контрагента — `409 missing_reference`; два долговых кошелька одного контрагента в одной валюте — `200`; `due_date` неверного типа — `400 invalid_row`; кошелёк с `account_asset` и `account_debt` — `200`; батч старого клиента без новых таблиц — `200`. Проверка: `tests_integration/run_local.sh` зелёный.
- [x] 3.5 Pull: интеграционный тест — после push долга `GET /sync/pull` со старым курсором отдаёт `changes.counterparty` и `changes.account_debt` с полным набором колонок, мягко удалённые — с `deleted_at`. Проверка: тест зелёный.
- [x] 3.6 `tests_integration/test_account_deletion.cpp`: леджер с контрагентами и долгами удаляется целиком. Проверка: тест зелёный.
- [ ] 3.7 `openapi.yaml`: `CounterpartyPushRow`/`PullRow`, `AccountDebtPushRow`/`PullRow`, массивы в `syncPush`/`syncPull`, ответы `409 duplicate_name`, `409 counterparty_in_use`; README — список таблиц и порядок применения. Проверка: `openapi.yaml` проходит линтер, `GET /docs` отдаёт новые схемы.

## 4. Отчётные функции

- [x] 4.1 В той же миграции: `CREATE OR REPLACE VIEW v_account_operating` с `LEFT JOIN account_debt` (живые) и колонкой `counterparty_uuid` в конце (design D5); зеркало `schema/view/v_account_operating.sql`. Проверка: `SELECT counterparty_uuid FROM v_account_operating` на test отдаёт значение у долгового кошелька и `NULL` у остальных.
- [x] 4.2 `f_balance_to_date`, `f_balance_to_dates`, `f_balance_series` отдают `counterparty_uuid` в конце (`DROP` + `CREATE` + `GRANT`); в пустом бакете `f_balance_series` — `NULL`. Проверка: SQL-тест на леджере с долговым и обычным кошельком.
- [x] 4.3 `f_operations_for_period`: ветка `'debt'` (design D6); если влит фильтр по `kind`, он принимает `'debt'`. Проверка: SQL-тесты — выдача `kind = 'debt'`, перевод между двумя долговыми `transfer`, прощение `expense`.
- [x] 4.4 Новая `f_debts_for_period` (design D7) с `GRANT EXECUTE`; зеркало `schema/function/`. Проверка: SQL-тесты на сценарии `specs/debts` — «остаток после частичного возврата», «нет курса», нулевой и архивный кошелёк в выдаче, два займа одному человеку.
- [x] 4.5 Тестовые данные в `tests_integration/` для отчётных функций: леджер с долгами, переплатой (баланс уходит в минус) и прощением. Проверка: тесты зелёные.

## 5. Парные изменения и выкат

- [ ] 5.1 Сообщить в парный change wallet-report порядок `counterparty`, `account_debt` в `kApplyOrder` (его тестовая копия `sync_repo.cpp` должна совпадать) и имена колонок `f_debts_for_period`. Проверка: ссылка на design D7 в design wallet-report.
- [ ] 5.2 Выкат на test: миграция и wallet-api раньше APK. Проверка: `env-deploy`, интеграционные тесты wallet-api и wallet-report на test зелёные.

## 6. Импорт Money Lover

- [ ] 6.1 На реальных выгрузках `tools/moneylover/MoneyLover-*.csv` выяснить, как `Debt`, `Loan`, `Debt Collection` соотносятся с направлением (расход/доход) и что лежит в поле «with». Проверка: таблица соответствий в `tools/moneylover/README.md`.
- [ ] 6.2 `tools/moneylover/csv_export.py`: три категории — в долговые кошельки; контрагент из «with», иначе из заметки; направление по 6.1. Проверка: прогон на `MoneyLover-2026-11-09.csv` — число долговых кошельков и баланс по каждому совпадают с ручным расчётом по выгрузке.

## Примечания к выполнению

- 1.1 — номер `000036`: у `partition-operation-by-ledger` миграции ещё нет. Источник всех прежних определений (`v_account_operating`, `f_balance_to_date`, `f_balance_to_dates`, `f_balance_series`, `f_operations_for_period`, `f_operations_total`) — `000033`; записано в шапке `000036_debts.up.sql` (PR не открывался — перенести в описание PR при открытии).
- 2.1–2.4 — проверено на одноразовом `postgres:16-alpine` (не на базе test): `migrate goto 35 → up → down 1 → up`, `pg_dump --schema-only` после `down` совпадает с дампом до `up`, после повторного `up` — с первым `up` (расходятся только случайные метки `\restrict`). `apply.sql` на пустой базе — тела функций, вид, ACL, комментарии функций и DDL обеих таблиц совпадают с миграциями. `SET ROLE wallet_reader`: `SELECT` из обеих таблиц и `f_debts_for_period` проходит, `INSERT` — `permission denied`.
- 2.1 — уникальный индекс имени — `lower(btrim(translate(name, 'Ёё', 'Ее')))`, а не `lower(btrim(name))` из design D1: правило `uq_account_name` плюс `btrim` (решение владельца 2026-11-12). `icon_uuid` — FK на `icon` (решение владельца 2026-11-12). Ссылки `fk_counterparty_icon`, `fk_account_debt_counterparty` — `DEFERRABLE INITIALLY IMMEDIATE` и отложены в `account_deletion_repo` (иначе удаление леджера падает на вложенном каскаде, как до `000025`).
- 3.1 — `TableSpec::optional_kinds`: необязательные колонки с `NULL` (`due_date` — `Date`, `icon_uuid` — `Uuid`). Нет ключа — колонки нет в `INSERT`/`SET` (прежнее значение), как у `show_in_equivalent`; явный `null` — `NULL` (снять срок); строка проверяется по формату (`yyyy-MM-dd` с проверкой календаря, uuid) до SQL, иначе `400 invalid_row` с именем поля. Юнит-тесты: 86 зелёных (сборка в контейнере `debian:bookworm-slim`, на хосте нет cmake).
- 3.2 — ответ `409 {"error":"duplicate_name","conflicts":[{"table":"counterparty","reason":"duplicate_name","uuid":…,"existing_uuid":…}]}`: формат конфликта счёта плюс `error` из спеки (решение владельца 2026-11-12); ответ для `account` не менялся.
- 3.3 — тело `409 {"error":"counterparty_in_use","table":"counterparty","uuid":…}`: `table`/`uuid` сверх спеки, как у `missing_reference`. Проверка — после `upsert` и каскада, в той же транзакции; три батча проходят: «снять долг и удалить контрагента», «удалить кошелёк и контрагента», «удалить контрагента без долгов».
- 3.4–3.6 — интеграционные тесты прогнаны не через `run_local.sh` (он привязан к кластеру wallet-test), а тем же бинарём против одноразового `postgres:16-alpine` с миграциями до `000036`: 128 тестов, 0 упавших.
- 4.1–4.5 — SQL-тесты — `tests_integration/test_debts_reports.cpp` (6 тестов на одном наборе данных), вместо ручного `SELECT` на test; прогон — тот же, что у 3.4. `counterparty_uuid` в `v_account_operating` проверяется через `f_balance_*` и тесты синка (`view_counterparty`).
- 4.3 — `kind = 'debt'` строго по спеке: только прямой перевод «кошелёк ↔ кошелёк», ровно одна сторона которого долговая. Ноги разновалютного займа через категорию `Transfer` остаются `expense`/`income` (подтверждено владельцем 2026-11-12). Побочный эффект: `p_kind => 'transfer'` больше не находит долговые переводы — wallet-report должен принять `'debt'` в валидации `kind` (парный change). То же в `f_operations_total`.
- 4.4 — порядок строк `f_debts_for_period` — `counterparty_name, account_name, account_uuid` (в design не задан). `balance_to` выводится из округлённых частей — тождество точное.
- 2.5 — разовой чистки осиротевших строк нет: таблица создаётся той же миграцией, строк в ней ещё нет. Каскад — правилом `cascade_rules()` в `push_batch`, как у `account_asset`.

## Workflow follow-up

- Архивировать change после выката на prod и закрытия парных changes (`openspec archive`).
