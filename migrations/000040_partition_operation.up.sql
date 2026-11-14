-- operation и operation_link становятся секционированными таблицами
-- PARTITION BY HASH (ledger_id), 16 секций у каждой, одинаковый модуль:
-- строки одного леджера в обеих таблицах лежат в секциях с одним номером.
-- Решение и порядок шагов — openspec/changes/partition-operation-by-ledger/design.md.
--
-- Имена таблиц, столбцы, типы, ограничения, индексы, триггеры, вьюхи и права
-- остаются прежними: код wallet-api и wallet-report ходит по имени таблицы.
--
-- Из обычной таблицы секционированную можно получить только перестройкой с
-- переливом: строим operation_new/operation_link_new, переливаем, старые таблицы
-- удаляем, новые переименовываем. Всё в одной транзакции — при ошибке база
-- остаётся в прежнем состоянии. Ограничения и индексы создаём ПОСЛЕ перелива и
-- переименования: так быстрее и сразу получаются прежние имена, которые до DROP
-- заняты старыми объектами.
--
-- Блокировка ACCESS EXCLUSIVE держится на время перелива. Старый контейнер
-- wallet-api в это время ждёт, клиенты повторяют push/pull сами. lock_timeout не
-- даёт миграции повиснуть за долгим запросом: упадёт, повтор — тем же migrate.sh.
BEGIN;

SET LOCAL lock_timeout = '5s';

LOCK TABLE operation, operation_link IN ACCESS EXCLUSIVE MODE;

CREATE TABLE operation_new (
    uuid        uuid          NOT NULL,
    ledger_id   uuid          NOT NULL,
    seq         bigint        NOT NULL,
    deleted_at  timestamptz,
    updated_at  timestamptz   NOT NULL DEFAULT now(),
    updated_by  uuid,
    "date"      timestamp     NOT NULL,
    acc_fr_uuid uuid          NOT NULL,
    acc_to_uuid uuid          NOT NULL,
    amount      numeric(20,8) NOT NULL,
    comment     text          NOT NULL DEFAULT ''
) PARTITION BY HASH (ledger_id);

CREATE TABLE operation_link_new (
    uuid       uuid        NOT NULL,
    ledger_id  uuid        NOT NULL,
    seq        bigint      NOT NULL,
    deleted_at timestamptz,
    updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by uuid,
    main_uuid  uuid        NOT NULL,
    link_uuid  uuid        NOT NULL,
    type       smallint    NOT NULL DEFAULT 0
) PARTITION BY HASH (ledger_id);

-- Модуль 16 у обеих таблиц. Удвоение потом — по одной секции за раз
-- (schema/README.md, «Арендатор в ключе, а не в коде»).
DO $$
BEGIN
    FOR r IN 0..15 LOOP
        EXECUTE format('CREATE TABLE operation_p%s PARTITION OF operation_new FOR VALUES WITH (MODULUS 16, REMAINDER %s)',
                       lpad(r::text, 2, '0'), r);
        EXECUTE format('CREATE TABLE operation_link_p%s PARTITION OF operation_link_new FOR VALUES WITH (MODULUS 16, REMAINDER %s)',
                       lpad(r::text, 2, '0'), r);
    END LOOP;
END
$$;

-- INSERT, а не UPDATE: триггер updated_at висит на UPDATE и updated_at не меняет.
INSERT INTO operation_new       SELECT * FROM operation;
INSERT INTO operation_link_new  SELECT * FROM operation_link;

DROP VIEW v_operation_eq;
DROP VIEW v_operation;
DROP TABLE operation_link;
DROP TABLE operation;

ALTER TABLE operation_new      RENAME TO operation;
ALTER TABLE operation_link_new RENAME TO operation_link;

-- operation: ограничения с прежними именами.
ALTER TABLE operation
    ADD CONSTRAINT pk_operation PRIMARY KEY (ledger_id, uuid),
    ADD CONSTRAINT operation_amount_check CHECK (amount >= 0),
    ADD CONSTRAINT ck_operation_sides CHECK (acc_fr_uuid <> acc_to_uuid),
    ADD CONSTRAINT operation_ledger_id_fkey
        FOREIGN KEY (ledger_id) REFERENCES ledger (id) ON DELETE CASCADE,
    ADD CONSTRAINT operation_updated_by_fkey
        FOREIGN KEY (updated_by) REFERENCES device (id) ON DELETE SET NULL,
    ADD CONSTRAINT fk_operation_acc_fr
        FOREIGN KEY (ledger_id, acc_fr_uuid) REFERENCES account (ledger_id, uuid)
        DEFERRABLE INITIALLY IMMEDIATE,
    ADD CONSTRAINT fk_operation_acc_to
        FOREIGN KEY (ledger_id, acc_to_uuid) REFERENCES account (ledger_id, uuid)
        DEFERRABLE INITIALLY IMMEDIATE;

CREATE INDEX ix_operation_sync ON operation (ledger_id, seq);
CREATE INDEX ix_operation_date ON operation (ledger_id, "date" DESC) WHERE deleted_at IS NULL;
CREATE INDEX ix_operation_acc_fr ON operation (ledger_id, acc_fr_uuid, "date") WHERE deleted_at IS NULL;
CREATE INDEX ix_operation_acc_to ON operation (ledger_id, acc_to_uuid, "date") WHERE deleted_at IS NULL;

