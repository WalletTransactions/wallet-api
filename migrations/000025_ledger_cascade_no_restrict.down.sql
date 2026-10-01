-- Откат 000025_ledger_cascade_no_restrict.up.sql. Возвращает RESTRICT и
-- неоткладываемые ключи — и вместе с ними 500 в DELETE /api/account у
-- пользователей со своей валютой или иконкой. SET CONSTRAINTS в
-- account_deletion_repo для неоткладываемых ключей — ошибка, поэтому откат
-- миграции — только вместе с откатом кода.
ALTER TABLE account_operating
    DROP CONSTRAINT account_operating_currency_uuid_fkey,
    ADD CONSTRAINT account_operating_currency_uuid_fkey
        FOREIGN KEY (currency_uuid) REFERENCES currency (uuid) ON DELETE RESTRICT;

ALTER TABLE currency_pair
    DROP CONSTRAINT currency_pair_base_currency_uuid_fkey,
    ADD CONSTRAINT currency_pair_base_currency_uuid_fkey
        FOREIGN KEY (base_currency_uuid) REFERENCES currency (uuid) ON DELETE RESTRICT,
    DROP CONSTRAINT currency_pair_quote_currency_uuid_fkey,
    ADD CONSTRAINT currency_pair_quote_currency_uuid_fkey
        FOREIGN KEY (quote_currency_uuid) REFERENCES currency (uuid) ON DELETE RESTRICT;

ALTER TABLE account
    DROP CONSTRAINT account_icon_uuid_fkey,
    ADD CONSTRAINT account_icon_uuid_fkey
        FOREIGN KEY (icon_uuid) REFERENCES icon (uuid) ON DELETE RESTRICT;

ALTER TABLE currency
    DROP CONSTRAINT currency_icon_uuid_fkey,
    ADD CONSTRAINT currency_icon_uuid_fkey
        FOREIGN KEY (icon_uuid) REFERENCES icon (uuid) ON DELETE RESTRICT;

ALTER TABLE operation
    DROP CONSTRAINT fk_operation_acc_fr,
    ADD CONSTRAINT fk_operation_acc_fr
        FOREIGN KEY (ledger_id, acc_fr_uuid) REFERENCES account (ledger_id, uuid),
    DROP CONSTRAINT fk_operation_acc_to,
    ADD CONSTRAINT fk_operation_acc_to
        FOREIGN KEY (ledger_id, acc_to_uuid) REFERENCES account (ledger_id, uuid);
