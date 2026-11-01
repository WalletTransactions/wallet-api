-- Валюта. Справочная таблица: ledger_id IS NULL — общая валюта, которую сервер
-- раздаёт всем; заполненный ledger_id — валюта, которую пользователь добавил себе
-- сам (редкая, локальная, крипта).
--
-- precision взята в кавычки не из-за конфликта имён, а для страховки: PRECISION
-- в PostgreSQL — незарезервированное ключевое слово, но встречается внутри
-- DOUBLE PRECISION. Идентификатор при этом остаётся строчным, поэтому в запросах
-- колонку можно писать без кавычек.
--
-- precision задаёт число знаков в суммах этой валюты — и на клиенте определяет
-- и вывод (AdapterUtils.getFormat), и InputFilter в полях суммы. Верхняя граница
-- CHECK связана с масштабом operation.amount: знаков в сумме не может быть
-- больше, чем хранит колонка.
CREATE TABLE currency (
    uuid        uuid PRIMARY KEY,
    ledger_id   uuid REFERENCES ledger (id) ON DELETE CASCADE,
    seq         bigint      NOT NULL,
    deleted_at  timestamptz,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  uuid REFERENCES device (id) ON DELETE SET NULL,

    name        text     NOT NULL,
    iso_code    text     NOT NULL,
    icon_uuid   uuid     NOT NULL REFERENCES icon (uuid)
        ON DELETE NO ACTION DEFERRABLE INITIALLY IMMEDIATE,
    symbol      text     NOT NULL,
    "precision" smallint NOT NULL DEFAULT 2 CHECK ("precision" BETWEEN 0 AND 8),
    show_in_equivalent boolean NOT NULL DEFAULT true
);

CREATE INDEX ix_currency_reference_sync ON currency (seq)            WHERE ledger_id IS NULL;
CREATE INDEX ix_currency_ledger_sync    ON currency (ledger_id, seq) WHERE ledger_id IS NOT NULL;

-- Уникальность в клиентской схеме глобальная (name / iso_code UNIQUE), здесь она
-- разъезжается по области видимости: общий справочник и справочник леджера — разные
-- пространства имён. Схема при этом не запрещает пользователю завести локальный
-- USD рядом с общим — это проверяет приложение, а клиент при совпадении кода
-- предпочитает свою строку общей.
CREATE UNIQUE INDEX uq_currency_iso_reference  ON currency (iso_code)            WHERE ledger_id IS NULL     AND deleted_at IS NULL;
CREATE UNIQUE INDEX uq_currency_iso_ledger     ON currency (ledger_id, iso_code) WHERE ledger_id IS NOT NULL AND deleted_at IS NULL;
CREATE UNIQUE INDEX uq_currency_name_reference ON currency (name)                WHERE ledger_id IS NULL     AND deleted_at IS NULL;
CREATE UNIQUE INDEX uq_currency_name_ledger    ON currency (ledger_id, name)     WHERE ledger_id IS NOT NULL AND deleted_at IS NULL;

CREATE TRIGGER trg_currency_updated_at BEFORE UPDATE ON currency
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE currency IS
    'Валюта — справочная таблица. ledger_id IS NULL — общая валюта, которую сервер раздаёт всем; заполненный — валюта, которую пользователь добавил себе сам (редкая, локальная, крипта).';
COMMENT ON COLUMN currency.uuid IS 'Идентификатор валюты.';
COMMENT ON COLUMN currency.ledger_id IS 'NULL — общая валюта; заполнено — своя валюта этого леджера.';
COMMENT ON COLUMN currency.seq IS 'Версия строки в её потоке изменений (ledger или reference).';
COMMENT ON COLUMN currency.deleted_at IS 'Момент мягкого удаления (tombstone); NULL — строка активна.';
COMMENT ON COLUMN currency.updated_at IS 'Момент последнего изменения строки — только диагностика.';
COMMENT ON COLUMN currency.updated_by IS 'Устройство, применившее последнее изменение этой строки.';
COMMENT ON COLUMN currency.name IS 'Название валюты, видимое пользователю.';
COMMENT ON COLUMN currency.iso_code IS
    'Код валюты (например, "USD") — по нему уникальность внутри своей области видимости (общая/леджера, см. uq_currency_iso_*).';
COMMENT ON COLUMN currency.icon_uuid IS 'Иконка-флаг/символ этой валюты.';
COMMENT ON COLUMN currency.symbol IS 'Символ валюты для вывода сумм (например, "$").';
COMMENT ON COLUMN currency."precision" IS
    'Число знаков после запятой в суммах этой валюты — определяет округление и ограничивает верхнюю границу масштаба operation.amount для этой валюты.';
COMMENT ON COLUMN currency.show_in_equivalent IS
    'Показывать ли валюту в выборе валюты эквивалента (отчёты, пикеры). true по умолчанию; в push необязательна — строка без ключа не меняет прежнее значение.';
