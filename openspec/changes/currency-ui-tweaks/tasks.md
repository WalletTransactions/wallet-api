# Tasks

## 1. Схема

- [ ] 1.1 Миграция `migrations/000026_currency_show_in_equivalent.up.sql` (`ADD COLUMN show_in_equivalent boolean NOT NULL DEFAULT true` + `COMMENT ON COLUMN`) и `.down.sql` (`DROP COLUMN`); проверка — `up` → `down` → `up` на локальной БД (`docker compose --env-file infra/db/.env`) проходит без ошибок
- [ ] 1.2 Колонка и комментарий в `schema/table/currency.sql`; проверка — `schema/apply.sql` на чистой БД, `\d currency` показывает `show_in_equivalent boolean not null default true`

## 2. Push: необязательная колонка

- [ ] 2.1 `TableSpec::optional_columns` в `src/sync_repo.hpp`, `"show_in_equivalent"` в `columns` и `optional_columns` у `currency` (`src/sync_repo.cpp`); проверка — сборка проходит
- [ ] 2.2 Сборка upsert: отсутствующий ключ из `optional_columns` не попадает ни в `INSERT`, ни в `DO UPDATE SET`, ни в `update_by_uuid_sql`; присутствующий не boolean → `invalid_row` с именем поля (design D2); проверка — юнит-тест в `tests/test_sync_repo.cpp` на текст SQL для строки с ключом и без
- [ ] 2.3 Интеграционные тесты в `tests_integration/test_push_batch.cpp` по сценариям `sync-push` «Флаг эквивалента у валюты» и «Необязательная колонка неверного типа»; проверка — `tests_integration/run_local.sh` зелёный

## 3. Pull

- [ ] 3.1 Интеграционный тест по сценариям `sync-pull` «Флаг эквивалента в строке валюты»; проверка — `run_local.sh` зелёный

## 4. REST валют

- [ ] 4.1 `src/currencies_repo.{hpp,cpp}`: create/update/delete своей валюты в одной транзакции с `next_seq(ledger)` (design D4), проверки полей, видимости иконки, уникальности против своих и общих валют (D5), `currency_in_pair` (D6), `currency_in_use`; проверка — юнит-тесты разбора и проверки тела запроса в `tests/`
- [ ] 4.2 `src/currencies.cpp`: `POST /api/currencies`, `PATCH`/`DELETE /api/currencies/:uuid`, коды ответов по spec `currencies-api`; регистрация в `main.cpp`; проверка — сборка, ручной `curl` через gateway
- [ ] 4.3 `src/access.cpp`: ветка `/api/currencies` (`wallet:read` для GET/HEAD, `wallet:write` для остального); проверка — юнит-тест в `tests/test_access.cpp` по сценарию «Правка валюты без записи»
- [ ] 4.4 Новый `tests_integration/test_currencies.cpp` по всем сценариям `currencies-api` (создание с умолчаниями, невалидные поля, невидимая иконка, общая → 404, дубль кода с общей → 409, код валюты пары → 409, тот же код → 200, удаление занятой → 409, свободной → 204 и tombstone в pull); проверка — `run_local.sh` зелёный

## 5. Контракт и документация

- [ ] 5.1 `openapi.yaml`: тег `currencies` с `createCurrency`/`updateCurrency`/`deleteCurrency` и схемой строки; строка `currency` в `syncPush` (необязательное `show_in_equivalent`) и `syncPull`; проверка — поля и операции видны в `/docs`
- [ ] 5.2 `README.md`: раздел «Валюты» (REST, правила D5/D6), разделы схемы и синка (необязательные колонки, почему не как `account.kind`); проверка — просмотр диффа

## Workflow follow-up

- Выкатка до wallet-report и клиентов (см. design, Migration Plan).
- Архивировать вместе с парными `currency-ui-tweaks` в wallet-report, android-wallet и wallet-web.
