-- Откат 000012_account_system_kind.up.sql.
ALTER TABLE account DROP COLUMN IF EXISTS system_kind;
