# Design

## Context

`account_asset (ledger_id, uuid)` — FK на `account_operating (ledger_id, uuid)`,
тот — на `account (ledger_id, uuid)`: у кошелька один uuid на три таблицы.
Мягкое удаление каскадов FK не запускает. Механизм для `operation_link` уже есть
(`cascade-link-tombstones`): один `UPDATE` в конце `push_batch` по строкам,
которых касается батч.

## Decisions

1. **Правила вместо второй копии кода.** `CascadeRule {child, parents[{table,
   child_column}]}`; SQL строит `build_cascade_sql(rule)`, входы собирает
   `cascade_inputs(changes, rule)`. Связи переходят на те же функции без
   изменения поведения — их интеграционные тесты остаются как есть.
2. **У актива два родителя: `account_operating` и `account`.** Телефон
   удаляет оба, но клиенту, удалившему только счёт, актив тоже не нужен:
   `v_account_operating` уже прячет кошелёк с удалённым счётом. Юнит-тест сверяет
   каждое правило с `sync_table_refs()`: `account_asset → account` — через
   `account_operating` по тому же uuid.
3. **Кандидаты без повторов колонок.** Оба родителя актива ссылаются по `uuid`,
   поэтому условие кандидатов — `c.uuid = ANY($4) OR c.uuid = ANY($5)`; uuid
   удалённых родителей не дублируются, `operation` как родитель дважды
   читается один раз.
4. **Событие лога — общее.** `sync_push_cascade` с полем `table` вместо
   `sync_push_link_cascade` (вышло в rc.5 того же дня, дашбордов на нём нет).
5. **Миграция 000035 — данные, откат пустой**, как у 000034.

## Risks / Trade-offs

- Оживление кошелька актив не оживляет — клиент, вернувший кошелёк, пришлёт
  актив заново, и правило его пропустит (оба родителя живы). Как у связей.
