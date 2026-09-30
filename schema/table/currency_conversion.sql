-- Ручное переопределение маршрута пересчёта одной валюты в другую, когда прямой
-- пары нет.
--
-- В клиенте таблица создаётся и остаётся пустой: ни один код-путь в неё не пишет,
-- а вьюха v_currency_conversion всегда резолвит курс через currency_pair
-- (android-wallet/schema/table/README.md). Здесь она заведена ради полноты зеркала —
-- если клиент когда-нибудь начнёт её заполнять, синку не придётся добавлять
-- сущность на ходу.
--
-- num — номер альтернативного маршрута между одной парой валют; вместе с
-- from/to образует естественный ключ клиентской схемы. Первичный ключ, как и
-- везде, uuid.
CREATE TABLE currency_conversion (
    uuid               uuid PRIMARY KEY,
    ledger_id          uuid REFERENCES ledger (id) ON DELETE CASCADE,
    seq                bigint      NOT NULL,
    deleted_at         timestamptz,
    updated_at         timestamptz NOT NULL DEFAULT now(),
    updated_by         uuid REFERENCES device (id) ON DELETE SET NULL,

    from_currency_uuid uuid     NOT NULL REFERENCES currency (uuid)      ON DELETE CASCADE,
    to_currency_uuid   uuid     NOT NULL REFERENCES currency (uuid)      ON DELETE CASCADE,
    num                smallint NOT NULL DEFAULT 0 CHECK (num >= 0),
    currency_pair_uuid uuid     NOT NULL REFERENCES currency_pair (uuid) ON DELETE CASCADE,
    is_reverse         boolean  NOT NULL DEFAULT false,

    CONSTRAINT ck_currency_conversion_sides CHECK (from_currency_uuid <> to_currency_uuid)
);

CREATE INDEX ix_currency_conversion_reference_sync ON currency_conversion (seq)            WHERE ledger_id IS NULL;
CREATE INDEX ix_currency_conversion_ledger_sync    ON currency_conversion (ledger_id, seq) WHERE ledger_id IS NOT NULL;

-- Как и у курсов, уникальность по области видимости: смысл таблицы — переопределение,
-- значит строка леджера обязана сосуществовать с общей для той же пары валют.
CREATE UNIQUE INDEX uq_currency_conversion_reference
    ON currency_conversion (from_currency_uuid, to_currency_uuid, num)
 WHERE ledger_id IS NULL     AND deleted_at IS NULL;

CREATE UNIQUE INDEX uq_currency_conversion_ledger
    ON currency_conversion (ledger_id, from_currency_uuid, to_currency_uuid, num)
 WHERE ledger_id IS NOT NULL AND deleted_at IS NULL;

CREATE TRIGGER trg_currency_conversion_updated_at BEFORE UPDATE ON currency_conversion
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE currency_conversion IS
    'Ручное переопределение маршрута пересчёта одной валюты в другую, когда прямой пары нет. В клиенте таблица всегда пустая — заведена ради полноты зеркала.';
COMMENT ON COLUMN currency_conversion.uuid IS 'Идентификатор строки переопределения.';
COMMENT ON COLUMN currency_conversion.ledger_id IS 'NULL — общее переопределение; заполнено — своё для этого леджера.';
COMMENT ON COLUMN currency_conversion.seq IS 'Версия строки в её потоке изменений (ledger или reference).';
COMMENT ON COLUMN currency_conversion.deleted_at IS 'Момент мягкого удаления (tombstone); NULL — строка активна.';
COMMENT ON COLUMN currency_conversion.updated_at IS 'Момент последнего изменения строки — только диагностика.';
COMMENT ON COLUMN currency_conversion.updated_by IS 'Устройство, применившее последнее изменение этой строки.';
COMMENT ON COLUMN currency_conversion.from_currency_uuid IS 'Исходная валюта пересчёта.';
COMMENT ON COLUMN currency_conversion.to_currency_uuid IS 'Целевая валюта пересчёта.';
COMMENT ON COLUMN currency_conversion.num IS
    'Номер альтернативного маршрута между этой парой валют — на случай нескольких путей пересчёта между одними и теми же валютами.';
COMMENT ON COLUMN currency_conversion.currency_pair_uuid IS 'Пара, курс которой использовать для этого маршрута.';
COMMENT ON COLUMN currency_conversion.is_reverse IS
    'true — использовать обратный курс пары (1.0/rate), false — прямой.';
