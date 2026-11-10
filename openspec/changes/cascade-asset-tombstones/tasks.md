# Tasks

## 1. Push

- [x] 1.1 (юнит: 78 тестов, 0 упавших) `cascade_rules()`, `cascade_inputs`, `build_cascade_sql` вместо `link_cascade_inputs`; правило `account_asset`. Проверка: юнит-тесты в `tests/test_sync_repo.cpp` — сверка правил с `sync_table_refs()`, входы для связей и активов, текст SQL
- [x] 1.2 (4 теста связей и 3 новых — зелёные) Интеграционные тесты в `tests_integration/test_push_batch.cpp` на три сценария спеки; тесты связей (`cascade-link-tombstones`) зелёные без изменений

## 2. Схема

- [x] 2.1 (2026-11-10: up → down 1 → up на postgres:16-alpine; копия test `wallet_api`: 3 → 0 за 17 мс, все с `seq` 145 = новая голова) Миграция `000035_tombstone_orphan_account_assets.up/down.sql`. Проверка: up → down → up на одноразовом Postgres; на копии test — живых активов удалённых кошельков 0, затронутые с новым `seq`

## 3. Документация

- [x] 3.1 (openapi-spec-validator: OK) README wallet-api (синк) и `openapi.yaml` (`syncPush`) — правило про активы. Проверка: openapi-spec-validator OK

## 4. Интеграция

- [x] 4.1 (2026-11-10: 101 тест, 0 упавших) `tests_integration` целиком зелёные
- [ ] 4.2 После выкатки на test: синк Pixel 8 Pro без «строки без родителя — account_asset»
