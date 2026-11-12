-- Расширение кошелька — признак долгового кошелька (change debts, миграция
-- 000036), по образцу account_asset. Строка есть и жива — кошелёк долговой:
-- его баланс — долг, «+» — контрагент должен леджеру, «−» — леджер должен
-- контрагенту. Деньги ходят обычными переводами, поэтому доход и расход долг
-- не искажает; прощение и проценты — проводки с обычной категорией. Мягкое
-- удаление возвращает кошелёк в обычные, не трогая его операции и баланс.
--
-- Уникальности «контрагент + валюта» нет намеренно: второй заём тому же
-- человеку в той же валюте — ещё один кошелёк со своими due_date и comment.
--
-- FK на account_operating, а не на account: «долг только у кошелька» держит
-- схема — строка на категории даёт 23503 (409 missing_reference в push).
-- Каскад от удаления леджера идёт account → account_operating → account_debt.
-- Мягкое удаление кошелька гасит его account_debt в push_batch
-- (sync_repo::cascade_rules(), как у account_asset). Отчёты считают кошелёк
-- долговым, только если живы account, account_operating и account_debt
-- (v_account_operating).
CREATE TABLE account_debt (
    uuid              uuid        NOT NULL,
    ledger_id         uuid        NOT NULL,
    seq               bigint      NOT NULL,
    deleted_at        timestamptz,
    updated_at        timestamptz NOT NULL DEFAULT now(),
    updated_by        uuid REFERENCES device (id) ON DELETE SET NULL,

    counterparty_uuid uuid        NOT NULL,
    comment           text        NOT NULL DEFAULT '',
    due_date          date,

    CONSTRAINT pk_account_debt PRIMARY KEY (ledger_id, uuid),
    CONSTRAINT fk_account_debt_account_operating
        FOREIGN KEY (ledger_id, uuid) REFERENCES account_operating (ledger_id, uuid) ON DELETE CASCADE,
    CONSTRAINT fk_account_debt_counterparty
        FOREIGN KEY (ledger_id, counterparty_uuid) REFERENCES counterparty (ledger_id, uuid)
        ON DELETE NO ACTION DEFERRABLE INITIALLY IMMEDIATE
);

CREATE INDEX ix_account_debt_sync ON account_debt (ledger_id, seq);
CREATE INDEX ix_account_debt_counterparty ON account_debt (ledger_id, counterparty_uuid);

CREATE TRIGGER trg_account_debt_updated_at BEFORE UPDATE ON account_debt
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE account_debt IS
    'Признак долгового кошелька: живая строка — кошелёк является долгом перед контрагентом или контрагента. Баланс «+» — контрагент должен леджеру, «−» — леджер должен контрагенту. uuid всегда равен account.uuid и account_operating.uuid.';
COMMENT ON COLUMN account_debt.uuid IS '= account_operating.uuid того же кошелька.';
COMMENT ON COLUMN account_debt.ledger_id IS '= account_operating.ledger_id того же кошелька.';
COMMENT ON COLUMN account_debt.seq IS 'Версия строки в потоке изменений леджера — своя, отдельная от account.seq.';
COMMENT ON COLUMN account_debt.deleted_at IS
    'Момент мягкого удаления (снятие признака долга); NULL — кошелёк долговой.';
COMMENT ON COLUMN account_debt.updated_at IS 'Момент последнего изменения строки — только диагностика.';
COMMENT ON COLUMN account_debt.updated_by IS 'Устройство, применившее последнее изменение этой строки.';
COMMENT ON COLUMN account_debt.counterparty_uuid IS
    'Контрагент долга. Уникальности «контрагент + валюта» нет: у контрагента может быть несколько займов.';
COMMENT ON COLUMN account_debt.comment IS 'Свободный комментарий к займу.';
COMMENT ON COLUMN account_debt.due_date IS 'Срок возврата; NULL — срок не задан.';
