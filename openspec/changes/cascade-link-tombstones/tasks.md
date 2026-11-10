# Tasks

## 1. Push

- [x] 1.1 (плюс `pg_array_literal` — тот же юнит-тест) `sync_repo::link_cascade_inputs(changes)` — uuid операций, удалённых батчем, и uuid связей, присланных живыми. Проверка: юнит-тест в `tests/test_sync_repo.cpp` (удаление, живая связь, удалённая связь не попадает, нет таблиц, мусор вместо массива)
- [x] 1.2 (плюс проверка, что pull с курсором до батча отдаёт оба tombstone) `UPDATE operation_link …` в конце `push_batch` (design, решение 3), не в режиме «только новые операции». Проверка: интеграционные тесты в `tests_integration/test_push_batch.cpp` на четыре сценария спеки

## 2. Схема

- [x] 2.1 (2026-11-10: up → down 1 → up на одноразовом postgres:16-alpine; копия test `wallet_api`: 973 → 0, все с `seq` 141 = новая голова, 282 настоящие живы) Миграция `000034_tombstone_orphan_operation_links.up/down.sql` (design, решение 6). Проверка: up → down → up на одноразовом Postgres; на копии test-леджера живых связей с удалёнными операциями после up — 0, затронутые связи с новым `seq`

## 3. Документация

- [x] 3.1 (openapi-spec-validator: OK) README wallet-api (раздел синка) и `schema/README.md` — правило про связи удалённых операций; `openapi.yaml` — строка в описании `syncPush`. Проверка: openapi-spec-validator OK

## 4. Интеграция

- [x] 4.1 (2026-11-10: юнит — все зелёные; `tests_integration` — 98 тестов, 0 упавших; замер — design.md, Risks) `tests_integration` целиком зелёные; замер миграции на копии test-базы записан в design.md/Risks
- [ ] 4.2 После выкатки на test: Pixel 8 Pro — синк без «строки без родителя — operation_link»
