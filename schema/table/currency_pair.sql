-- Валютная пара с направлением «база → квота» и собственной точностью курса.
-- Справочная таблица, область видимости как у currency.
--
-- FK на currency простые, по uuid, без ledger_id: валюта пары может быть и общей,
-- и локальной для леджера, поэтому составной ключ арендатора здесь не построить.
-- Что пара леджера не ссылается на чужую валюту, проверяет приложение — в схеме
-- этого выразить нельзя.
CREATE TABLE currency_pair (
    uuid              uuid PRIMARY KEY,
    ledger_id         uuid REFERENCES ledger (id) ON DELETE CASCADE,
    seq               bigint      NOT NULL,
    deleted_at        timestamptz,
    updated_at        timestamptz NOT NULL DEFAULT now(),
    updated_by        uuid REFERENCES device (id) ON DELETE SET NULL,

    symbol            text     NOT NULL,
    base_currency_uuid  uuid   NOT NULL REFERENCES currency (uuid)
        ON DELETE NO ACTION DEFERRABLE INITIALLY IMMEDIATE,
    quote_currency_uuid uuid   NOT NULL REFERENCES currency (uuid)
        ON DELETE NO ACTION DEFERRABLE INITIALLY IMMEDIATE,
    "precision"       smallint NOT NULL DEFAULT 5 CHECK ("precision" BETWEEN 0 AND 10),

    CONSTRAINT ck_currency_pair_sides CHECK (base_currency_uuid <> quote_currency_uuid)
);

CREATE INDEX ix_currency_pair_reference_sync ON currency_pair (seq)            WHERE ledger_id IS NULL;
CREATE INDEX ix_currency_pair_ledger_sync    ON currency_pair (ledger_id, seq) WHERE ledger_id IS NOT NULL;

CREATE UNIQUE INDEX uq_currency_pair_symbol_reference ON currency_pair (symbol)            WHERE ledger_id IS NULL     AND deleted_at IS NULL;
CREATE UNIQUE INDEX uq_currency_pair_symbol_ledger    ON currency_pair (ledger_id, symbol) WHERE ledger_id IS NOT NULL AND deleted_at IS NULL;

CREATE INDEX ix_currency_pair_base  ON currency_pair (base_currency_uuid);
CREATE INDEX ix_currency_pair_quote ON currency_pair (quote_currency_uuid);

CREATE TRIGGER trg_currency_pair_updated_at BEFORE UPDATE ON currency_pair
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE currency_pair IS
    'Валютная пара с направлением "база → квота" и собственной точностью курса. Справочная таблица, область видимости как у currency.';
COMMENT ON COLUMN currency_pair.uuid IS 'Идентификатор пары.';
COMMENT ON COLUMN currency_pair.ledger_id IS 'NULL — общая пара; заполнено — своя пара этого леджера.';
COMMENT ON COLUMN currency_pair.seq IS 'Версия строки в её потоке изменений (ledger или reference).';
COMMENT ON COLUMN currency_pair.deleted_at IS 'Момент мягкого удаления (tombstone); NULL — строка активна.';
COMMENT ON COLUMN currency_pair.updated_at IS 'Момент последнего изменения строки — только диагностика.';
COMMENT ON COLUMN currency_pair.updated_by IS 'Устройство, применившее последнее изменение этой строки.';
COMMENT ON COLUMN currency_pair.symbol IS 'Обозначение пары для отображения (например, "EUR/USD").';
COMMENT ON COLUMN currency_pair.base_currency_uuid IS
    'Базовая валюта пары — курс задаётся как "квота за 1 базовую единицу".';
COMMENT ON COLUMN currency_pair.quote_currency_uuid IS 'Котируемая валюта пары.';
COMMENT ON COLUMN currency_pair."precision" IS 'Число знаков после запятой в курсах этой пары.';
