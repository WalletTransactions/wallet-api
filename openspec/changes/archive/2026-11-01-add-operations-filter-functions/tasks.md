# Tasks

## 1. Миграция

- [x] 1.1 `migrations/0000NN_operations_filters.up.sql` (NN — следующий свободный номер с учётом `currency-ui-tweaks`, `purge-synced-tombstones` и `partition-operation-by-ledger`): в одной транзакции `DROP FUNCTION f_operations_for_period(uuid, timestamp, timestamp, uuid, integer, timestamp, uuid)`, `CREATE` с новой сигнатурой и условиями фильтра до курсора и `LIMIT` (design D1, D3), `CREATE FUNCTION f_operations_total` с правилом знака (D4), `GRANT EXECUTE … TO wallet_reader` обеим, `COMMENT ON FUNCTION`. Проверка: up на локальной базе (`docker compose --env-file infra/db/.env`) без ошибок; `\df f_operations_*` показывает обе функции с нужными сигнатурами
  Проверено: номер 000027 (после 000026 `currency-ui-tweaks`); up на копии test-дампа (`wallet_tmp_filters`, кластер wallet-test) и на чистой `wallet_tmp_mig` без ошибок, `\df` — 11 и 8 аргументов, EXECUTE у `wallet_reader` есть.
- [x] 1.2 `migrations/0000NN_operations_filters.down.sql`: `DROP` обеих функций и дословно версия 000020 с её `GRANT`. Проверка: up → down → up без ошибок; после down `\df f_operations_for_period` показывает 7 аргументов, `f_operations_total` нет
  Проверено: тело в down совпадает с 000020 построчно (`diff`); up → down → up на `wallet_tmp_filters`, после down — одна функция с 7 аргументами.
- [x] 1.3 Совместимость со старым вызовом: под `wallet_reader` вызвать `f_operations_for_period` позиционно с 5 и с 7 аргументами (как текущий `reports_repo.cpp`) на леджере с операциями. Проверка: оба вызова проходят и возвращают те же строки, что до миграции (сверка `md5(string_agg(...))` до/после)
  Проверено: 5 арг. (1001 строка и весь период — 8741), 7 арг. (1001) — `md5` до миграции, после up и после down совпадают.
- [x] 1.4 Ручная проверка фильтров и итога через psql под `wallet_reader`, именованной нотацией (D2): каждый фильтр отдельно и вместе; категория в `p_wallet_uuids` ничего не находит; прямой перевод находится по любому из двух кошельков; `q` = «НЯНЯ»/«нЯня»/«Ёлка» против «няня»/«елка»; `q` с `%` и `_` ищется буквально; `f_operations_total` без `p_kind` даёт `Σ income − Σ expense` при переводах = 0, с `p_kind` — неотрицательную сумму; операция без курса даёт `incomplete = true` и не входит в сумму; пустой результат — одна строка `0 / false / 0`. Проверка: каждый случай — запрос и ожидаемый результат, записаны в описание PR
  Проверено: контрольный набор из 9 операций на `wallet_tmp_mig`, 11 групп случаев (A–K, включая страницы под курсором) — все совпали с ожидаемым; запросы и результаты в описании PR.
- [x] 1.5 `EXPLAIN (ANALYZE, BUFFERS)` ленты с фильтром `q` и без фильтров за год на копии test-дампа. Проверка: в плане диапазонный скан `ix_operation_date`, время с `q` — не более чем вдвое больше ленты без фильтра; планы приложены к PR
  Проверено: на копии test-дампа (28 670 операций) — оба плана `Bitmap Index Scan on ix_operation_date`; год без фильтров ~90–107 мс (как у версии 000020), с `q` ~2–6 мс; планы — в комментарии к PR.

## 2. Справочная схема и документация

- [x] 2.1 `schema/function/f_operations_for_period.sql` — текущее состояние после миграции (с фильтрами и комментарием про именованную нотацию); новый `schema/function/f_operations_total.sql`; включение в `schema/apply.sql` после `f_operations_for_period`; `GRANT` в `schema/role/wallet_reader.sql`. Проверка: `psql -v ON_ERROR_STOP=1 -f schema/apply.sql` на чистой базе проходит, `\df` совпадает с базой после миграции
  Проверено: `apply.sql` на чистой `wallet_tmp_schema2` проходит (заодно исправлен устаревший 4-аргументный `GRANT`, из-за которого он падал); сигнатуры, результат, EXECUTE и `md5(prosrc)` совпадают с базой после миграции.
- [x] 2.2 `schema/function/README.md` и `schema/README.md` (таблица отчётных функций): фильтры, правило знака итога, ссылка на спеку wallet-report `operations-list`. Проверка: описание сверено с design D3/D4, ссылки открываются
  Проверено: сверено с D3/D4; ссылка на `wallet-report/openspec/specs/operations-list` существует в main (`gh api`).

## Workflow follow-up

- Миграция выкатывается раньше wallet-report `add-operations-filters`. Архивировать оба change после выката wallet-report.
- Если этот change выкатывается раньше `partition-operation-by-ledger`, в его базовую линию (задача 1.1 того change) стоит добавить `EXPLAIN` ленты с фильтрами.
