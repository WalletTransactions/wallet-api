# Tasks

## 1. Схема и миграция

- [x] 1.1 Написать `migrations/000041_category_kind.up.sql`: `ALTER TABLE account ADD COLUMN category_kind smallint NOT NULL DEFAULT 2 CHECK (category_kind IN (0, 1, 2))` и `COMMENT ON COLUMN`; проверить, что файл применяется на чистой базе тем же `migrate.sh`, что и остальные.
- [x] 1.2 В том же файле разметить живые категории (`kind = 0`, `system_kind = 0`) по живым операциям леджера (D5 в `design.md`): только `acc_fr_uuid` → `1`, только `acc_to_uuid` → `0`; изменённым строкам один `next_seq` на леджер и `updated_by = NULL`. Проверить интеграционным тестом на сценариях спеки `category-kind` (только доход, только расход, обе стороны, без операций, удалённые операции, системная категория).
- [x] 1.3 Написать `000041_category_kind.down.sql` (удаление колонки); проверить цепочкой up → down → up на тестовой базе.
- [x] 1.4 Обновить `schema/table/account.sql` (колонка, CHECK, комментарий в стиле `system_kind`/`kind`); проверить, что `schema/apply.sql` собирается и `wallet_reader` читает колонку.

## 2. Синк

- [x] 2.1 Добавить `"category_kind"` в колонки `account` в `push_tables()` (`src/sync_repo.cpp`); проверить юнит-тестом в `tests/test_sync_repo.cpp`: строка без поля → `invalid_row`, со значением `1` — применяется.
- [x] 2.2 Интеграционный тест в `tests_integration/`: push `account` с `category_kind` = 0/1/2 и pull возвращают то же значение; `category_kind` = 3 → `400 invalid_row`; смена вида существующей категории получает новый `seq`.
- [x] 2.3 Интеграционный тест миграционной разметки: после применения `000041` на базе с категориями из спеки `category-kind` значения совпадают, а pull с курсором, дочитанным до миграции, отдаёт изменённые категории.

## 3. Контракт и документация

- [x] 3.1 В `openapi.yaml` добавить `category_kind` в `AccountPushRow` и `AccountPullRow` (integer, 0–2, описание значений) и в `required`; проверить, что `openapi.yaml` проходит линтер/валидацию, которой пользуется репозиторий.
- [x] 3.2 В `README.md` описать колонку (значения, умолчание `2`, правило для кошельков и системных категорий), отдельным пунктом — `400` для строки без `category_kind` и для значения вне `0..2`; проверить, что описание совпадает со спеками change.

## 4. Проверка

- [x] 4.1 Прогнать юнит-тесты `tests/` и интеграционные `tests_integration/` (throwaway postgres, как в `run_local.sh`); все проходят, `junit.xml` не оставлять изменённым в рабочем дереве.
- [x] 4.2 `openspec validate category-kind-income-expense --strict` без ошибок.

## Workflow follow-up

- Сразу после релиза сервера выпустить change `category-kind-income-expense` в `android-wallet` (пикер, создание и карточка категории, справочник): без него push счетов от приложения получит `400`.
- Заархивировать change после слияния и проверки на test.
