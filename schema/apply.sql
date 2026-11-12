-- Разворачивание схемы с нуля в порядке зависимостей.
--
-- Здесь только включения — никакого DDL, чтобы не появилась вторая копия схемы,
-- которая молча разойдётся с файлами в table/. \ir включает относительно
-- расположения этого файла, поэтому запускать можно из любого каталога:
--
--   psql -v ON_ERROR_STOP=1 -f wallet-api/schema/apply.sql
--
-- Требуется PostgreSQL 13 или новее: gen_random_uuid() без расширения pgcrypto.
-- Проверялось на 16.
--
-- С 2026-09-04 источник истины для этой схемы — реальная миграция
-- wallet-api/migrations/000002_ledger_sync.up.sql (накатана и
-- проверена на живой базе, см. её шапку про три отличия от файлов здесь:
-- нет auth_nonce вообще — nonce мобильного входа живёт в памяти google-auth,
-- см. его README "Мобильный вход"; app_user и device проще — без третьего
-- слоя идентичности и без ротации refresh-токенов силами wallet-api, вся
-- выдача/ротация токенов централизована в google-auth). Эти файлы
-- по-прежнему читаемое зеркало происхождения решений (см. ../README.md), но
-- при расхождении с миграцией верна миграция, не этот каталог.

-- Порядок этих трёх строк не переставлять, он вынужденный с обеих сторон.
--
-- set_updated_at() идёт до таблиц: на неё ссылаются триггеры в файлах таблиц.
-- Тело у неё на plpgsql, оно при создании не разбирается, так что ссылок на
-- таблицы в этот момент не требуется.
--
-- next_seq(), наоборот, идёт ПОСЛЕ change_stream: тело SQL-функции разбирается
-- в момент CREATE FUNCTION (check_function_bodies включён по умолчанию), и без
-- существующей таблицы создание падает с «отношение change_stream не существует».
\ir function/set_updated_at.sql
\ir table/change_stream.sql
\ir function/next_seq.sql

-- Владение данными.
\ir table/ledger.sql
\ir table/app_user.sql
\ir table/ledger_member.sql
\ir table/ledger_invite.sql
\ir table/device.sql
\ir table/sync_push_batch.sql

-- Содержимое и справочники.
\ir table/blob.sql
\ir table/icon.sql
\ir table/currency.sql
\ir table/currency_pair.sql
\ir table/currency_pair_rate.sql
\ir table/currency_conversion.sql

-- Данные леджера.
\ir table/account.sql
\ir table/account_operating.sql
\ir table/account_asset.sql
\ir table/counterparty.sql
\ir table/account_debt.sql
\ir table/operation.sql
\ir table/operation_link.sql

-- Представления. Порядок внутри тоже вынужденный: тело вьюхи разбирается при
-- CREATE VIEW, поэтому каждая обязана идти после всех, на которые ссылается —
-- v_currency_conversion_rate после v_currency_conversion, v_operation_eq после
-- обеих.
\ir view/v_account_operating.sql
\ir view/v_account_expanse.sql
\ir view/v_currency_conversion.sql
\ir view/v_currency_conversion_rate.sql
\ir view/v_operation.sql
\ir view/v_operation_eq.sql

-- Отчётные функции — порт android-wallet/schema/select/. Идут последними: их тела
-- разбираются при CREATE FUNCTION и опираются на представления выше.
\ir function/f_balance_to_date.sql
\ir function/f_income_for_period.sql
\ir function/f_expanse_for_period.sql

-- Не порт клиента (см. её же комментарий) — агрегация только для веб-отчёта
-- "Структура расходов", группирует f_expanse_for_period ещё и по категории,
-- смешивая валюты через amount_eq. Идёт после f_expanse_for_period по тому
-- же принципу "рядом по смыслу", не из-за реальной зависимости.
\ir function/f_expanse_by_category_for_period.sql
\ir function/f_expense_by_category_by_month.sql

-- "Обзор" (000006), "Список операций" (000007), "Кошельки и остатки"
-- (000008, 000010), общий батч-баланс на несколько дат (000011) и
-- баланс-по-бакетам (000017, f_balance_series — забытый \ir, починено
-- 000018_balance_series_incremental вместе с самим переписыванием функции)
-- — тоже не порт клиента, каждая под свой веб-экран (см. их же комментарии).
\ir function/f_income_expense_by_month.sql
\ir function/f_expense_by_weekday_for_period.sql
\ir function/f_operations_for_period.sql
\ir function/f_operations_total.sql
\ir function/f_wallet_turnover_for_period.sql
\ir function/f_balance_to_dates.sql
\ir function/f_balance_series.sql

-- "Капитал" (000033, capital-assets) — сводка по активам, опирается на
-- v_account_operating.asset_type.
\ir function/f_assets_for_period.sql

-- "Долги" (000036, debts) — сводка по долговым кошелькам, опирается на
-- account_debt и counterparty.
\ir function/f_debts_for_period.sql

-- Роли — после всего остального, и порядок здесь тоже вынужденный: гранты идут
-- по ALL TABLES IN SCHEMA и по конкретным функциям, а это списки, вычисляемые в
-- момент выполнения. Роль, созданная раньше таблиц, осталась бы без прав на них.
\ir role/wallet_reader.sql
