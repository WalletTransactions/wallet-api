-- Откат 000011_balance_to_dates.up.sql.
DROP FUNCTION IF EXISTS f_balance_to_dates(uuid, timestamp[], uuid);
