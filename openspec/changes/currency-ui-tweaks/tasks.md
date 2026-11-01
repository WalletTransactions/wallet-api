# Tasks

## 1. Схема

- [x] 1.1 Миграция `migrations/000026_currency_show_in_equivalent.up.sql` (`ADD COLUMN show_in_equivalent boolean NOT NULL DEFAULT true` + `COMMENT ON COLUMN`) и `.down.sql` (`DROP COLUMN`); проверка — `up` → `down` → `up` на локальной БД (`docker compose --env-file infra/db/.env`) проходит без ошибок
  Проверено: up → down 1 → up на временной базе `wallet_tmp_mig` кластера wallet-test (golang-migrate v4.18.3), после down колонки нет, после up — `boolean not null default true`.
- [x] 1.2 Колонка и комментарий в `schema/table/currency.sql`; проверка — `schema/apply.sql` на чистой БД, `\d currency` показывает `show_in_equivalent boolean not null default true`
  Проверено: `apply.sql` на чистой `wallet_tmp_schema` — `\d currency` показывает колонку; сам `apply.sql` падал в конце на давнем `GRANT … f_operations_for_period(uuid, timestamp, timestamp, uuid)` в `role/wallet_reader.sql` (не обновлён после 000020) — исправлено в `add-operations-filter-functions` 2.1.

## 2. Push: необязательная колонка

- [x] 2.1 `TableSpec::optional_columns` в `src/sync_repo.hpp`, `"show_in_equivalent"` в `columns` и `optional_columns` у `currency` (`src/sync_repo.cpp`); проверка — сборка проходит
  Проверено: сборка `wallet_api` и `wallet_api_tests` (bookworm, тот же тулчейн, что Containerfile).
- [x] 2.2 Сборка upsert: отсутствующий ключ из `optional_columns` не попадает ни в `INSERT`, ни в `DO UPDATE SET`, ни в `update_by_uuid_sql`; присутствующий не boolean → `invalid_row` с именем поля (design D2); проверка — юнит-тест в `tests/test_sync_repo.cpp` на текст SQL для строки с ключом и без
  Проверено: сборка SQL вынесена в чистую `sync_repo::build_upsert`; 6 новых тестов в `test_sync_repo.cpp` (без ключа, с ключом, `"yes"`/`null`, обязательные колонки) зелёные.
- [x] 2.3 Интеграционные тесты в `tests_integration/test_push_batch.cpp` по сценариям `sync-push` «Флаг эквивалента у валюты» и «Необязательная колонка неверного типа»; проверка — `tests_integration/run_local.sh` зелёный
  Проверено: 5 тестов `push_*show_in_equivalent*`; `run_local.sh` (wallet-test, `wallet_api_it`) — 69 тестов, 0 упало.

## 3. Pull

- [x] 3.1 Интеграционный тест по сценариям `sync-pull` «Флаг эквивалента в строке валюты»; проверка — `run_local.sh` зелёный
  Проверено: `pull_currency_created_before_flag_carries_true_in_both_streams`, `pull_after_cursor_returns_flag_cleared_on_other_device`; `run_local.sh` зелёный.

## 4. REST валют

- [x] 4.1 `src/currencies_repo.{hpp,cpp}`: create/update/delete своей валюты в одной транзакции с `next_seq(ledger)` (design D4), проверки полей, видимости иконки, уникальности против своих и общих валют (D5), `currency_in_pair` (D6), `currency_in_use`; проверка — юнит-тесты разбора и проверки тела запроса в `tests/`
  Проверено: `tests/test_currencies.cpp` (6 тестов разбора `parse_create`/`parse_update`) зелёный.
- [x] 4.2 `src/currencies.cpp`: `POST /api/currencies`, `PATCH`/`DELETE /api/currencies/:uuid`, коды ответов по spec `currencies-api`; регистрация в `main.cpp`; проверка — сборка, ручной `curl` через gateway
  Проверено: wallet-api 0.1.1-rc.1 в test, `curl` через gateway test (`:8091`) токеном отдельного пользователя (`mint_loadtest_token`) — 401 без токена; POST минимальный → 201 с умолчаниями (`KZT`, `symbol`=`KZT`, `precision` 2, флаг `true`, `is_own`); 400 с `field` на пустой `name`, `precision` 9, небулев флаг, невидимую иконку; 409 `duplicate`/`iso_code` на дубль своей; PATCH `{show_in_equivalent:false}` → 200, остальные поля прежние; PATCH чужого uuid → 404; валюта приходит в `/sync/pull`; DELETE → 204, повторный → 404. Дубль с общей валютой в test не воспроизводим (общих валют нет) — покрыт `tests_integration/test_currencies.cpp`.
- [x] 4.3 `src/access.cpp`: ветка `/api/currencies` (`wallet:read` для GET/HEAD, `wallet:write` для остального); проверка — юнит-тест в `tests/test_access.cpp` по сценарию «Правка валюты без записи»
  Проверено: `access_required_scope_table` и `access_gate_end_to_end` (PATCH с `wallet:read` → 403 «нужен scope wallet:write») зелёные.
- [x] 4.4 Новый `tests_integration/test_currencies.cpp` по всем сценариям `currencies-api` (создание с умолчаниями, невалидные поля, невидимая иконка, общая → 404, дубль кода с общей → 409, код валюты пары → 409, тот же код → 200, удаление занятой → 409, свободной → 204 и tombstone в pull); проверка — `run_local.sh` зелёный
  Проверено: 10 тестов, `run_local.sh` — 69/69.

## 5. Контракт и документация

- [x] 5.1 `openapi.yaml`: тег `currencies` с `createCurrency`/`updateCurrency`/`deleteCurrency` и схемой строки; строка `currency` в `syncPush` (необязательное `show_in_equivalent`) и `syncPull`; проверка — поля и операции видны в `/docs`
  Проверено: YAML разбирается; локально запущенный сервис отдаёт в `GET /openapi.yaml` (источник `/docs`) все три операции и `show_in_equivalent`. Сам Swagger UI в браузере не открывался.
- [x] 5.2 `README.md`: раздел «Валюты» (REST, правила D5/D6), разделы схемы и синка (необязательные колонки, почему не как `account.kind`); проверка — просмотр диффа
  Проверено: дифф просмотрен.

## Workflow follow-up

- Выкатка до wallet-report и клиентов (см. design, Migration Plan).
- Архивировать вместе с парными `currency-ui-tweaks` в wallet-report, android-wallet и wallet-web.
