## ADDED Requirements

### Requirement: Исключение операций по подстроке комментария
`f_operations_for_period` и `f_operations_total` SHALL принимать необязательный
`p_exclude_qs text[]` (по умолчанию `NULL` — фильтр не задан): операция, чей
комментарий содержит ЛЮБОЙ из вариантов (без учёта регистра, `ё` = `е`,
буквально), не попадает ни в страницу, ни в итог (`total_eq`, `matched`).
Операция с пустым комментарием не исключается. Фильтр объединяется с остальными
по И, в том числе с `p_q`/`p_qs`.

#### Scenario: Ложное срабатывание
- **WHEN** `p_qs => {стриж}`, `p_exclude_qs => {машинк}`, комментарии «Стрижка» и «Машинка для стрижки волос»
- **THEN** лента и `f_operations_total` содержат только «Стрижка»

#### Scenario: Регистр и ё
- **WHEN** `p_exclude_qs => {ЁЛКА}`, комментарий «новогодняя елка»
- **THEN** операция исключена

#### Scenario: Пустой комментарий
- **WHEN** `p_exclude_qs => {такси}`, у операции комментарий `NULL`
- **THEN** операция остаётся в ленте и в итоге

#### Scenario: Без параметра
- **WHEN** `p_exclude_qs` не передан
- **THEN** результат функций тот же, что до миграции

### Requirement: Агрегат операций по категориям
`f_operations_by_category` SHALL принимать те же фильтры, что `f_operations_total`
(`p_category_uuids`, `p_exclude_category_uuids`, `p_wallet_uuids`, `p_kind`, `p_q`,
`p_qs`, `p_exclude_qs`) и возвращать по одной строке на категорию подходящих
операций: `category_uuid`, `category_name`, `matched` (число операций),
`total_eq` (с `p_kind` — сумма, без — сальдо доходы минус расходы, как у
`f_operations_total`), `first_date` и `last_date` (самая ранняя и самая поздняя
дата). Прямые переводы и долги — одна строка с `NULL` в `category_uuid`.
Операции без курса к эквиваленту считаются в `matched` и датах, но не входят в
`total_eq`. Сумма `total_eq` и `matched` по строкам равна `total_eq` и
`matched` у `f_operations_total` с теми же аргументами.

#### Scenario: Две категории
- **WHEN** `p_qs => {стриж}`, `p_kind => 'expense'`, «Стрижка» 23 в Personal Care и 15 в «Красота и уход»
- **THEN** две строки: по одной на категорию, `total_eq` 23 и 15, `first_date`/`last_date` — даты операций категории

#### Scenario: Согласованность с итогом
- **WHEN** те же аргументы передаются в `f_operations_total`
- **THEN** сумма `matched` строк равна `matched`, сумма `total_eq` — `total_eq` итога

#### Scenario: Ничего не найдено
- **WHEN** подходящих операций нет
- **THEN** функция возвращает ноль строк

#### Scenario: Чужой леджер
- **WHEN** `p_ledger_id` другого пользователя
- **THEN** ноль строк, операции чужого леджера не видны

### Requirement: Права на функции ленты
Роль `wallet_reader` SHALL иметь `EXECUTE` на `f_operations_for_period`,
`f_operations_total` и `f_operations_by_category` после миграции; прав на
запись и DDL SHALL не получать.

#### Scenario: Чтение под wallet_reader
- **WHEN** wallet-report вызывает `f_operations_by_category` ролью `wallet_reader`
- **THEN** вызов выполняется, а `INSERT` в таблицу операций той же ролью отклоняется
