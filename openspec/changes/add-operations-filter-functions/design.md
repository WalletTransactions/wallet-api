# Design

## Context

- `f_operations_for_period(p_ledger_id, p_from, p_to, p_eq_currency, p_limit
  DEFAULT 1000, p_cursor_date DEFAULT NULL, p_cursor_uuid DEFAULT NULL)`
  (000020) — `LANGUAGE sql STABLE`, выборка из `v_operation_eq` с `JOIN` на
  `account` (категория/кошелёк по стороне проводки), курсор
  `(date, uuid) < (…)`, `ORDER BY date DESC, uuid DESC LIMIT p_limit`.
  Мотивация — proposal.md, «Why».
- wallet-report зовёт её через `db::Database::exec()`, который не умеет
  передавать SQL NULL: необязательные параметры сейчас решены двумя текстами
  запроса (без `$6/$7` и с ними).
- Тип операции определяется только флагами `acc_from_is_operating` /
  `acc_to_is_operating`: оба — `transfer`, только from — `expense`, только to —
  `income`. Категория — неоперационная сторона, кошелёк — операционная.
- Без курса к `p_eq_currency` строка в `v_operation_eq` есть, но `amount_eq IS NULL`.
- Правило «без учёта регистра, ё = е» уже закреплено в схеме:
  `lower(translate(name, 'Ёё', 'Ее'))` (000024, `uq_account_name`).
- `GRANT EXECUTE` отчётных функций `wallet_reader` повторяется после каждого
  `DROP FUNCTION` (000022).
- Параллельно в работе: `currency-ui-tweaks` и `purge-synced-tombstones` (оба
  претендуют на 000026), `partition-operation-by-ledger` (пересоздаёт
  `v_operation`, `v_operation_eq`).

## Goals / Non-Goals

**Goals:**
- Одна логика фильтра для страницы и для итога, применённая до курсора и `LIMIT`.
- Старый позиционный вызов (5 и 7 аргументов) работает без изменений сразу после
  миграции, до выката нового wallet-report.
- Необязательные фильтры передаются без SQL NULL со стороны клиента.

**Non-Goals:**
- Индексы под фильтры (в том числе триграммный под `q`): объёмы одного леджера
  малы, ограничение по `ix_operation_date` остаётся главным.
- Изменение колонок результата `f_operations_for_period`.
- Проверка входных значений (`kind`, длина `q`, число uuid) — это делает
  wallet-report до вызова; функция принимает любые значения и просто фильтрует.

## Decisions

### D1. Расширить `f_operations_for_period`, а не заводить вторую функцию ленты

Новая сигнатура (DROP + CREATE, как в 000020/000022):

```
f_operations_for_period(
    p_ledger_id      uuid,
    p_from           timestamp,
    p_to             timestamp,
    p_eq_currency    uuid,
    p_limit          integer   DEFAULT 1000,
    p_cursor_date    timestamp DEFAULT NULL,
    p_cursor_uuid    uuid      DEFAULT NULL,
    p_category_uuids uuid[]    DEFAULT NULL,
    p_wallet_uuids   uuid[]    DEFAULT NULL,
    p_kind           text      DEFAULT NULL,
    p_q              text      DEFAULT NULL
) RETURNS TABLE (… как в 000020 …)
```

Позиционные вызовы с 5 и 7 аргументами разрешаются в эту же функцию через
`DEFAULT`, поэтому старый wallet-report продолжает работать.
Альтернатива — новая `f_operations_filtered` рядом со старой — отклонена: две
копии тела ленты расходились бы молча, а старая без фильтров была бы чистым
частным случаем новой.

### D2. Вызов именованной нотацией вместо NULL

wallet-report передаёт только заданные параметры по имени:
`f_operations_for_period($1, $2, $3, $4, $5, p_kind => $6, p_q => $7)`. Не
переданный параметр получает `DEFAULT NULL` в самой базе, клиенту NULL слать не
нужно. Это обобщение приёма «два текста запроса» на любое число необязательных
параметров. Курсор тоже можно передавать именованно (`p_cursor_date => …`).
Массивы приходят текстовым литералом `'{uuid,uuid}'` с приведением `$n::uuid[]`.
Альтернатива — «пустой массив/пустая строка = нет фильтра» — отклонена: смысл
`'{}'` («ни одной категории») и «фильтр не задан» тогда сливаются.

### D3. Условия фильтра — по флагам проводки, без опоры на JOIN

В `WHERE` до `ORDER BY … LIMIT`:

- категория: `(NOT acc_from_is_operating AND acc_fr_uuid = ANY(p_category_uuids))
  OR (NOT acc_to_is_operating AND acc_to_uuid = ANY(p_category_uuids))`;
- кошелёк: то же с операционной стороной, так что прямой перевод кошелёк →
  кошелёк подходит, если любой из двух кошельков в списке. uuid категории в
  `p_wallet_uuids` (и наоборот) ни с чем не совпадёт;
- `kind`: те же выражения по флагам, что в `CASE` колонки `kind`;
- `q`: `strpos(lower(translate(comment, 'Ёё', 'Ее')), lower(translate(p_q, 'Ёё', 'Ее'))) > 0`.
  `strpos`, а не `LIKE`: `%` и `_` в тексте пользователя не становятся
  шаблоном, экранировать нечего. Нормализация — та же, что у `uq_account_name`.
  Пустой `comment` (NULL) не подходит.

