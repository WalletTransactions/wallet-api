# Design

## Context

Мотивация — в proposal.md, раздел Why. Что есть сейчас:

- `operation`: PK `(ledger_id, uuid)`. FK на `ledger` (CASCADE), `device`
  (SET NULL) и два составных FK на `account (ledger_id, uuid)`, оба
  `DEFERRABLE INITIALLY IMMEDIATE` (000025). Индексы: `ix_operation_sync
  (ledger_id, seq)` и три частичных `WHERE deleted_at IS NULL` (`ix_operation_date`,
  `ix_operation_acc_fr`, `ix_operation_acc_to`). Триггер
  `trg_operation_updated_at`.
- `operation_link`: PK `(ledger_id, uuid)`. Два составных FK на `operation`
  (CASCADE), частичный уникальный `uq_operation_link_natural (ledger_id,
  main_uuid, link_uuid)`, индексы `ix_operation_link_sync`,
  `ix_operation_link_link`.
- Во всех уникальных ограничениях обеих таблиц уже есть `ledger_id`, поэтому
  PostgreSQL разрешит секционирование без смены ключей.
- Кто зависит от таблиц:
  - вьюхи `v_operation`, `v_operation_eq` и, возможно, построенные на них.
    Вьюха привязана к таблице по OID, поэтому при замене таблицы её нужно
    пересоздать;
  - SQL-функции `f_*` (`LANGUAGE sql` без `BEGIN ATOMIC`). Имя таблицы
    разрешается при вызове, правок не нужно;
  - `sync_repo.cpp` (push/pull) обращается по имени;
  - `account_deletion_repo.cpp`;
  - `wallet-report/src/reports_repo.cpp`, в том числе межледжерный запрос
    статистики владельцев (`JOIN owners`).
- PostgreSQL 16.15. Миграции катит golang-migrate v4.18.3, по одному файлу
  за раз. Перед миграцией prod `deploy.sh` снимает дамп. Старый контейнер
  wallet-api работает, пока миграция идёт.
- Объём: test ≈ 34 тыс. операций, 11 МБ.

## Goals / Non-Goals

**Goals:**
- Одна миграция в одной транзакции. При ошибке база остаётся в прежнем
  состоянии.
- Имена объектов, видимых коду, сохраняются: таблицы, PK/FK/CHECK, индексы на
  родителе, триггеры, вьюхи.
- Pruning до одной секции для всех запросов с `ledger_id`, в том числе внутри
  функций отчётов. Сейчас у них generic-план, поэтому отсечение происходит при
  выполнении (runtime pruning).

**Non-Goals:**
- Включать `enable_partitionwise_join` или `enable_partitionwise_aggregate`.
  Совпадающие номера секций оставляют эту возможность, но включать её без
  замеров не будем.
- Автоматическое управление секциями (pg_partman и т.п.). У HASH набор секций
  фиксированный, управлять нечем.
- Онлайн-миграция без блокировки (логическая репликация, двойная запись). На
  нынешних объёмах она не окупается.

## Decisions

### HASH (ledger_id), а не RANGE по дате и не LIST

- **RANGE по `"date"`** отвергнут. Ключ секционирования должен входить в PK,
  тогда PK стал бы `(ledger_id, uuid, date)` и сломал бы идентичность строки
  синка (`ON CONFLICT (ledger_id, uuid)`). Дату операции пользователь меняет,
  и каждая такая правка переносила бы строку между секциями. Pull по `seq`
  обходил бы все секции.
- **LIST по `ledger_id`** отвергнут: он требует секцию на каждый леджер и
  создание секции при регистрации пользователя, то есть DDL от app-роли, у
  которой DDL нет.
- **HASH** не требует обслуживания, распределяет строки равномерно, и каждый
  запрос «одного леджера» превращается в обращение к одной секции.

### 16 секций, одинаковый модуль у обеих таблиц

Оценка из `schema/README.md`: 100 тыс. пользователей × ~1 100 операций в год
дают ~110 млн строк в год, то есть ~7 млн на секцию в год. Нагрузку на
планировщик от 16 секций не заметно. Модуль потом можно удвоить по одной
секции за раз: отсоединить `p_r` (MODULUS 16), создать `MODULUS 32 REMAINDER r`
и `r+16`, перелить. Полной перестройки для этого не нужно. Одинаковый модуль
у `operation_link` кладёт связи леджера в секцию с тем же номером, что и его
операции.

