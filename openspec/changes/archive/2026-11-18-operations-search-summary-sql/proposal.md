# Proposal

## Why

wallet-mcp (change `improve-search-summary`) должен отвечать на «сколько потратил на X,
когда первый и последний раз, в каких категориях лежит X, и без ложных срабатываний».
Для этого нужны два SQL-примитива, а схема БД и SQL-функции живут только в wallet-api
(`wallet_reader` не может ни создавать функции, ни писать): исключение операций по
подстроке комментария и агрегат «по категориям + границы дат» по тому же фильтру, что
у ленты операций.

## What Changes

- Миграция `000042_operations_search_summary`:
  - `f_operations_for_period` и `f_operations_total` получают необязательный параметр
    `p_exclude_qs text[] DEFAULT NULL`: операция, чей комментарий содержит ЛЮБОЙ из
    вариантов (те же правила, что у `p_qs`: без регистра, `ё` = `е`, буквально),
    не попадает ни в страницу, ни в итог. Операция с пустым (`NULL`) комментарием
    не исключается.
  - Новая функция `f_operations_by_category(...)` с теми же фильтрами, что у
    `f_operations_total`, возвращает строки `(category_uuid, category_name, matched,
    total_eq, first_date, last_date)` — по одной на категорию подходящих операций;
    строка с `NULL`-категорией — прямые переводы и долги. Знак `total_eq` — по тому же
    правилу, что у `f_operations_total` (с `p_kind` — сумма, без — сальдо).
  - Права `EXECUTE` роли `wallet_reader` на изменённые и новые функции.
- Down-миграция возвращает функции к виду 000036 дословно.
- Без фильтров поведение существующих функций прежнее; новые параметры необязательны.

## Capabilities

### New Capabilities
- `operations-feed-sql`: контракт SQL-функций ленты операций для wallet-report —
  фильтр исключения по тексту и агрегат по категориям.

### Modified Capabilities
<!-- нет -->

## Impact

- **wallet-api**: `migrations/000042_*`, `schema/` (справочный DDL), тест миграции в
  `tests_integration/`. Клиенты синка (android-wallet, wallet-telegram) не затронуты:
  таблицы не меняются.
- **wallet-report**: сопутствующий change `operations-search-summary` вызывает новые
  параметры и функцию.
- Порядок выкатки: wallet-api (миграция) → wallet-report → wallet-mcp. wallet-report без
  `exclude_q`/`summary` продолжает работать на старой сигнатуре (вызов именованной
  нотацией только с заданными параметрами).