Каждое условие начинается с `p_x IS NULL OR …`. Фильтр по чужому uuid ничего не
находит: вся выборка уже ограничена `ledger_id = p_ledger_id`.

### D4. Итог — отдельная функция `f_operations_total` с теми же условиями

```
f_operations_total(
    p_ledger_id uuid, p_from timestamp, p_to timestamp, p_eq_currency uuid,
    p_category_uuids uuid[] DEFAULT NULL, p_wallet_uuids uuid[] DEFAULT NULL,
    p_kind text DEFAULT NULL, p_q text DEFAULT NULL
) RETURNS TABLE (total_eq numeric, incomplete boolean, matched bigint)
```

Ровно одна строка: для пустого результата `total_eq = 0`, `incomplete = false`,
`matched = 0`. Курсор и лимит итог не учитывает: он за весь период.

**Правило знака `total_eq`:**
- `p_kind` задан — сумма `amount_eq` подходящих операций, неотрицательная
  («сколько ушло на такси»: `kind = expense`);
- `p_kind` не задан — сальдо: `Σ income − Σ expense`, прямые переводы
  кошелёк → кошелёк дают 0 (деньги не выходят из кошельков пользователя).
  Разновалютный перевод через категорию Transfer — это пара expense + income, и
  его ноги взаимно погашаются, как в `/expense-structure`.

Модуль суммы без `kind` отклонён: «расход 100 + доход 100 = 200» не значит
ничего. Отдельные суммы по каждому типу отложены: клиенту, которому они нужны,
достаточно передать `kind`.

`incomplete = bool_or(amount_eq IS NULL)` по всем подходящим; такие операции в
сумму не входят.

Альтернатива — одна внутренняя функция фильтра, которую зовут и лента, и итог, —
отклонена: инлайнинг вложенной SQL-функции не гарантирован, а лента без него
может потерять диапазонный скан `ix_operation_date` под `LIMIT`. Повтор
условия в двух функциях страхуется тестом согласованности (wallet-report,
`add-operations-filters`: итог = сумма по всем страницам).

### D5. Права и зеркала

Миграция повторяет `GRANT EXECUTE … TO wallet_reader` для новой сигнатуры
`f_operations_for_period` и для `f_operations_total`. Зеркала:
`schema/function/f_operations_for_period.sql` (текущее состояние),
новый `schema/function/f_operations_total.sql`, включение в `schema/apply.sql`
после `f_operations_for_period`, `schema/role/wallet_reader.sql`,
`schema/function/README.md`.

### D6. Тесты

C++-логики репозитория в wallet-api не меняется, поэтому юнит- и
интеграционных тестов в `tests/` и `tests_integration/` wallet-api change не
добавляет. Поведение функций проверяют интеграционные тесты wallet-report
(`tests_integration/test_reports.cpp`): по `wallet-schema-ownership` смысл
отчётных функций принадлежит его спекам. Здесь проверка — up → down → up и
вызовы под `wallet_reader` через psql.

## Risks / Trade-offs

- [`lower()` не опускает кириллицу при не-UTF-8 `lc_ctype` базы] → то же
  допущение уже держит `uq_account_name` (000024). В задаче проверки — вызов с
  «Няня»/«НЯНЯ»/«нЯня» под `wallet_reader`.
- [Две копии условия фильтра разойдутся] → тест согласованности в wallet-report
  (итог `matched` = число строк по всем страницам, `total_eq` = сумма по ним с
  правилом знака).
- [`q` без индекса на долгом периоде] → просмотр ограничен леджером и периодом.
  Замер — `EXPLAIN (ANALYZE)` на test-дампе (~34 тыс. операций), порог — не хуже
  ленты без фильтра того же периода более чем вдвое.
- [Down при новом wallet-report] → после отката именованные параметры фильтров
  неизвестны и запросы с фильтрами упадут (500). Откат делается вместе с
  откатом wallet-report. Запросы без фильтров работают и после down.
- [Номер миграции] → 000026 уже заявлен двумя changes (`currency-ui-tweaks`,
  `purge-synced-tombstones`). Номер — следующий свободный на момент реализации.
  Объекты не пересекаются ни с ними, ни с `partition-operation-by-ledger`.

## Migration Plan

**Порядок относительно `partition-operation-by-ledger`:** независимы, любой
может идти первым. Обе функции `LANGUAGE sql` без `BEGIN ATOMIC`, поэтому
обращение к `v_operation_eq` разрешается при вызове, и пересоздание вьюхи в
миграции секционирования их не задевает. Если этот change выкатывается первым,
базовую линию `EXPLAIN` из задачи 1.1 секционирования стоит снять и для вызова
с фильтрами.

1. Миграция `0000NN_operations_filters.up.sql` в одной транзакции:
   `DROP FUNCTION f_operations_for_period(uuid, timestamp, timestamp, uuid, integer, timestamp, uuid)`,
   `CREATE` с новой сигнатурой (D1, D3), `CREATE FUNCTION f_operations_total` (D4),
   `GRANT EXECUTE` обеим, `COMMENT ON FUNCTION`.
2. Выкат: миграция → wallet-api (код не изменился) → wallet-report с фильтрами.
   Между шагами старый wallet-report работает (D1).
3. Откат: `.down.sql` — `DROP` обеих функций и `CREATE` версии 000020
   дословно, с её `GRANT`.