Имена секций: `operation_p00` … `operation_p15`, `operation_link_p00` …
`operation_link_p15`.

### Перестройка через новую таблицу и переименование в одной транзакции

Порядок в up-файле:

1. `SET LOCAL lock_timeout = '5s'`. Если таблицу держит долгий запрос,
   миграция падает и не вешает выкат. Повтор — тем же `migrate.sh`.
2. `LOCK TABLE operation, operation_link IN ACCESS EXCLUSIVE MODE`. Сначала
   блокировка, потом чтение, чтобы старый сервис не дописал строку между
   копированием и заменой.
3. Создать `operation_new` и `operation_link_new` (`PARTITION BY HASH
   (ledger_id)`) и 16 секций для каждой.
4. `INSERT INTO operation_new SELECT * FROM operation`, затем то же для
   `operation_link`. Вставка не меняет `updated_at`: это INSERT, а триггер
   висит на UPDATE.
5. `DROP VIEW` зависимых вьюх. Список снят из `pg_depend` на test
   (2026-11-14): прямая зависимость только `v_operation`, на ней построена
   `v_operation_eq` — порядок удаления `v_operation_eq`, затем `v_operation`
   (создание — обратный). Материализованных представлений нет. Других FK на
   `operation`/`operation_link`, кроме перечисленных в Context, нет; автоимена
   FK, которые надо сохранить: `operation_ledger_id_fkey`,
   `operation_updated_by_fkey`, `operation_link_ledger_id_fkey`,
   `operation_link_updated_by_fkey`. Затем `DROP TABLE operation_link`,
   `DROP TABLE operation`.
6. `ALTER TABLE … RENAME` новых таблиц в старые имена. Затем на родителях
   создаются ограничения и индексы с прежними именами: `pk_operation`,
   `fk_operation_acc_fr/acc_to` (DEFERRABLE), FK на `ledger`/`device`, CHECK,
   `ix_operation_*`, `pk_operation_link`, `fk_operation_link_main/link`,
   `uq_operation_link_natural`, `ix_operation_link_*`. Индексы и ограничения
   создаются после переливания: так быстрее и сразу получаются прежние имена,
   которые до шага 5 заняты старыми объектами.
7. Триггеры `trg_operation_updated_at`, `trg_operation_link_updated_at` на
   родителях (PG ≥ 13 сам распространяет их на секции). Все `COMMENT ON`
   переносятся из `schema/table/*.sql`.
8. Пересоздать вьюхи дословно из `schema/view/*.sql`.
9. `GRANT SELECT, INSERT, UPDATE, DELETE` для `wallet_api` и `GRANT SELECT`
   для `wallet_reader` на обе таблицы и вьюхи. Default privileges мигратора
   эти права тоже выдают, явный GRANT — страховка на случай, если они
   разъехались между контурами.
10. `ANALYZE operation, operation_link`.

Начало и конец транзакции явные (`BEGIN`/`COMMIT`), как в 000002.

Отвергнутые варианты:
- **ATTACH старой таблицы как секции.** Для HASH так нельзя: строки старой
  таблицы не укладываются в один остаток.
- **`ALTER TABLE … RENAME` старой таблицы вместо DROP**, чтобы хранить копию.
  Копию и так даёт дамп перед prod-миграцией, а лишняя таблица осталась бы
  висеть в схеме и правах.

### Down-миграция

Зеркальна up: обычные таблицы с прежним DDL из 000002/000014/000025
(текущее состояние `schema/table/*.sql`), перелив, пересоздание вьюх и прав.
Существующие миграции не правятся.

### Справочный DDL

`schema/table/operation.sql` и `operation_link.sql` получают `PARTITION BY
HASH (ledger_id)` и блок секций. В шапке — ссылка на этот change. В
`schema/README.md`, раздел «Арендатор в ключе, а не в коде», «дверь оставлена
открытой» меняется на «секционировано, 16 секций, как удваивать». В
`schema/apply.sql` правок не нужно, он только включает файлы.

