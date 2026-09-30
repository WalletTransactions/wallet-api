-- Курс пары на дату: quote за 1 base. Самая большая таблица в базе — история по
-- всем парам за все годы; её и раздаёт эндпоинт справочников.
--
-- Тип date, а не timestamp, в отличие от клиентской DATETIME. Курс — величина на
-- день, и в такой колонке невозможны две записи на одну дату с разным временем,
-- которые потом расходятся в «курсе на дату». Сужение намеренное; при переносе
-- из клиента время отбрасывается, значащей информации в нём нет.
--
-- rate > 0: нулевой или отрицательный курс не имеет смысла, а обратный курс
-- считается делением (1.0 / rate) — ноль здесь уронил бы пересчёт эквивалента.
--
-- Масштаб numeric(24,10) шире клиентского DECIMAL(12,5) и шире максимального
-- currency_pair.precision: сервер не должен терять точность источника, из которого
-- курс приехал, даже если пара отображается с пятью знаками.
CREATE TABLE currency_pair_rate (
    uuid               uuid PRIMARY KEY,
    ledger_id          uuid REFERENCES ledger (id) ON DELETE CASCADE,
    seq                bigint      NOT NULL,
    deleted_at         timestamptz,
    updated_at         timestamptz NOT NULL DEFAULT now(),
    updated_by         uuid REFERENCES device (id) ON DELETE SET NULL,

    currency_pair_uuid uuid          NOT NULL REFERENCES currency_pair (uuid) ON DELETE CASCADE,
    "date"             date          NOT NULL,
    rate               numeric(24,10) NOT NULL CHECK (rate > 0)
);

CREATE INDEX ix_currency_pair_rate_reference_sync ON currency_pair_rate (seq)            WHERE ledger_id IS NULL;
CREATE INDEX ix_currency_pair_rate_ledger_sync    ON currency_pair_rate (ledger_id, seq) WHERE ledger_id IS NOT NULL;

-- Естественный ключ клиентской схемы (currency_pair_id, date). Здесь он остаётся
-- уникальным, но первичный ключ — uuid: синхронизации нужна одна колонка-идентичность
-- на строку, см. ../README.md.
--
-- Уникальность разъезжается по области видимости, и это не формальность: курс,
-- введённый пользователем вручную, обязан сосуществовать с общим курсом той же
-- пары на ту же дату. Один индекс на обе области запретил бы ручной ввод ровно
-- там, где он и нужен — когда общий курс есть, но пользователь ему не верит.
-- Своя строка перекрывает общую для своего леджера, как и у currency.
CREATE UNIQUE INDEX uq_currency_pair_rate_reference
    ON currency_pair_rate (currency_pair_uuid, "date")
 WHERE ledger_id IS NULL     AND deleted_at IS NULL;

CREATE UNIQUE INDEX uq_currency_pair_rate_ledger
    ON currency_pair_rate (ledger_id, currency_pair_uuid, "date")
 WHERE ledger_id IS NOT NULL AND deleted_at IS NULL;

-- Курс на дату всегда ищется как max(date) не позже нужной — индекс по убыванию
-- даты внутри пары отдаёт его первой строкой.
CREATE INDEX ix_currency_pair_rate_lookup
    ON currency_pair_rate (currency_pair_uuid, "date" DESC) WHERE deleted_at IS NULL;

CREATE TRIGGER trg_currency_pair_rate_updated_at BEFORE UPDATE ON currency_pair_rate
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE currency_pair_rate IS
    'Курс пары на конкретную дату: квота за 1 базовую единицу. Самая большая по объёму таблица в базе — история курсов по всем парам за все годы.';
COMMENT ON COLUMN currency_pair_rate.uuid IS 'Идентификатор строки курса.';
COMMENT ON COLUMN currency_pair_rate.ledger_id IS
    'NULL — общий курс; заполнено — ручной курс этого леджера (сосуществует с общим на ту же дату, см. uq_currency_pair_rate_*).';
COMMENT ON COLUMN currency_pair_rate.seq IS 'Версия строки в её потоке изменений (ledger или reference).';
COMMENT ON COLUMN currency_pair_rate.deleted_at IS 'Момент мягкого удаления (tombstone); NULL — строка активна.';
COMMENT ON COLUMN currency_pair_rate.updated_at IS 'Момент последнего изменения строки — только диагностика.';
COMMENT ON COLUMN currency_pair_rate.updated_by IS 'Устройство, применившее последнее изменение этой строки.';
COMMENT ON COLUMN currency_pair_rate.currency_pair_uuid IS 'Пара, к которой относится этот курс.';
COMMENT ON COLUMN currency_pair_rate."date" IS
    'Дата, на которую действует курс — без времени: курс это величина на день, две записи на одну дату с разным временем здесь невозможны.';
COMMENT ON COLUMN currency_pair_rate.rate IS
    'Значение курса, строго положительное. Обратный курс (квота→база) считается делением 1.0/rate, отдельно не хранится.';
