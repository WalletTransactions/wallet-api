# Tasks

## 1. Миграция

- [x] 1.1 `migrations/000042_operations_search_summary.up.sql`: `DROP` старых `f_operations_for_period` и `f_operations_total`, `CREATE` с `p_exclude_qs text[] DEFAULT NULL` (последним), тела из 000036 + условие D1, `GRANT EXECUTE ... TO wallet_reader`, `COMMENT`. Проверка: миграция применяется на чистой базе (`tests_integration`).
- [x] 1.2 В той же миграции `f_operations_by_category` (D2, D3) и `GRANT EXECUTE`. Проверка: функция вызывается ролью `wallet_reader`.
- [x] 1.3 `000042_*.down.sql`: удалить `f_operations_by_category`, вернуть функции 000036 дословно с правами. Проверка: up → down → up проходит.
- [x] 1.4 Обновить справочный DDL в `schema/`. Проверка: diff схемы после `migrate up` совпадает со `schema/`.

## 2. Тесты

- [x] 2.1 Интеграционный тест `p_exclude_qs`: «Стрижка» + «Машинка для стрижки волос», `ё`/регистр, пустой комментарий, без параметра. Проверка: `tests_integration` зелёный.
- [x] 2.2 Интеграционный тест `f_operations_by_category`: две категории, чужой леджер, пустой результат, согласованность с `f_operations_total` (NULL-категория и операция без курса тестами не покрыты — довести). Проверка: `tests_integration` зелёный.
- [ ] 2.3 Замер времени `f_operations_by_category` на тестовой базе (год данных, 4 варианта `q`). Проверка: цифра в описании PR.

## 3. Выкатка

- [x] 3.1 README.md wallet-api не меняется (миграция не трогает API синка); описание тестов — tests_integration/README.md.
- [ ] 3.2 Выкатить на test (rc-тег) до wallet-report. Проверка: миграция применена, версия схемы 42 на test.