CREATE TRIGGER trg_operation_updated_at BEFORE UPDATE ON operation
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- operation_link: ссылается на operation, поэтому после её PK.
ALTER TABLE operation_link
    ADD CONSTRAINT pk_operation_link PRIMARY KEY (ledger_id, uuid),
    ADD CONSTRAINT operation_link_type_check CHECK (type IN (0, 1)),
    ADD CONSTRAINT ck_operation_link_distinct CHECK (main_uuid <> link_uuid),
    ADD CONSTRAINT operation_link_ledger_id_fkey
        FOREIGN KEY (ledger_id) REFERENCES ledger (id) ON DELETE CASCADE,
    ADD CONSTRAINT operation_link_updated_by_fkey
        FOREIGN KEY (updated_by) REFERENCES device (id) ON DELETE SET NULL,
    ADD CONSTRAINT fk_operation_link_main
        FOREIGN KEY (ledger_id, main_uuid) REFERENCES operation (ledger_id, uuid) ON DELETE CASCADE,
    ADD CONSTRAINT fk_operation_link_link
        FOREIGN KEY (ledger_id, link_uuid) REFERENCES operation (ledger_id, uuid) ON DELETE CASCADE;

CREATE INDEX ix_operation_link_sync ON operation_link (ledger_id, seq);
CREATE UNIQUE INDEX uq_operation_link_natural
    ON operation_link (ledger_id, main_uuid, link_uuid) WHERE deleted_at IS NULL;
CREATE INDEX ix_operation_link_link ON operation_link (ledger_id, link_uuid);

CREATE TRIGGER trg_operation_link_updated_at BEFORE UPDATE ON operation_link
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE operation IS
    'Единственная таблица транзакций. Любая операция — перевод между двумя account: расход "кошелёк → категория", доход "категория → кошелёк", перевод "кошелёк → кошелёк".';
COMMENT ON COLUMN operation.uuid IS 'Идентификатор операции, общий с клиентом.';
COMMENT ON COLUMN operation.ledger_id IS 'Леджер-владелец операции.';
COMMENT ON COLUMN operation.seq IS 'Версия строки в потоке изменений леджера.';
COMMENT ON COLUMN operation.deleted_at IS 'Момент мягкого удаления (tombstone); NULL — строка активна.';
COMMENT ON COLUMN operation.updated_at IS 'Момент последнего изменения строки — только диагностика.';
COMMENT ON COLUMN operation.updated_by IS 'Устройство, применившее последнее изменение этой строки.';
COMMENT ON COLUMN operation."date" IS
    'Бизнес-дата операции — локальное время клиента, БЕЗ часового пояса намеренно (перевод в UTC сдвинул бы часть операций через границу суток и разъехал отчёты между устройствами в разных поясах).';
COMMENT ON COLUMN operation.acc_fr_uuid IS 'Счёт списания (источник проводки).';
COMMENT ON COLUMN operation.acc_to_uuid IS 'Счёт зачисления (получатель проводки).';
COMMENT ON COLUMN operation.amount IS
    'Сумма проводки, всегда неотрицательная (CHECK amount >= 0) — направление задаёт пара acc_fr/acc_to, а не знак.';
COMMENT ON COLUMN operation.comment IS 'Свободный комментарий пользователя к операции.';

COMMENT ON TABLE operation_link IS
    'Связь проводок одной пользовательской операции, хранимых несколькими строками (разновалютный перевод, комиссия за перевод).';
COMMENT ON COLUMN operation_link.uuid IS 'Идентификатор строки связи.';
COMMENT ON COLUMN operation_link.ledger_id IS 'Леджер-владелец.';
COMMENT ON COLUMN operation_link.seq IS 'Версия строки в потоке изменений леджера.';
COMMENT ON COLUMN operation_link.deleted_at IS 'Момент мягкого удаления (tombstone); NULL — строка активна.';
COMMENT ON COLUMN operation_link.updated_at IS 'Момент последнего изменения строки — только диагностика.';
COMMENT ON COLUMN operation_link.updated_by IS 'Устройство, применившее последнее изменение этой строки.';
COMMENT ON COLUMN operation_link.main_uuid IS
    'Проводка списания с кошелька-источника — по ней находится вся операция целиком.';
COMMENT ON COLUMN operation_link.link_uuid IS 'Вторая нога перевода или комиссия, связанная с main_uuid.';
COMMENT ON COLUMN operation_link.type IS
    'Явная роль связки: 0 = нога валютного перевода, 1 = комиссия (см. OperationItem.LinkType на клиенте). Заменяет прежний вывод по system_kind счёта-источника.';

-- Вьюхи — дословно schema/view/v_operation.sql и v_operation_eq.sql (с 000002
-- не менялись).
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

-- Права. Default privileges мигратора их тоже выдают; явный GRANT — страховка
-- на случай, если они разъехались между контурами. Секции напрямую не
-- используются, но вьюхи и запросы идут через родителей — прав на родителей
-- достаточно (проверка прав выполняется на таблице из запроса).
GRANT SELECT, INSERT, UPDATE, DELETE ON operation, operation_link, v_operation, v_operation_eq TO wallet_api;
GRANT SELECT ON operation, operation_link, v_operation, v_operation_eq TO wallet_reader;

ANALYZE operation;
ANALYZE operation_link;

COMMIT;
