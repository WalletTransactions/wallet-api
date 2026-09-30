-- Откат 000014_operation_link_type.up.sql.
ALTER TABLE operation_link DROP COLUMN IF EXISTS type;
