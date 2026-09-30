-- Единая таблица кошельков и категорий, как в клиенте: строка становится
-- кошельком, если для того же uuid есть строка в account_operating.
--
-- ledger_id NOT NULL — это личные данные пользователя, общих счётов не бывает.
--
-- Первичный ключ составной, (ledger_id, uuid), и это делает две работы сразу.
--
-- Во-первых, на него ссылаются составные внешние ключи из operation: ссылка
-- «операция → счёт» проверяется вместе с арендатором, поэтому сослаться на счёт
-- чужого леджера невозможно даже при испорченном или враждебном клиенте. Без
-- составного ключа это была бы проверка в коде, которую однажды забудут.
--
-- Во-вторых, он оставляет открытой дверь к секционированию по ledger_id:
-- PostgreSQL требует, чтобы ключ секционирования входил в каждое уникальное
-- ограничение, и одиночный uuid в первичном ключе закрыл бы эту возможность
-- навсегда. Стоило это ничего — все входящие внешние ключи и так составные.
-- Подробнее о том, когда секционирование окупится, — в ../README.md.
--
-- Плата: uuid уникален в пределах леджера, а не глобально. Протоколу этого
-- достаточно — строка всегда адресуется вместе со своим леджером.
--
-- is_archived — boolean вместо клиентского INT DEFAULT 0. Признак только для
-- интерфейса: в расчётах архивный счёт участвует наравне с остальными, иначе
-- архивация молча меняла бы итоги за прошлые периоды (android-wallet/schema/table/README.md).
--
-- system_kind — явный признак системной категории (Transfer, Transfer
-- commission) вместо распознавания по name (обсуждение 2026-09-09). Раньше
-- признака в схеме не было вообще — ни здесь, ни в клиенте — и обе стороны
-- сравнивали account.name со строками "Transfer"/"Transfer commission"
-- (AccountItem.isSystemName). Проблема не только в хрупкости: имя —
-- единственное уникальное поле счёта (uq_account_name), пользователь мог
-- переименовать системную категорию и тем самым молча снять с неё защиту от
-- удаления и выбить её из логики разновалютных переводов.
--
-- Значения совпадают с AccountItem.SystemKind на клиенте: 0 = обычный
-- счёт/категория (по умолчанию), 1 = Transfer, 2 = Transfer commission.
-- smallint, а не boolean — множество системных ролей уже сейчас не бинарное
-- (две разные роли), и это тот же приём, что icon.icon_type.
--
-- Сравнение по имени остаётся ЛЕГИТИМНЫМ ровно в одном месте — миграции,
-- бэкфиллящей это поле на уже существующих строках (см. её файл): это
-- единственный момент превращения старого неявного состояния в новое явное,
-- дальше по коду имя в определении системности не участвует нигде.
--
-- kind — явный признак «кошелёк или категория» (обсуждение 2026-09-09), тем
-- же приёмом, что system_kind чуть выше: раньше это не хранилось нигде, а
-- вычислялось join'ом на account_operating (есть строка — кошелёк, нет —
-- категория, см. account_operating.sql). Сам join никуда не делся —
-- account_operating остаётся источником валюты кошелька и отдельной
-- синхронизируемой сущностью, kind — это её явный, дешёвый в проверке
-- слепок на самой строке account. Проставляется РОВНО ОДИН РАЗ, в момент
-- создания строки (одновременно с решением, заводить ли для неё
-- account_operating), и дальше не меняется — конвертации категории в
-- кошелёк и обратно в коде нет ни на клиенте, ни на сервере.
CREATE TABLE account (
    uuid        uuid        NOT NULL,
    ledger_id   uuid        NOT NULL REFERENCES ledger (id) ON DELETE CASCADE,
    seq         bigint      NOT NULL,
    deleted_at  timestamptz,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  uuid REFERENCES device (id) ON DELETE SET NULL,

    name        text     NOT NULL,
    comment     text     NOT NULL DEFAULT '',
    icon_uuid   uuid     NOT NULL REFERENCES icon (uuid) ON DELETE RESTRICT,
    is_archived boolean  NOT NULL DEFAULT false,
    -- IN (0, 1, 2), а не просто >= 0, в отличие от icon.icon_type: там
    -- ограничение снято из-за унаследованных мусорных значений в реальных
    -- данных (см. icon.sql), здесь колонка новая и без такого прошлого —
    -- ничто не мешает сразу закрыть набор значений.
    system_kind smallint NOT NULL DEFAULT 0 CHECK (system_kind IN (0, 1, 2)),
    kind        smallint NOT NULL DEFAULT 0 CHECK (kind IN (0, 1)),

    CONSTRAINT pk_account PRIMARY KEY (ledger_id, uuid)
);

CREATE INDEX ix_account_sync ON account (ledger_id, seq);

-- Имя уникально среди живых счётов леджера. Удалённые из индекса выпадают:
-- иначе имя удалённой категории навсегда занято её tombstone'ом.
--
-- Это же место, где ловится главный конфликт офлайновой работы: два устройства
-- независимо создали «Продукты». Второй push получает нарушение этого индекса,
-- сервер отвечает 409 с uuid выжившей строки, клиент переклеивает свои операции
-- на него и снимает локальный дубль.
CREATE UNIQUE INDEX uq_account_name ON account (ledger_id, name) WHERE deleted_at IS NULL;

CREATE INDEX ix_account_icon ON account (icon_uuid);

CREATE TRIGGER trg_account_updated_at BEFORE UPDATE ON account
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE account IS
    'Единая таблица счетов и категорий: строка становится кошельком, если для того же uuid есть строка в account_operating, иначе это категория.';
COMMENT ON COLUMN account.uuid IS 'Идентификатор счёта/категории, общий с клиентом.';
COMMENT ON COLUMN account.ledger_id IS 'Леджер-владелец — личные данные пользователя, общих счетов не бывает (NOT NULL).';
COMMENT ON COLUMN account.seq IS 'Версия строки в потоке изменений леджера.';
COMMENT ON COLUMN account.deleted_at IS 'Момент мягкого удаления (tombstone); NULL — строка активна.';
COMMENT ON COLUMN account.updated_at IS 'Момент последнего изменения строки — только диагностика.';
COMMENT ON COLUMN account.updated_by IS 'Устройство, применившее последнее изменение этой строки.';
COMMENT ON COLUMN account.name IS
    'Название счёта/категории, видимое пользователю — уникально среди живых (deleted_at IS NULL) строк леджера, см. uq_account_name.';
COMMENT ON COLUMN account.comment IS 'Свободный комментарий пользователя к счёту/категории.';
COMMENT ON COLUMN account.icon_uuid IS 'Иконка счёта/категории.';
COMMENT ON COLUMN account.is_archived IS
    'Признак только для интерфейса — архивный счёт участвует в расчётах наравне с остальными, иначе архивация молча меняла бы итоги за прошлые периоды.';
COMMENT ON COLUMN account.system_kind IS
    'Явный признак системной категории вместо распознавания по name: 0 = обычная, 1 = Transfer, 2 = Transfer commission (см. AccountItem.SystemKind на клиенте).';
COMMENT ON COLUMN account.kind IS
    'Явный признак «кошелёк или категория»: 0 = категория, 1 = кошелёк (см. AccountItem.Kind на клиенте). Дублирует наличие строки в account_operating, проставляется один раз при создании и дальше не меняется.';
