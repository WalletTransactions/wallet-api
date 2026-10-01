-- Расширение account для кошельков: строка есть — счёт операционный, у него есть
-- валюта и баланс; строки нет — это категория. Наследование через общий первичный
-- ключ, ровно как в клиентской схеме: uuid здесь всегда равен account.uuid.
--
-- У категории своей валюты нет и быть не может — валюта операции по категории
-- определяется второй стороной проводки, то есть кошельком.
--
-- Отдельная синхронизируемая сущность со своими seq и deleted_at, а не колонка в
-- account: смена валюты кошелька и снятие «операционности» должны ехать между
-- устройствами как самостоятельные изменения.
--
-- FK на currency простой, без ledger_id: валюта бывает и общей, и локальной,
-- составной ключ арендатора здесь не построить (см. currency_pair.sql).
-- DEFERRABLE, а не RESTRICT: удаление аккаунта откладывает проверку до COMMIT,
-- иначе каскад от ledger падает на порядке (миграция 000025, README.md, `icon`).
CREATE TABLE account_operating (
    uuid          uuid        NOT NULL,
    ledger_id     uuid        NOT NULL,
    seq           bigint      NOT NULL,
    deleted_at    timestamptz,
    updated_at    timestamptz NOT NULL DEFAULT now(),
    updated_by    uuid REFERENCES device (id) ON DELETE SET NULL,

    currency_uuid uuid NOT NULL REFERENCES currency (uuid)
        ON DELETE NO ACTION DEFERRABLE INITIALLY IMMEDIATE,

    CONSTRAINT pk_account_operating PRIMARY KEY (ledger_id, uuid),
    CONSTRAINT fk_account_operating_account
        FOREIGN KEY (ledger_id, uuid) REFERENCES account (ledger_id, uuid) ON DELETE CASCADE
);

CREATE INDEX ix_account_operating_sync     ON account_operating (ledger_id, seq);
CREATE INDEX ix_account_operating_currency ON account_operating (currency_uuid);

CREATE TRIGGER trg_account_operating_updated_at BEFORE UPDATE ON account_operating
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE account_operating IS
    'Расширение account для кошельков: строка есть — счёт операционный (есть валюта), строки нет — это категория. uuid всегда равен account.uuid.';
COMMENT ON COLUMN account_operating.uuid IS '= account.uuid того же счёта.';
COMMENT ON COLUMN account_operating.ledger_id IS '= account.ledger_id того же счёта.';
COMMENT ON COLUMN account_operating.seq IS 'Версия строки в потоке изменений леджера — своя, отдельная от account.seq.';
COMMENT ON COLUMN account_operating.deleted_at IS
    'Момент мягкого удаления (снятие "операционности" со счёта); NULL — строка активна.';
COMMENT ON COLUMN account_operating.updated_at IS 'Момент последнего изменения строки — только диагностика.';
COMMENT ON COLUMN account_operating.updated_by IS 'Устройство, применившее последнее изменение этой строки.';
COMMENT ON COLUMN account_operating.currency_uuid IS 'Валюта этого кошелька.';
