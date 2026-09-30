-- Откат 000006_overview.up.sql.
DROP FUNCTION IF EXISTS f_expense_by_weekday_for_period(uuid, timestamp, timestamp, uuid);
DROP FUNCTION IF EXISTS f_income_expense_by_month(uuid, timestamp, timestamp, uuid);
