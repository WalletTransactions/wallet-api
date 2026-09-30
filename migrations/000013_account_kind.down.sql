-- Откат 000013_account_kind.up.sql.
ALTER TABLE account DROP COLUMN IF EXISTS kind;
