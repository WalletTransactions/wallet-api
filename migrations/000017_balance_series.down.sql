-- Откат 000017_balance_series.up.sql.
DROP FUNCTION IF EXISTS f_balance_series(uuid, date, date, text, uuid);
