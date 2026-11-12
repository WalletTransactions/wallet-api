-- Контрагент долгов — человек или организация (change debts, миграция 000036).
-- К нему привязаны долговые кошельки (account_debt.counterparty_uuid); у одного
-- контрагента их может быть несколько — один заём, один кошелёк. Контрагенты
-- общие для всех участников леджера.
--
-- Имя уникально среди живых контрагентов леджера без учёта регистра, пробелов
-- по краям и «ё»/«е» — правило uq_account_name (000024) плюс btrim. Нарушение
-- в push — 409 с error = duplicate_name и conflicts[] (existing_uuid выжившей
-- строки), как у счёта.
--
-- Удаление контрагента, у которого остался живой account_debt, push отклоняет
-- (409 counterparty_in_use) — это держит sync_repo, а не схема: удаление
-- мягкое, FK его не видит. is_archived — признак интерфейса, на долги не влияет.
--
-- Ссылки внутри леджера (icon_uuid, account_debt → counterparty) — NO ACTION
-- DEFERRABLE INITIALLY IMMEDIATE, как в 000025: удаление леджера каскадом идёт
-- несколькими ветками, проверка откладывается до COMMIT.
CREATE TABLE counterparty (
    uuid          uuid        NOT NULL,
    ledger_id     uuid        NOT NULL REFERENCES ledger (id) ON DELETE CASCADE,
    seq           bigint      NOT NULL,
    deleted_at    timestamptz,
    updated_at    timestamptz NOT NULL DEFAULT now(),
    updated_by    uuid REFERENCES device (id) ON DELETE SET NULL,

    name          text        NOT NULL,
    comment       text        NOT NULL DEFAULT '',
    icon_uuid     uuid,
    is_archived   boolean     NOT NULL DEFAULT false,

    CONSTRAINT pk_counterparty PRIMARY KEY (ledger_id, uuid),
    CONSTRAINT fk_counterparty_icon
        FOREIGN KEY (icon_uuid) REFERENCES icon (uuid)
        ON DELETE NO ACTION DEFERRABLE INITIALLY IMMEDIATE
);

CREATE INDEX ix_counterparty_sync ON counterparty (ledger_id, seq);
CREATE INDEX ix_counterparty_icon ON counterparty (icon_uuid);

CREATE UNIQUE INDEX uq_counterparty_name
    ON counterparty (ledger_id, lower(btrim(translate(name, 'Ёё', 'Ее'))))
    WHERE deleted_at IS NULL;

CREATE TRIGGER trg_counterparty_updated_at BEFORE UPDATE ON counterparty
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE counterparty IS
    'Контрагент долгов (человек или организация): к нему привязаны долговые кошельки (account_debt). Общий для всех участников леджера.';
COMMENT ON COLUMN counterparty.uuid IS 'Идентификатор контрагента, выдаёт клиент.';
COMMENT ON COLUMN counterparty.ledger_id IS 'Леджер-владелец.';
COMMENT ON COLUMN counterparty.seq IS 'Версия строки в потоке изменений леджера.';
COMMENT ON COLUMN counterparty.deleted_at IS
    'Момент мягкого удаления; NULL — контрагент жив. Удаление при живых account_debt отклоняется (409 counterparty_in_use).';
COMMENT ON COLUMN counterparty.updated_at IS 'Момент последнего изменения строки — только диагностика.';
COMMENT ON COLUMN counterparty.updated_by IS 'Устройство, применившее последнее изменение этой строки.';
COMMENT ON COLUMN counterparty.name IS
    'Имя контрагента — уникально среди живых строк леджера без учёта регистра, пробелов по краям и «ё»/«е», см. uq_counterparty_name.';
COMMENT ON COLUMN counterparty.comment IS 'Свободный комментарий к контрагенту (телефон и т. п.).';
COMMENT ON COLUMN counterparty.icon_uuid IS 'Иконка контрагента; NULL — без иконки.';
COMMENT ON COLUMN counterparty.is_archived IS 'Архивный контрагент — признак интерфейса, на долги не влияет.';
