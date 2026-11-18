-- Шаг маршрута пересчёта одной валюты в другую, когда прямой пары нет.
--
-- Маршрут from -> to леджера — это ЦЕПОЧКА строк с num = 1..N (N <= 3); каждая
-- строка называет пару (currency_pair_uuid) и направление шага (is_reverse:
-- false — от базовой валюты пары к котируемой, true — наоборот). Начало и конец
-- шага выводятся из пары и is_reverse. from/to одинаковы у всех шагов маршрута.
-- Цепочка валидна, если num идут подряд с 1, шаг 1 начинается в from, каждый
-- следующий — там, где закончился предыдущий, последний заканчивается в to
-- (проверяет rate_fallback, а не таблица: шаги могут приходить из
-- синка разными батчами). Невалидная цепочка курса не даёт.
--
-- Маршрут принадлежит леджеру (ledger_id NOT NULL, общих маршрутов нет) и
-- двунаправленный: BTC -> EUR -> RUB даёт и курс RUB -> BTC. Один живой маршрут
-- на неупорядоченную пару валют. Первичный ключ, как и везде, uuid.
CREATE TABLE currency_conversion (
    uuid               uuid PRIMARY KEY,
    ledger_id          uuid        NOT NULL REFERENCES ledger (id) ON DELETE CASCADE,
    seq                bigint      NOT NULL,
    deleted_at         timestamptz,
    updated_at         timestamptz NOT NULL DEFAULT now(),
    updated_by         uuid REFERENCES device (id) ON DELETE SET NULL,

    from_currency_uuid uuid     NOT NULL REFERENCES currency (uuid)      ON DELETE CASCADE,
    to_currency_uuid   uuid     NOT NULL REFERENCES currency (uuid)      ON DELETE CASCADE,
    num                smallint NOT NULL,
    currency_pair_uuid uuid     NOT NULL REFERENCES currency_pair (uuid) ON DELETE CASCADE,
    is_reverse         boolean  NOT NULL DEFAULT false,

    CONSTRAINT ck_currency_conversion_sides CHECK (from_currency_uuid <> to_currency_uuid),
    -- Верхняя граница ограничивает стоимость вьюхи курса.
    CONSTRAINT ck_currency_conversion_num   CHECK (num BETWEEN 1 AND 3)
);

CREATE INDEX ix_currency_conversion_ledger_sync ON currency_conversion (ledger_id, seq);

-- Шаг уникален по (леджер, from, to, num). Любой маршрут содержит num = 1,
-- поэтому второй индекс — по НЕупорядоченной паре валют — ловит и прямой, и
-- обратный дубль маршрута уже на первом шаге.
CREATE UNIQUE INDEX uq_currency_conversion_step
    ON currency_conversion (ledger_id, from_currency_uuid, to_currency_uuid, num)
 WHERE deleted_at IS NULL;

CREATE UNIQUE INDEX uq_currency_conversion_unordered
    ON currency_conversion (ledger_id,
                            LEAST(from_currency_uuid, to_currency_uuid),
                            GREATEST(from_currency_uuid, to_currency_uuid),
                            num)
 WHERE deleted_at IS NULL;

-- Таблица LedgerOnly: push резолвит конфликт как ON CONFLICT (ledger_id, uuid),
-- ему нужен именно такой уникальный ключ (у остальных таблиц леджера он первичный).
CREATE UNIQUE INDEX uq_currency_conversion_ledger_uuid
    ON currency_conversion (ledger_id, uuid);

-- Каскад мягкого удаления пары находит шаги по паре.
CREATE INDEX ix_currency_conversion_pair
    ON currency_conversion (currency_pair_uuid)
 WHERE deleted_at IS NULL;

CREATE TRIGGER trg_currency_conversion_updated_at BEFORE UPDATE ON currency_conversion
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE currency_conversion IS
    'Шаги маршрутов пересчёта валют леджера: маршрут from -> to — цепочка строк с num = 1..3, каждая называет пару и направление шага. Нужен там, где прямой пары нет.';
COMMENT ON COLUMN currency_conversion.uuid IS 'Идентификатор шага.';
COMMENT ON COLUMN currency_conversion.ledger_id IS 'Леджер-владелец маршрута; общих маршрутов нет.';
COMMENT ON COLUMN currency_conversion.seq IS 'Версия строки в потоке изменений леджера.';
COMMENT ON COLUMN currency_conversion.deleted_at IS 'Момент мягкого удаления (tombstone); NULL — строка активна.';
COMMENT ON COLUMN currency_conversion.updated_at IS 'Момент последнего изменения строки — только диагностика.';
COMMENT ON COLUMN currency_conversion.updated_by IS 'Устройство, применившее последнее изменение этой строки.';
COMMENT ON COLUMN currency_conversion.from_currency_uuid IS 'Валюта, из которой считается весь маршрут (одинакова у всех шагов маршрута).';
COMMENT ON COLUMN currency_conversion.to_currency_uuid IS 'Валюта, в которую считается весь маршрут (одинакова у всех шагов маршрута).';
COMMENT ON COLUMN currency_conversion.num IS 'Номер шага маршрута, 1..3.';
COMMENT ON COLUMN currency_conversion.currency_pair_uuid IS 'Пара, курс которой используется на этом шаге.';
COMMENT ON COLUMN currency_conversion.is_reverse IS
    'false — шаг идёт от базовой валюты пары к котируемой (курс rate), true — наоборот (курс 1/rate).';
