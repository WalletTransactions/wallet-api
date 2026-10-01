-- «Удалить аккаунт» (DELETE /api/account) падал 500 у любого пользователя со своей
-- валютой или иконкой (org/docs/TODO_telegram_bot.md, шаг 8, 2026-10-01).
-- account_deletion_repo удаляет ledger и рассчитывает на ON DELETE CASCADE, но
-- каскад идёт несколькими вложенными запросами (ledger → currency, ledger →
-- account → account_operating), и проверка ссылки срабатывает в конце каждого:
-- currency удаляется раньше ссылающегося account_operating — ошибка 23503 на
-- account_operating_currency_uuid_fkey. NO ACTION вместо RESTRICT этого не
-- лечит — проверка всё равно в конце вложенного запроса, а не всего каскада.
--
-- Поэтому ключи внутри леджера — NO ACTION DEFERRABLE INITIALLY IMMEDIATE:
-- обычные запросы (push_batch и его 409 missing_reference) проверяются сразу,
-- как раньше, а delete_own_account откладывает проверку до COMMIT
-- (SET CONSTRAINTS ... DEFERRED), когда каскад уже снял всё. RESTRICT отложить
-- нельзя, отсюда и смена на NO ACTION. fk_operation_acc_* уже NO ACTION, но на
-- той же вложенности (ledger → operation и ledger → account) — тоже откладываем.
--
-- icon.content_sha256 → blob и ledger.id → change_stream не трогаем: blob общий,
-- каскадом не удаляется, а change_stream снимается отдельным DELETE после ledger.
ALTER TABLE account_operating
    DROP CONSTRAINT account_operating_currency_uuid_fkey,
    ADD CONSTRAINT account_operating_currency_uuid_fkey
        FOREIGN KEY (currency_uuid) REFERENCES currency (uuid)
        ON DELETE NO ACTION DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE currency_pair
    DROP CONSTRAINT currency_pair_base_currency_uuid_fkey,
    ADD CONSTRAINT currency_pair_base_currency_uuid_fkey
        FOREIGN KEY (base_currency_uuid) REFERENCES currency (uuid)
        ON DELETE NO ACTION DEFERRABLE INITIALLY IMMEDIATE,
    DROP CONSTRAINT currency_pair_quote_currency_uuid_fkey,
    ADD CONSTRAINT currency_pair_quote_currency_uuid_fkey
        FOREIGN KEY (quote_currency_uuid) REFERENCES currency (uuid)
        ON DELETE NO ACTION DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE account
    DROP CONSTRAINT account_icon_uuid_fkey,
    ADD CONSTRAINT account_icon_uuid_fkey
        FOREIGN KEY (icon_uuid) REFERENCES icon (uuid)
        ON DELETE NO ACTION DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE currency
    DROP CONSTRAINT currency_icon_uuid_fkey,
    ADD CONSTRAINT currency_icon_uuid_fkey
        FOREIGN KEY (icon_uuid) REFERENCES icon (uuid)
        ON DELETE NO ACTION DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE operation
    DROP CONSTRAINT fk_operation_acc_fr,
    ADD CONSTRAINT fk_operation_acc_fr
        FOREIGN KEY (ledger_id, acc_fr_uuid) REFERENCES account (ledger_id, uuid)
        DEFERRABLE INITIALLY IMMEDIATE,
    DROP CONSTRAINT fk_operation_acc_to,
    ADD CONSTRAINT fk_operation_acc_to
        FOREIGN KEY (ledger_id, acc_to_uuid) REFERENCES account (ledger_id, uuid)
        DEFERRABLE INITIALLY IMMEDIATE;
