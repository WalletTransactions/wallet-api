-- Домен леджера/синка (servers/TODO_mobile_sync.md, Фаза 2) — перенос
-- schema/server/table|view|function/*.sql в реальную миграцию wallet-базы,
-- порядок зависимостей как в schema/server/apply.sql, ТРИ отличия от него
-- (адаптация под уже реализованную Фазу 1, а не под изначальный черновик
-- схемы):
--
-- 1. Таблицы auth_nonce НЕТ ВООБЩЕ. В schema/server она предполагалась
--    здесь, но по факту реализации (google-auth, см. его README "Мобильный
--    вход") nonce живёт в памяти процесса auth-сервиса
--    (AppState::issued_nonces) — тем же приёмом, что уже там есть у pending/
--    pending_signups. Заводить таблицу и миграцию ради секунд жизни было бы
--    тяжелее, чем того требует задача.
--
-- 2. app_user СИЛЬНО проще: одна колонка id, БЕЗ отдельного google_sub.
--    schema/server проектировала app_user как ТРЕТИЙ слой идентичности
--    (Google sub -> google-auth UserRecord.id -> ещё один свой uuid здесь).
--    По факту в auth::issue_access_token claim "sub" access-JWT — это уже
--    внутренний UserRecord.id google-auth (см. auth.cpp), то есть ровно тот
--    непрозрачный идентификатор, которым нужно адресовать пользователя и
--    здесь. wallet-api не заводит СВОЙ, ЕЩЁ один id поверх него — ровно тот
--    же приём, что уже использует демо-таблица wallets.owner_id ("просто sub
--    из уже проверенного access-токена", см. README wallet-api). app_user.id
--    здесь поэтому не DEFAULT gen_random_uuid() — значение приходит извне,
--    из claim'а токена, а не порождается этой базой.
--
-- 3. device СИЛЬНО проще: без refresh_hash/refresh_family/refresh_expires_at/
--    refresh_prev_hash/refresh_prev_until/revoked_at. schema/server
--    проектировала device как точку выпуска И ротации refresh-токенов
--    силами wallet-api. По факту вся выдача/ротация/отзыв токенов
--    централизована в google-auth (Redis, см. его README "Детали
--    устройства") — wallet-api токены не выпускает и не ротирует вообще,
--    только проверяет уже готовый JWT по JWKS. Здесь device — не точка
--    авторизации, а просто книга устройств для курсоров синка и диагностики
--    ("какое устройство последним писало", last_ack_seq и т.п.). id этой
--    строки — claim "device_id" ИЗ ТОГО ЖЕ JWT (google-auth кладёт его
--    только когда вход был мобильным, см. его README) — тоже не
--    gen_random_uuid(), а внешнее значение.
--
-- Всё остальное — table/*.sql, view/*.sql, function/*.sql,
-- role/wallet_reader.sql — перенесено дословно, с комментариями оригинала
-- (сокращены до сути, полные версии — в schema/server/, которая остаётся
-- читаемым зеркалом, см. servers/README.md и корневой
-- ddl-mirror-must-follow-schema-changes).

-- Порядок первых трёх строк вынужденный, как и в apply.sql: set_updated_at
-- (plpgsql, тело не разбирается при CREATE) — до таблиц, на которые
-- ссылаются её триггеры; next_seq (SQL, тело разбирается сразу) — после
-- change_stream, на которую ссылается.
CREATE FUNCTION set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

-- Счётчики версий строк. 'ledger' — по одному на леджер, 'reference' — один
-- на всю базу для общих справочников (id зафиксирован, на него ссылается
-- весь код, работающий со справочниками).
CREATE TABLE change_stream (
    id   uuid PRIMARY KEY,
    kind text   NOT NULL CHECK (kind IN ('ledger', 'reference')),
    seq  bigint NOT NULL DEFAULT 0 CHECK (seq >= 0)
);

INSERT INTO change_stream (id, kind)
VALUES ('00000000-0000-0000-0000-000000000001', 'reference');

-- Выдача очередного номера версии — один раз на батч записи, в той же
-- транзакции. UPDATE берёт блокировку строки потока, поэтому порядок seq
-- совпадает с порядком коммитов (в отличие от SEQUENCE, где номер выдаётся
-- вне транзакции и более поздний коммит может обогнать более ранний).
CREATE FUNCTION next_seq(p_stream uuid) RETURNS bigint
    LANGUAGE sql
AS $$
    UPDATE change_stream
       SET seq = seq + 1
     WHERE id = p_stream
    RETURNING seq;
$$;

-- ── Владение данными ────────────────────────────────────────────────────

-- Единица владения и единица синхронизации: всё, что видит пользователь,
-- принадлежит ровно одному леджеру. id совпадает с change_stream.id того же
-- потока — создание леджера всегда две вставки в одной транзакции, сначала
-- в change_stream.
CREATE TABLE ledger (
    id         uuid PRIMARY KEY REFERENCES change_stream (id) ON DELETE RESTRICT,
    name       text        NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- См. п. 2 в шапке файла — id это claim "sub" уже проверенного access-JWT
-- (внутренний UserRecord.id google-auth), не сгенерированное здесь значение.
CREATE TABLE app_user (
    id          uuid PRIMARY KEY,
    email       text,        -- кэш claim "email" из JWT, только для показа/отчётов
    created_at  timestamptz NOT NULL DEFAULT now(),
    disabled_at timestamptz  -- зарезервировано; сейчас ничего его не выставляет
);

-- Кто имеет доступ к леджеру и с какими правами. Заведена с первого дня,
-- даже если пользователь один (MVP — план, п. 1.3): общий кошелёк потом
-- требует только выдачи второй строки, а не переписывания всех запросов.
CREATE TABLE ledger_member (
    ledger_id uuid        NOT NULL REFERENCES ledger (id)   ON DELETE CASCADE,
    user_id   uuid        NOT NULL REFERENCES app_user (id) ON DELETE CASCADE,
    role      text        NOT NULL CHECK (role IN ('owner', 'member', 'reader')),
    joined_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT pk_ledger_member PRIMARY KEY (ledger_id, user_id)
);

-- Владелец ровно один — "два владельца" не имеет разумной семантики при
-- конфликте; передача владения — UPDATE двух строк в одной транзакции.
CREATE UNIQUE INDEX uq_ledger_member_owner ON ledger_member (ledger_id) WHERE role = 'owner';
CREATE INDEX ix_ledger_member_user ON ledger_member (user_id);

-- См. п. 3 в шапке файла — книга устройств для курсоров синка/диагностики,
-- не точка выпуска токенов (это делает google-auth). id — claim "device_id"
-- из JWT.
CREATE TABLE device (
    id           uuid PRIMARY KEY,
    user_id      uuid NOT NULL REFERENCES app_user (id) ON DELETE CASCADE,
    ledger_id    uuid NOT NULL REFERENCES ledger (id)   ON DELETE CASCADE,
    platform     text NOT NULL DEFAULT '' CHECK (platform IN ('android', 'ios', 'web', 'other', '')),
    name         text NOT NULL DEFAULT '', -- только для показа человеку, см. README google-auth "Детали устройства"

    last_seen_at timestamptz,
    last_ack_seq bigint,
    created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ix_device_user   ON device (user_id);
CREATE INDEX ix_device_ledger ON device (ledger_id);

-- Идемпотентность отправки: офлайновый клиент неизбежно повторяет батч,
-- если ответ потерялся. Без этой таблицы повтор выглядел бы как чужая
-- правка (seq строки уже больше присланного) и вернул бы 409 на
-- собственную запись пользователя. Ключ — на батч целиком, не на строку:
-- батч и так одна транзакция.
CREATE TABLE sync_push_batch (
    batch_id   uuid PRIMARY KEY,
    device_id  uuid        NOT NULL REFERENCES device (id) ON DELETE CASCADE,
    ledger_id  uuid        NOT NULL REFERENCES ledger (id) ON DELETE CASCADE,
    seq        bigint      NOT NULL,
    response   jsonb       NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ix_sync_push_batch_created ON sync_push_batch (created_at);
CREATE INDEX ix_sync_push_batch_device  ON sync_push_batch (device_id, created_at DESC);

-- ── Содержимое и справочники ────────────────────────────────────────────

-- Двоичное содержимое, адресуемое по SHA-256 (иконки). Строки ничьи —
-- ledger_id здесь нет, содержимое общее; право прочитать конкретный blob
-- проверяет приложение (по наличию видимой леджеру icon с этим content_sha256).
CREATE TABLE blob (
    sha256     bytea PRIMARY KEY CHECK (octet_length(sha256) = 32),
    bytes      bytea       NOT NULL CHECK (octet_length(bytes) BETWEEN 1 AND 1048576),
    created_at timestamptz NOT NULL DEFAULT now()
);

-- ledger_id IS NULL — общая иконка; заполненный — своя, добавленная
-- пользователем. icon_type без CHECK IN (0,1) намеренно — см.
-- schema/server/table/README.md, "icon": в реальной клиентской базе 62 из 84
-- иконок имеют значение 2.
CREATE TABLE icon (
    uuid           uuid PRIMARY KEY,
    ledger_id      uuid REFERENCES ledger (id) ON DELETE CASCADE,
    seq            bigint      NOT NULL,
    deleted_at     timestamptz,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    updated_by     uuid REFERENCES device (id) ON DELETE SET NULL,

    name           text     NOT NULL,
    content_sha256 bytea    NOT NULL REFERENCES blob (sha256) ON DELETE RESTRICT,
    icon_type      smallint NOT NULL CHECK (icon_type >= 0)
);

CREATE INDEX ix_icon_reference_sync ON icon (seq)            WHERE ledger_id IS NULL;
CREATE INDEX ix_icon_ledger_sync    ON icon (ledger_id, seq) WHERE ledger_id IS NOT NULL;

CREATE UNIQUE INDEX uq_icon_name_reference ON icon (name)            WHERE ledger_id IS NULL     AND deleted_at IS NULL;
CREATE UNIQUE INDEX uq_icon_name_ledger    ON icon (ledger_id, name) WHERE ledger_id IS NOT NULL AND deleted_at IS NULL;

CREATE INDEX ix_icon_blob ON icon (content_sha256);

CREATE TRIGGER trg_icon_updated_at BEFORE UPDATE ON icon
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE currency (
    uuid        uuid PRIMARY KEY,
    ledger_id   uuid REFERENCES ledger (id) ON DELETE CASCADE,
    seq         bigint      NOT NULL,
    deleted_at  timestamptz,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  uuid REFERENCES device (id) ON DELETE SET NULL,

    name        text     NOT NULL,
    iso_code    text     NOT NULL,
    icon_uuid   uuid     NOT NULL REFERENCES icon (uuid) ON DELETE RESTRICT,
    symbol      text     NOT NULL,
    "precision" smallint NOT NULL DEFAULT 2 CHECK ("precision" BETWEEN 0 AND 8)
);

CREATE INDEX ix_currency_reference_sync ON currency (seq)            WHERE ledger_id IS NULL;
CREATE INDEX ix_currency_ledger_sync    ON currency (ledger_id, seq) WHERE ledger_id IS NOT NULL;

CREATE UNIQUE INDEX uq_currency_iso_reference  ON currency (iso_code)            WHERE ledger_id IS NULL     AND deleted_at IS NULL;
CREATE UNIQUE INDEX uq_currency_iso_ledger     ON currency (ledger_id, iso_code) WHERE ledger_id IS NOT NULL AND deleted_at IS NULL;
CREATE UNIQUE INDEX uq_currency_name_reference ON currency (name)                WHERE ledger_id IS NULL     AND deleted_at IS NULL;
CREATE UNIQUE INDEX uq_currency_name_ledger    ON currency (ledger_id, name)     WHERE ledger_id IS NOT NULL AND deleted_at IS NULL;

CREATE TRIGGER trg_currency_updated_at BEFORE UPDATE ON currency
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- FK на currency простые, без ledger_id: валюта пары может быть и общей, и
-- локальной — составной ключ арендатора здесь не построить, проверяет приложение.
CREATE TABLE currency_pair (
    uuid                 uuid PRIMARY KEY,
    ledger_id            uuid REFERENCES ledger (id) ON DELETE CASCADE,
    seq                  bigint      NOT NULL,
    deleted_at           timestamptz,
    updated_at           timestamptz NOT NULL DEFAULT now(),
    updated_by           uuid REFERENCES device (id) ON DELETE SET NULL,

    symbol               text     NOT NULL,
    base_currency_uuid   uuid     NOT NULL REFERENCES currency (uuid) ON DELETE RESTRICT,
    quote_currency_uuid  uuid     NOT NULL REFERENCES currency (uuid) ON DELETE RESTRICT,
    "precision"          smallint NOT NULL DEFAULT 5 CHECK ("precision" BETWEEN 0 AND 10),

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

-- Курс пары на дату: quote за 1 base. "date", а не timestamp — курс это
-- величина на день. rate > 0 — обратный курс считается делением (1.0/rate).
CREATE TABLE currency_pair_rate (
    uuid               uuid PRIMARY KEY,
    ledger_id          uuid REFERENCES ledger (id) ON DELETE CASCADE,
    seq                bigint      NOT NULL,
    deleted_at         timestamptz,
    updated_at         timestamptz NOT NULL DEFAULT now(),
    updated_by         uuid REFERENCES device (id) ON DELETE SET NULL,

    currency_pair_uuid uuid           NOT NULL REFERENCES currency_pair (uuid) ON DELETE CASCADE,
    "date"             date           NOT NULL,
    rate               numeric(24,10) NOT NULL CHECK (rate > 0)
);

CREATE INDEX ix_currency_pair_rate_reference_sync ON currency_pair_rate (seq)            WHERE ledger_id IS NULL;
CREATE INDEX ix_currency_pair_rate_ledger_sync    ON currency_pair_rate (ledger_id, seq) WHERE ledger_id IS NOT NULL;

-- Уникальность разъезжается по области видимости не формально: ручной курс
-- пользователя обязан сосуществовать с общим курсом той же пары на ту же дату.
CREATE UNIQUE INDEX uq_currency_pair_rate_reference
    ON currency_pair_rate (currency_pair_uuid, "date")
 WHERE ledger_id IS NULL     AND deleted_at IS NULL;

CREATE UNIQUE INDEX uq_currency_pair_rate_ledger
    ON currency_pair_rate (ledger_id, currency_pair_uuid, "date")
 WHERE ledger_id IS NOT NULL AND deleted_at IS NULL;

CREATE INDEX ix_currency_pair_rate_lookup
    ON currency_pair_rate (currency_pair_uuid, "date" DESC) WHERE deleted_at IS NULL;

CREATE TRIGGER trg_currency_pair_rate_updated_at BEFORE UPDATE ON currency_pair_rate
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Ручное переопределение маршрута пересчёта. В клиенте таблица всегда
-- пустая (ни один код-путь в неё не пишет) — заведена ради полноты зеркала.
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

CREATE UNIQUE INDEX uq_currency_conversion_reference
    ON currency_conversion (from_currency_uuid, to_currency_uuid, num)
 WHERE ledger_id IS NULL     AND deleted_at IS NULL;

CREATE UNIQUE INDEX uq_currency_conversion_ledger
    ON currency_conversion (ledger_id, from_currency_uuid, to_currency_uuid, num)
 WHERE ledger_id IS NOT NULL AND deleted_at IS NULL;

CREATE TRIGGER trg_currency_conversion_updated_at BEFORE UPDATE ON currency_conversion
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── Данные леджера ───────────────────────────────────────────────────────

-- Единая таблица кошельков и категорий: строка становится кошельком, если
-- для того же uuid есть строка в account_operating. Составной первичный
-- ключ (ledger_id, uuid) — на него ссылаются составные FK из operation
-- (сослаться на счёт чужого леджера невозможно даже при враждебном клиенте)
-- и он же оставляет дверь к будущему секционированию по ledger_id.
CREATE TABLE account (
    uuid        uuid        NOT NULL,
    ledger_id   uuid        NOT NULL REFERENCES ledger (id) ON DELETE CASCADE,
    seq         bigint      NOT NULL,
    deleted_at  timestamptz,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  uuid REFERENCES device (id) ON DELETE SET NULL,

    name        text    NOT NULL,
    comment     text    NOT NULL DEFAULT '',
    icon_uuid   uuid    NOT NULL REFERENCES icon (uuid) ON DELETE RESTRICT,
    is_archived boolean NOT NULL DEFAULT false,

    CONSTRAINT pk_account PRIMARY KEY (ledger_id, uuid)
);

CREATE INDEX ix_account_sync ON account (ledger_id, seq);

-- Главный конфликт офлайновой работы ловится этим индексом: два устройства
-- независимо создали "Продукты" — второй push нарушает его, сервер отвечает
-- 409 с uuid выжившей строки (см. README schema/server, "account").
CREATE UNIQUE INDEX uq_account_name ON account (ledger_id, name) WHERE deleted_at IS NULL;

CREATE INDEX ix_account_icon ON account (icon_uuid);

CREATE TRIGGER trg_account_updated_at BEFORE UPDATE ON account
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Расширение account для кошельков: строка есть — счёт операционный, есть
-- валюта; строки нет — категория. uuid всегда равен account.uuid.
CREATE TABLE account_operating (
    uuid          uuid        NOT NULL,
    ledger_id     uuid        NOT NULL,
    seq           bigint      NOT NULL,
    deleted_at    timestamptz,
    updated_at    timestamptz NOT NULL DEFAULT now(),
    updated_by    uuid REFERENCES device (id) ON DELETE SET NULL,

    currency_uuid uuid NOT NULL REFERENCES currency (uuid) ON DELETE RESTRICT,

    CONSTRAINT pk_account_operating PRIMARY KEY (ledger_id, uuid),
    CONSTRAINT fk_account_operating_account
        FOREIGN KEY (ledger_id, uuid) REFERENCES account (ledger_id, uuid) ON DELETE CASCADE
);

CREATE INDEX ix_account_operating_sync     ON account_operating (ledger_id, seq);
CREATE INDEX ix_account_operating_currency ON account_operating (currency_uuid);

CREATE TRIGGER trg_account_operating_updated_at BEFORE UPDATE ON account_operating
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Единственная таблица транзакций. "date" — timestamp БЕЗ часового пояса
-- намеренно (бизнес-дата в локальном времени клиента, см. README
-- schema/server, "Даты"). amount NOT NULL CHECK >= 0 — направление задаёт
-- пара acc_fr/acc_to, не знак.
CREATE TABLE operation (
    uuid        uuid        NOT NULL,
    ledger_id   uuid        NOT NULL REFERENCES ledger (id) ON DELETE CASCADE,
    seq         bigint      NOT NULL,
    deleted_at  timestamptz,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  uuid REFERENCES device (id) ON DELETE SET NULL,

    "date"      timestamp     NOT NULL,
    acc_fr_uuid uuid          NOT NULL,
    acc_to_uuid uuid          NOT NULL,
    amount      numeric(20,8) NOT NULL CHECK (amount >= 0),
    comment     text          NOT NULL DEFAULT '',

    CONSTRAINT pk_operation PRIMARY KEY (ledger_id, uuid),
    CONSTRAINT fk_operation_acc_fr
        FOREIGN KEY (ledger_id, acc_fr_uuid) REFERENCES account (ledger_id, uuid),
    CONSTRAINT fk_operation_acc_to
        FOREIGN KEY (ledger_id, acc_to_uuid) REFERENCES account (ledger_id, uuid),
    CONSTRAINT ck_operation_sides CHECK (acc_fr_uuid <> acc_to_uuid)
);

CREATE INDEX ix_operation_sync ON operation (ledger_id, seq);
CREATE INDEX ix_operation_date ON operation (ledger_id, "date" DESC) WHERE deleted_at IS NULL;
CREATE INDEX ix_operation_acc_fr ON operation (ledger_id, acc_fr_uuid, "date") WHERE deleted_at IS NULL;
CREATE INDEX ix_operation_acc_to ON operation (ledger_id, acc_to_uuid, "date") WHERE deleted_at IS NULL;

CREATE TRIGGER trg_operation_updated_at BEFORE UPDATE ON operation
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Связь проводок одной пользовательской операции, хранимых несколькими
-- строками (разновалютный перевод, комиссия). main_uuid — всегда проводка
-- списания с источника; push применяется одной транзакцией именно ради
-- этой таблицы — иначе вторая нога может доехать отдельно от первой.
CREATE TABLE operation_link (
    uuid       uuid        NOT NULL,
    ledger_id  uuid        NOT NULL REFERENCES ledger (id) ON DELETE CASCADE,
    seq        bigint      NOT NULL,
    deleted_at timestamptz,
    updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by uuid REFERENCES device (id) ON DELETE SET NULL,

    main_uuid  uuid NOT NULL,
    link_uuid  uuid NOT NULL,

    CONSTRAINT pk_operation_link PRIMARY KEY (ledger_id, uuid),
    CONSTRAINT fk_operation_link_main
        FOREIGN KEY (ledger_id, main_uuid) REFERENCES operation (ledger_id, uuid) ON DELETE CASCADE,
    CONSTRAINT fk_operation_link_link
        FOREIGN KEY (ledger_id, link_uuid) REFERENCES operation (ledger_id, uuid) ON DELETE CASCADE,
    CONSTRAINT ck_operation_link_distinct CHECK (main_uuid <> link_uuid)
);

CREATE INDEX ix_operation_link_sync ON operation_link (ledger_id, seq);

CREATE UNIQUE INDEX uq_operation_link_natural
    ON operation_link (ledger_id, main_uuid, link_uuid) WHERE deleted_at IS NULL;

CREATE INDEX ix_operation_link_link ON operation_link (ledger_id, link_uuid);

CREATE TRIGGER trg_operation_link_updated_at BEFORE UPDATE ON operation_link
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── Представления (для отчётов; клиент считает балансы сам) ────────────

CREATE VIEW v_account_operating AS
SELECT a.uuid, a.ledger_id, a.name, a.comment, a.icon_uuid, a.is_archived, ao.currency_uuid
  FROM account a
  JOIN account_operating ao
    ON ao.ledger_id = a.ledger_id
   AND ao.uuid      = a.uuid
 WHERE a.deleted_at IS NULL
   AND ao.deleted_at IS NULL;

-- Обратный фильтр: счета БЕЗ строки в account_operating — категории.
CREATE VIEW v_account_expanse AS
SELECT a.ledger_id, a.uuid, a.name, a.comment, a.icon_uuid, a.is_archived
  FROM account a
  LEFT JOIN account_operating ao
         ON ao.ledger_id = a.ledger_id
        AND ao.uuid      = a.uuid
        AND ao.deleted_at IS NULL
 WHERE a.deleted_at IS NULL
   AND ao.uuid IS NULL;

-- Каждая пара развёрнута в оба направления, поверх — переопределение из
-- currency_conversion (в клиенте всегда пустая, см. таблицу выше).
CREATE VIEW v_currency_conversion AS
SELECT COALESCE(cc.ledger_id, fk.ledger_id)                   AS ledger_id,
       fc.uuid                                                AS from_currency_uuid,
       fc.name                                                AS from_currency_name,
       fc.iso_code                                            AS from_currency_iso,
       tc.uuid                                                AS to_currency_uuid,
       tc.name                                                AS to_currency_name,
       tc.iso_code                                            AS to_currency_iso,
       COALESCE(cc.currency_pair_uuid, fk.currency_pair_uuid) AS currency_pair_uuid,
       COALESCE(cc.num, fk.num)                               AS num,
       COALESCE(cc.is_reverse, fk.is_reverse)                 AS is_reverse
  FROM (
        SELECT cp.uuid                AS currency_pair_uuid,
               cp.ledger_id,
               cp.base_currency_uuid  AS from_currency_uuid,
               cp.quote_currency_uuid AS to_currency_uuid,
               0::smallint            AS num,
               false                  AS is_reverse
          FROM currency_pair cp
         WHERE cp.deleted_at IS NULL
        UNION ALL
        SELECT cp.uuid,
               cp.ledger_id,
               cp.quote_currency_uuid,
               cp.base_currency_uuid,
               0::smallint,
               true
          FROM currency_pair cp
         WHERE cp.deleted_at IS NULL
       ) fk
  LEFT JOIN currency_conversion cc
         ON cc.from_currency_uuid = fk.from_currency_uuid
        AND cc.to_currency_uuid   = fk.to_currency_uuid
        AND cc.ledger_id IS NOT DISTINCT FROM fk.ledger_id
        AND cc.deleted_at IS NULL
  JOIN currency fc
    ON fc.uuid = COALESCE(cc.from_currency_uuid, fk.from_currency_uuid)
   AND fc.deleted_at IS NULL
  JOIN currency tc
    ON tc.uuid = COALESCE(cc.to_currency_uuid, fk.to_currency_uuid)
   AND tc.deleted_at IS NULL;

-- Курс на дату по каждому направлению + тождественный курс валюты в саму
-- себя (UNION с датой 2000-01-01) — пересчёт "в себя" всегда находит курс 1.
CREATE VIEW v_currency_conversion_rate AS
SELECT COALESCE(r.ledger_id, cc.ledger_id) AS ledger_id,
       cc.from_currency_uuid,
       cc.from_currency_name,
       cc.from_currency_iso,
       cc.to_currency_uuid,
       cc.to_currency_name,
       cc.to_currency_iso,
       r."date",
       CASE WHEN cc.is_reverse THEN 1.0 / r.rate ELSE r.rate END AS rate
  FROM v_currency_conversion cc
  JOIN currency_pair_rate r
    ON r.currency_pair_uuid = cc.currency_pair_uuid
   AND r.deleted_at IS NULL
   AND (cc.ledger_id IS NULL OR r.ledger_id IS NULL OR r.ledger_id = cc.ledger_id)

UNION ALL

SELECT c.ledger_id,
       c.uuid, c.name, c.iso_code,
       c.uuid, c.name, c.iso_code,
       DATE '2000-01-01',
       1::numeric
  FROM currency c
 WHERE c.deleted_at IS NULL;

-- Операция с раскрытыми именами счетов/валютой. Счета НЕ фильтруются по
-- deleted_at — на сервере удаление мягкое, живая операция может ссылаться
-- на снятый счёт, и отсечь его здесь означало бы молча занизить отчёт.
CREATE VIEW v_operation AS
SELECT o.ledger_id,
       o.uuid,
       o."date",
       o.acc_fr_uuid,
       o.acc_to_uuid,
       o.amount,
       o.comment,
       acf.name AS acc_fr_name,
       act.name AS acc_to_name,
       COALESCE(aof.currency_uuid, aot.currency_uuid) AS currency_uuid,
       (aof.uuid IS NOT NULL) AS acc_from_is_operating,
       (aot.uuid IS NOT NULL) AS acc_to_is_operating
  FROM operation o
  JOIN account acf
    ON acf.ledger_id = o.ledger_id
   AND acf.uuid      = o.acc_fr_uuid
  JOIN account act
    ON act.ledger_id = o.ledger_id
   AND act.uuid      = o.acc_to_uuid
  LEFT JOIN account_operating aof
         ON aof.ledger_id = acf.ledger_id
        AND aof.uuid      = acf.uuid
        AND aof.deleted_at IS NULL
  LEFT JOIN account_operating aot
         ON aot.ledger_id = act.ledger_id
        AND aot.uuid      = act.uuid
        AND aot.deleted_at IS NULL
 WHERE o.deleted_at IS NULL;

-- v_operation + курс на дату операции и сумма в эквиваленте. Без COALESCE
-- на курсе намеренно — NULL означает "пересчитать нельзя", а не курс 1:1
-- (см. docs/ARCHITECTURE.md, три состояния эквивалента).
CREATE VIEW v_operation_eq AS
SELECT o.ledger_id,
       o.uuid,
       o."date",
       o.acc_fr_uuid,
       o.acc_to_uuid,
       o.amount,
       o.comment,
       o.acc_fr_name,
       o.acc_to_name,
       o.acc_from_is_operating,
       o.acc_to_is_operating,
       o.currency_uuid,
       tc.uuid                                   AS to_currency_uuid,
       r."date"                                  AS max_date_rate,
       r.rate,
       round(r.rate * o.amount, tc."precision")  AS amount_eq
  FROM v_operation o
  CROSS JOIN LATERAL (
        SELECT c.uuid, c."precision"
          FROM currency c
         WHERE c.deleted_at IS NULL
           AND (c.ledger_id IS NULL OR c.ledger_id = o.ledger_id)
       ) tc
  LEFT JOIN LATERAL (
        SELECT rr."date", rr.rate
          FROM v_currency_conversion_rate rr
         WHERE rr.from_currency_uuid = o.currency_uuid
           AND rr.to_currency_uuid   = tc.uuid
           AND rr."date"            <= o."date"::date
           AND (rr.ledger_id IS NULL OR rr.ledger_id = o.ledger_id)
         ORDER BY rr."date" DESC, (rr.ledger_id IS NULL)
         LIMIT 1
       ) r ON true;

-- ── Отчётные функции (порт schema/client/select/) ───────────────────────

-- Баланс каждого кошелька леджера на дату (обороты строго ДО p_date), в
-- своей валюте и в эквиваленте. Только кошельки, по которым было движение.
CREATE FUNCTION f_balance_to_date(
    p_ledger_id   uuid,
    p_date        timestamp,
    p_eq_currency uuid
) RETURNS TABLE (
    account_uuid  uuid,
    account_name  text,
    currency_uuid uuid,
    symbol        text,
    "precision"   smallint,
    balance       numeric,
    balance_eq    numeric
)
    LANGUAGE sql
    STABLE
    PARALLEL SAFE
AS $$
    SELECT vao.uuid,
           vao.name,
           c.uuid,
           c.symbol,
           c."precision",
           round(coalesce(opt.amount_to, 0) - coalesce(opf.amount_fr, 0), c."precision"),
           round(r.rate * (coalesce(opt.amount_to, 0) - coalesce(opf.amount_fr, 0)),
                 (SELECT eq."precision" FROM currency eq WHERE eq.uuid = p_eq_currency))
               AS eq_value
      FROM v_account_operating vao
      JOIN currency c
        ON c.uuid = vao.currency_uuid
       AND c.deleted_at IS NULL
      LEFT JOIN (
            SELECT o.acc_to_uuid, sum(o.amount) AS amount_to
              FROM operation o
             WHERE o.ledger_id = p_ledger_id
               AND o.deleted_at IS NULL
               AND o."date" < p_date
             GROUP BY o.acc_to_uuid
           ) opt ON opt.acc_to_uuid = vao.uuid
      LEFT JOIN (
            SELECT o.acc_fr_uuid, sum(o.amount) AS amount_fr
              FROM operation o
             WHERE o.ledger_id = p_ledger_id
               AND o.deleted_at IS NULL
               AND o."date" < p_date
             GROUP BY o.acc_fr_uuid
           ) opf ON opf.acc_fr_uuid = vao.uuid
      LEFT JOIN LATERAL (
            SELECT rr.rate
              FROM v_currency_conversion_rate rr
             WHERE rr.from_currency_uuid = c.uuid
               AND rr.to_currency_uuid   = p_eq_currency
               AND rr."date"            <= p_date::date
               AND (rr.ledger_id IS NULL OR rr.ledger_id = p_ledger_id)
             ORDER BY rr."date" DESC, (rr.ledger_id IS NULL)
             LIMIT 1
           ) r ON true
     WHERE vao.ledger_id = p_ledger_id
       AND (opt.acc_to_uuid IS NOT NULL OR opf.acc_fr_uuid IS NOT NULL)
     ORDER BY eq_value DESC NULLS LAST;
$$;

-- Доход за период с разбивкой по счёту-источнику. Доход отличает
-- направление (категория -> кошелёк), не знак — amount в operation всегда
-- положительный. Границы периода включительны с обеих сторон.
CREATE FUNCTION f_income_for_period(
    p_ledger_id   uuid,
    p_from        timestamp,
    p_to          timestamp,
    p_eq_currency uuid
) RETURNS TABLE (
    account_uuid  uuid,
    account_name  text,
    currency_uuid uuid,
    amount        numeric,
    amount_eq     numeric
)
    LANGUAGE sql
    STABLE
    PARALLEL SAFE
AS $$
    SELECT o.acc_fr_uuid,
           o.acc_fr_name,
           o.currency_uuid,
           round(sum(o.amount),
                 (SELECT c."precision" FROM currency c WHERE c.uuid = o.currency_uuid)),
           round(sum(o.amount_eq),
                 (SELECT eq."precision" FROM currency eq WHERE eq.uuid = p_eq_currency))
               AS eq_value
      FROM v_operation_eq o
     WHERE o.ledger_id        = p_ledger_id
       AND o.to_currency_uuid = p_eq_currency
       AND o."date" BETWEEN p_from AND p_to
       AND o.acc_to_is_operating
       AND NOT o.acc_from_is_operating
     GROUP BY o.acc_fr_uuid, o.acc_fr_name, o.currency_uuid
     ORDER BY eq_value DESC NULLS LAST;
$$;

-- Зеркально: расход — деньги идут из кошелька в категорию.
CREATE FUNCTION f_expanse_for_period(
    p_ledger_id   uuid,
    p_from        timestamp,
    p_to          timestamp,
    p_eq_currency uuid
) RETURNS TABLE (
    account_uuid  uuid,
    account_name  text,
    currency_uuid uuid,
    amount        numeric,
    amount_eq     numeric
)
    LANGUAGE sql
    STABLE
    PARALLEL SAFE
AS $$
    SELECT o.acc_to_uuid,
           o.acc_to_name,
           o.currency_uuid,
           round(sum(o.amount),
                 (SELECT c."precision" FROM currency c WHERE c.uuid = o.currency_uuid)),
           round(sum(o.amount_eq),
                 (SELECT eq."precision" FROM currency eq WHERE eq.uuid = p_eq_currency))
               AS eq_value
      FROM v_operation_eq o
     WHERE o.ledger_id        = p_ledger_id
       AND o.to_currency_uuid = p_eq_currency
       AND o."date" BETWEEN p_from AND p_to
       AND o.acc_from_is_operating
       AND NOT o.acc_to_is_operating
     GROUP BY o.acc_to_uuid, o.acc_to_name, o.currency_uuid
     ORDER BY eq_value DESC NULLS LAST;
$$;

-- ── Роль только для чтения (сервис отчётов, план п. 4.3) ────────────────
--
-- Идемпотентна и лечащая: не только создаёт роль, но и приводит уже
-- существующую к описанному виду (см. schema/server/role/wallet_reader.sql
-- — тот же файл, перенесён дословно). Пароль в репозитории — осознанно для
-- локальной разработки; для стенда с реальными данными сменить отдельно
-- (ALTER ROLE ... PASSWORD, вне этого файла).
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'wallet_reader') THEN
        CREATE ROLE wallet_reader;
    END IF;
END
$$;

-- CONNECTION LIMIT 20 — не произвольное число: это реальный потолок
-- REPORTS_DB_POOL_SIZE у wallet-report (см. wallet-report/loadtest/README.md,
-- "Шаг 4" — REPORTS_DB_POOL_SIZE=32 воспроизводимо кладёт wallet-report в
-- рестарт-луп с "too many connections for role wallet_reader" в логах,
-- реальный инцидент 2026-09-17). Поднимать это число вместе с
-- REPORTS_DB_POOL_SIZE, не отдельно — иначе тот же инцидент повторится на
-- любом REPORTS_DB_POOL_SIZE выше текущего лимита.
ALTER ROLE wallet_reader
    LOGIN
    NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
    CONNECTION LIMIT 20
    PASSWORD 'wallet_reader';

DO $$
BEGIN
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO wallet_reader', current_database());
END
$$;

GRANT USAGE ON SCHEMA public TO wallet_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO wallet_reader;

GRANT EXECUTE ON FUNCTION f_balance_to_date(uuid, timestamp, uuid)              TO wallet_reader;
GRANT EXECUTE ON FUNCTION f_income_for_period(uuid, timestamp, timestamp, uuid) TO wallet_reader;
GRANT EXECUTE ON FUNCTION f_expanse_for_period(uuid, timestamp, timestamp, uuid) TO wallet_reader;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
    ON ALL TABLES IN SCHEMA public FROM wallet_reader;

ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO wallet_reader;
