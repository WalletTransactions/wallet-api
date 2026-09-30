-- Откат 000002_ledger_sync — в обратном порядке зависимостей.

-- Роль сначала: DROP ROLE падает, пока за ней числятся выданные привилегии
-- (не то же самое, что владение объектами, но Postgres их тоже отслеживает).
-- DROP OWNED снимает все гранты этой роли разом, включая ALTER DEFAULT
-- PRIVILEGES из up.sql.
DROP OWNED BY wallet_reader;
DROP ROLE IF EXISTS wallet_reader;

DROP FUNCTION IF EXISTS f_expanse_for_period(uuid, timestamp, timestamp, uuid);
DROP FUNCTION IF EXISTS f_income_for_period(uuid, timestamp, timestamp, uuid);
DROP FUNCTION IF EXISTS f_balance_to_date(uuid, timestamp, uuid);

DROP VIEW IF EXISTS v_operation_eq;
DROP VIEW IF EXISTS v_operation;
DROP VIEW IF EXISTS v_currency_conversion_rate;
DROP VIEW IF EXISTS v_currency_conversion;
DROP VIEW IF EXISTS v_account_expanse;
DROP VIEW IF EXISTS v_account_operating;

DROP TABLE IF EXISTS operation_link;
DROP TABLE IF EXISTS operation;
DROP TABLE IF EXISTS account_operating;
DROP TABLE IF EXISTS account;

DROP TABLE IF EXISTS currency_conversion;
DROP TABLE IF EXISTS currency_pair_rate;
DROP TABLE IF EXISTS currency_pair;
DROP TABLE IF EXISTS currency;
DROP TABLE IF EXISTS icon;
DROP TABLE IF EXISTS blob;

DROP TABLE IF EXISTS sync_push_batch;
DROP TABLE IF EXISTS device;
DROP TABLE IF EXISTS ledger_member;
DROP TABLE IF EXISTS app_user;
DROP TABLE IF EXISTS ledger;

DROP FUNCTION IF EXISTS next_seq(uuid);
DROP TABLE IF EXISTS change_stream;
DROP FUNCTION IF EXISTS set_updated_at();
