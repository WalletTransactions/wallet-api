-- Откат 000024_account_name_case_insensitive.up.sql. Старый индекс строже только
-- побайтово, так что имена, уникальные по новому правилу, уникальны и по старому.
DROP INDEX uq_account_name;
CREATE UNIQUE INDEX uq_account_name ON account (ledger_id, name) WHERE deleted_at IS NULL;

COMMENT ON COLUMN account.name IS
    'Название счёта/категории, видимое пользователю — уникально среди живых (deleted_at IS NULL) строк леджера, см. uq_account_name.';
