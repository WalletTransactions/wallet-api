# Tasks

## 1. Сверка с параллельными changes

- [x] 1.1 Выбрать номер миграции — следующий свободный в `migrations/` с учётом уже влитых `currency-ui-tweaks`, `purge-synced-tombstones`, `add-operations-filter-functions`, `partition-operation-by-ledger`; взять текущие определения `v_account_operating` и всех отчётных функций из последней миграции, которая их задавала. Проверка: в описании PR перечислены номер и миграции-источники каждого определения.

## 2. Схема: таблица и признак

- [x] 2.1 В миграции `0000NN_capital_assets.up.sql`: `CREATE TABLE account_asset` (служебные колонки синка, `asset_type smallint NOT NULL CHECK (asset_type IN (1,2,3))`, `include_in_net_worth boolean NOT NULL DEFAULT true`, `comment text NOT NULL DEFAULT ''`, PK `(ledger_id, uuid)`, FK на `account_operating (ledger_id, uuid) ON DELETE CASCADE`, индекс `(ledger_id, seq)`, триггер `set_updated_at`, `COMMENT ON`), расширение CHECK `account.system_kind IN (0,1,2,3)`. Проверка: `migrate up` на чистой базе test проходит, `\d account_asset` совпадает с design D1/D2.
- [x] 2.2 `.down.sql`: `DROP TABLE account_asset`, CHECK `system_kind IN (0,1,2)`. Проверка: `up → down → up` на базе без строк `system_kind = 3` проходит без ошибок.
- [x] 2.3 Зеркала: `schema/table/account_asset.sql`, правка `schema/table/account.sql` (CHECK и `COMMENT ON COLUMN system_kind` с `3 = Revaluation`), раздел `account_asset` в `schema/table/README.md`, строка в `schema/apply.sql`. Проверка: `schema/apply.sql` на пустой базе даёт ту же схему, что миграции (сравнение `pg_dump --schema-only`).
- [x] 2.4 В миграции явный `GRANT SELECT ON account_asset TO wallet_reader` (нужен wallet-report для `LEFT JOIN` в `/wallet-turnover` и `/accounts`); строка и комментарий в `schema/role/wallet_reader.sql`. Проверка: `SET ROLE wallet_reader; SELECT * FROM account_asset` на test проходит, `INSERT` — отказ.

## 3. Синк

- [x] 3.1 `src/sync_repo.cpp`: `{"account_asset", Scope::LedgerOnly, {"asset_type", "include_in_net_worth", "comment"}}` в `push_tables()`, `"account_asset"` после `"account_operating"` в `kApplyOrder`; обновить комментарий шапки `sync_repo.hpp` о числе таблиц. Проверка: `tests/test_sync_repo.cpp` — `account_asset` в списке LedgerOnly-таблиц, порядок применения проверен юнит-тестом.
- [x] 3.2 `push_batch`: `sqlstate == "23514"` → `400 {"error":"invalid_row","detail":…}` (design D3). Проверка: юнит-тест на разбор ответа и интеграционный тест в `tests_integration/test_push_batch.cpp`: `account.system_kind = 9` и `account_asset.asset_type = 4` дают `400 invalid_row`, а не `500`.
- [x] 3.3 Интеграционные тесты `tests_integration/test_push_batch.cpp` на сценарии `specs/capital-assets` и `specs/sync-push`: новый актив одним батчем (`account` + `account_operating` + `account_asset` в любом порядке ключей) — `200`; актив на категории — `409 missing_reference`; строка без `include_in_net_worth` — `400 invalid_row`; мягкое удаление `account_asset`; категория с `system_kind = 3` — `200`; батч старого клиента без `account_asset` — `200`. Проверка: `tests_integration/run_local.sh` зелёный.
- [x] 3.4 Pull: интеграционный тест — после push актива `GET /sync/pull` со старым курсором отдаёт `changes.account_asset` с полным набором колонок, мягко удалённую строку — с `deleted_at`. Проверка: тест в `tests_integration/` зелёный.
- [x] 3.5 `tests_integration/test_account_deletion.cpp`: леджер с активом удаляется целиком, строк `account_asset` не остаётся. Проверка: тест зелёный.
- [x] 3.6 `openapi.yaml`: `AccountAssetPushRow`/`AccountAssetPullRow`, массив `account_asset` в `syncPush`/`syncPull`, `system_kind` с `maximum: 3` и описанием `3 = Revaluation`, ответ `400 invalid_row` при значении вне набора; README — список синхронизируемых таблиц и порядок применения. Проверка: `openapi.yaml` проходит линтер, `GET /docs` отдаёт новую схему.

## 4. Отчётные функции

