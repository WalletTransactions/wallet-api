-- Иконка. Справочная таблица: ledger_id IS NULL — общая иконка, которая едет
-- всем; заполненный ledger_id — своя, добавленная пользователем из галереи.
--
-- Само изображение здесь не лежит, только ссылка на blob по SHA-256 — см. blob.sql.
--
-- name — text, хотя в клиентской схеме колонка объявлена INT
-- (WalletContract.IconEntry, android-wallet/schema/table/icon.sql). Зеркалить объявленный
-- тип здесь было бы ошибкой: SQLite типы не навязывает, и все 84 значения в
-- реальной базе — строки («unknown», «Flag Euro», «Babysitting», до 24 символов).
-- INT в клиентском DDL описывает намерение, а не данные.
--
-- ON DELETE RESTRICT на blob: пока хоть одна иконка ссылается на содержимое,
-- удалить его нельзя. Сборка мусора по blob — отдельная задача по расписанию,
-- а не побочный эффект удаления иконки.
CREATE TABLE icon (
    uuid           uuid PRIMARY KEY,
    ledger_id      uuid REFERENCES ledger (id) ON DELETE CASCADE,
    seq            bigint      NOT NULL,
    deleted_at     timestamptz,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    updated_by     uuid REFERENCES device (id) ON DELETE SET NULL,

    name           text     NOT NULL,
    content_sha256 bytea    NOT NULL REFERENCES blob (sha256) ON DELETE RESTRICT,
    -- Значений в Icon.IconType два: CATEGORY(0) и FLAG(1) — но CHECK IN (0,1)
    -- здесь стоять НЕ должен. В реальной базе 62 иконки из 84 имеют icon_type = 2,
    -- наследие более ранней схемы, и приложение их прекрасно показывает: его
    -- правило — «1 это флаг, всё остальное категория». Ограничение отвергло бы
    -- три четверти иконок при первой же загрузке существующего пользователя.
    icon_type      smallint NOT NULL CHECK (icon_type >= 0)
);

-- Две ленты изменений: общая по своему курсору, личная — по курсору леджера.
CREATE INDEX ix_icon_reference_sync ON icon (seq)            WHERE ledger_id IS NULL;
CREATE INDEX ix_icon_ledger_sync    ON icon (ledger_id, seq) WHERE ledger_id IS NOT NULL;

CREATE UNIQUE INDEX uq_icon_name_reference ON icon (name)            WHERE ledger_id IS NULL     AND deleted_at IS NULL;
CREATE UNIQUE INDEX uq_icon_name_ledger    ON icon (ledger_id, name) WHERE ledger_id IS NOT NULL AND deleted_at IS NULL;

CREATE INDEX ix_icon_blob ON icon (content_sha256);

CREATE TRIGGER trg_icon_updated_at BEFORE UPDATE ON icon
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE icon IS
    'Иконка — ссылка на содержимое в blob по SHA-256, с именем и типом. ledger_id IS NULL — общая иконка, которая едет всем; заполненный — своя, добавленная пользователем из галереи.';
COMMENT ON COLUMN icon.uuid IS 'Идентификатор иконки, общий для клиента и сервера (синхронизируемая сущность).';
COMMENT ON COLUMN icon.ledger_id IS 'NULL — общая (справочная) иконка; заполнено — своя иконка этого леджера.';
COMMENT ON COLUMN icon.seq IS 'Версия строки в её потоке изменений (ledger или reference, см. change_stream).';
COMMENT ON COLUMN icon.deleted_at IS 'Момент мягкого удаления (tombstone); NULL — строка активна.';
COMMENT ON COLUMN icon.updated_at IS
    'Момент последнего изменения строки — только диагностика, проставляет триггер set_updated_at; ни одно решение о конфликте по нему не принимается (см. seq).';
COMMENT ON COLUMN icon.updated_by IS 'Устройство, применившее последнее изменение этой строки.';
COMMENT ON COLUMN icon.name IS 'Название иконки, видимое в галерее выбора.';
COMMENT ON COLUMN icon.content_sha256 IS 'Ссылка на содержимое картинки в blob.sha256.';
COMMENT ON COLUMN icon.icon_type IS
    'Код типа иконки: у клиента различает 0=категория/1=флаг, но в реальных данных встречаются и другие значения (см. комментарий выше в этом файле) — приложение считает "1 это флаг, всё остальное категория".';