### Правки вне wallet-api

- **android-wallet, wallet-telegram**: правок нет, протокол и `openapi.yaml`
  не меняются.
- **wallet-report**: правок кода нет. Межледжерный запрос статистики
  владельцев (`JOIN owners`) обходит все 16 секций. Это допустимо: запрос
  админский и редкий. Нужна только проверка отчётов на test после выката.
- **wallet-infra / BuildPlatform**: правок нет. Миграция идёт штатным
  `migrate.sh` из образа wallet-api.

## Risks / Trade-offs

- [Блокировка на время перелива: старый wallet-api ждёт на `operation`] →
  на нынешних объёмах это секунды. Push и pull на клиентах повторяются сами.
  `lock_timeout` не даёт миграции зависнуть на долгом запросе.
- [Текст 409-ответа меняется: в `detail` для FK- и unique-ошибок на
  `operation`/`operation_link` вместо имени таблицы будет имя секции, а
  `constraint` для 23505 станет именем индекса секции] → разбор
  `parse_missing_reference` смотрит на ссылаемую таблицу (`account`,
  `operation` как родитель) и не задет. Составные FK этих таблиц и раньше не
  разбирались. Интеграционным тестом проверить, что android-wallet
  (`SyncEngine.parseMissingReference`) и `sync_repo` не завязаны на имя
  ссылающейся таблицы.
  **Проверено 2026-11-14 (grep по android-wallet, wallet-telegram, wallet-api,
  wallet-report):** `SyncEngine.parseMissingReference` читает только
  `error`/`table`/`uuid` тела 409 и сверяет `table` со своим `TABLE_ORDER` — ни
  имени ссылающейся таблицы, ни constraint не использует. В `sync_repo.cpp`
  `constraint_name` сравнивается только с `kUniqueNames` (`uq_account_name`,
  `uq_counterparty_name` — несекционированные таблицы); для `operation_link`
  23505 уходит в общий `duplicate_key` с `constraint` как справочным полем,
  которое никто не разбирает. Прочие совпадения по `fk_operation*` —
  `account_deletion_repo.cpp` (`SET CONSTRAINTS ... DEFERRED` по имени родителя;
  тест удаления леджера зелёный) и DDL SQLite в `WalletDbHelper` (локальная
  база клиента, к серверу не относится). Правок кода не требуется.
- [Generic-план в SQL-функциях отчётов может не отсечь секции] →
  runtime pruning работает и для параметров. Проверка — `EXPLAIN (ANALYZE)`
  по каждой `f_*` на test, в плане должно быть `Subplans Removed: 15`.
- [Запросы без `ledger_id` обходят 16 секций] → таких в горячем пути нет.
  Межледжерная статистика wallet-report — исключение, о нём сказано выше.
- [Конфликт номеров с `purge-synced-tombstones` (000026)] → номер
  назначается при реализации, той миграции, которая выкатывается позже.
  Миграции независимы: purge меняет `device` и `change_stream`, а не
  `operation`.
- [Удвоенный диск на время транзакции] → на нынешних объёмах это ~20 МБ, для
  хоста пренебрежимо. GPU и RAM не затронуты.
- [Секционирование без выигрыша по скорости сегодня] → осознанный выбор
  (proposal). Критерий успеха — ни один запрос не стал медленнее. Проверяется
  сравнением нагрузочного прогона до и после (`loadtest/compare_results.sh`).

## Migration Plan

1. Локально: up → проверки из tasks → down → up на копии test-дампа.
2. test: выкат тега wallet-api, `deploy.sh` катит миграцию. Smoke, проверка
   синка с телефона, отчёты wallet-web, нагрузочный прогон и сравнение с
   прошлым.
3. prod: штатный выкат. `deploy.sh` снимает дамп, затем катит миграцию.
4. Откат: образ откатывается без схемы, и старый код работает с
   секционированными таблицами, потому что контракт не изменился. Схему, если
   понадобится, возвращает `migrate.sh <env> wallet - down 1` (в prod — только
   осознанно, после дампа) или восстановление дампа.