- [x] 4.1 В той же миграции: `CREATE OR REPLACE VIEW v_account_operating` с `LEFT JOIN account_asset` (живые) и колонками `asset_type`, `include_in_net_worth` в конце (design D4); зеркало `schema/view/v_account_operating.sql`. Проверка: `SELECT asset_type FROM v_account_operating` на test отдаёт `1` у помеченного кошелька и `NULL` у остальных; `v_account_expanse` не сломан.
- [x] 4.2 `f_balance_to_date`, `f_balance_to_dates`, `f_balance_series` (не `f_wallet_turnover_for_period` — там признак добавляет wallet-report своим `JOIN`): `DROP FUNCTION` + `CREATE` с `asset_type`, `include_in_net_worth` в конце `RETURNS TABLE` + `GRANT EXECUTE` для `wallet_reader`; `f_balance_series` отдаёт их и в пустом бакете (`NULL`). Проверка: старый запрос wallet-report (`src/reports_repo.cpp`, колонки по имени) на мигрированной базе работает; интеграционные тесты wallet-report текущей версии зелёные.
- [x] 4.3 Исключение переоценки предикатом design D5 (без фильтра `deleted_at`) в `f_income_for_period`, `f_expanse_for_period`, `f_expanse_by_category_for_period`, `f_income_expense_by_month`, `f_expense_by_weekday_for_period` (`CREATE OR REPLACE`) и в оборотах и `incomplete` `f_wallet_turnover_for_period`. Проверка: на леджере с проводками переоценки обе стороны (вверх и вниз) не меняют ни одну из шести функций по сравнению с тем же леджером без них; переоценка через мягко удалённую категорию тоже исключена.
- [x] 4.4 `f_operations_for_period`: ветка `'revaluation'` первой в `CASE kind`; если влит `add-operations-filter-functions` — фильтр `kind` и функция итога принимают `'revaluation'`. Проверка: проводка «Переоценка → актив» приходит с `kind = 'revaluation'`, категорией «Переоценка» и кошельком-активом.
- [x] 4.5 Новая `f_assets_for_period(uuid, timestamp, timestamp, uuid)` по таблице design D7 + `GRANT EXECUTE` для `wallet_reader`; зеркало `schema/function/f_assets_for_period.sql`. Проверка: на наборе «покупка 10 000 000 переводом, ремонт 1 500 000, переоценка вверх на 500 000 в периоде» — `value` = 12 000 000, `invested` = 11 500 000, `revaluation_total` = `revaluation_period` = 500 000, `return_pct` ≈ 4.35, `*_eq` посчитаны по одному курсу на `p_to` и `value_eq = invested_eq + revaluation_total_eq`; актив, купленный разновалютным переводом через `Transfer`, имеет `invested` = сумма ноги в актив; без курса `value_eq` = `NULL`.
- [x] 4.6 `.down.sql`: прежние определения вида и всех функций из 4.1–4.5, `DROP FUNCTION f_assets_for_period`, повторные `GRANT`. Проверка: `up → down → up` проходит, после `down` текущий wallet-report работает.
- [x] 4.7 Документация: таблица отчётных функций и раздел «Переоценка» в `schema/function/README.md` (что исключается, тождество `value = invested + revaluation_total`, границы `p_to`), строки `GRANT` в `schema/role/wallet_reader.sql`, зеркала изменённых функций в `schema/function/`. Проверка: ревью — каждая функция из 4.2–4.5 упомянута в README и её зеркало совпадает с последней миграцией.

Сверх формулировок задач (реализация 2026-11-07, миграция `000033`):
- 4.3 — исключение переоценки также в `f_expense_by_category_by_month` (000030/000031, появилась после design): тот же расход, иначе помесячная матрица разошлась бы со структурой.
- 3.1 — `account_asset` добавлена в `sync_table_refs()`/`purge_order()` (чистка tombstone, `purge-synced-tombstones` влит после design) и порядок применения вынесен в `sync_repo::apply_order()` ради юнит-теста.
- 2.3 — `apply.sql` и миграции совпадают по всем объектам этого change; давний дрейф (демо-таблица `wallets`, тексты `COMMENT`) к нему не относится.

## 5. Интеграция с парными changes

- [x] 5.1 Прогнать интеграционные тесты wallet-report из парного change `capital-assets` против базы с этой миграцией. Проверка: зелёный прогон `wallet-report/tests_integration`.
- [x] 5.2 Выкат на test (`env-deploy`) раньше Android-версии с активами; ручной push актива и переоценки с тестового устройства. Проверка: на test `GET /api/reports/*` показывает актив отдельно, доход/расход не изменились. — проверено 2026-11-10: wallet-api 0.3.0-rc.6 на test; по базе `f_assets_for_period` отдаёт актив «Now» отдельно, `f_income_for_period` без строк за день переоценки. Тест: [android-wallet#33](https://github.com/WalletTransactions/android-wallet/issues/33)

## Workflow follow-up

- Архивировать change после выката в prod всех четырёх парных changes и обновления устройств.
