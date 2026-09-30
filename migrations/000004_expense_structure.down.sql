-- Откат 000004_expense_structure.up.sql. DROP FUNCTION снимает и выданный
-- GRANT EXECUTE сам по себе — отдельного REVOKE не нужно.
DROP FUNCTION IF EXISTS f_expanse_by_category_for_period(uuid, timestamp, timestamp, uuid);
