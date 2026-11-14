-- Связь проводок, которые пользователь завёл одной операцией, а база хранит
-- несколькими: перевод между разновалютными кошельками (две ноги через системную
-- категорию Transfer) и комиссия за перевод (отдельная проводка на свою категорию).
-- Появилась в клиенте в v71, потому что у operation одна колонка amount, а
-- разновалютному переводу нужны две суммы.
--
-- main_uuid — всегда проводка списания с кошелька-источника; по ней находится вся
-- операция целиком. link_uuid — вторая нога или комиссия.
--
-- Первичный ключ — суррогатный uuid, а не пара (main, link), как в клиенте.
-- Причина в протоколе: каждая синхронизируемая строка адресуется одной колонкой
-- идентичности — так устроены и outbox на клиенте, и разрешение конфликтов, и
-- ответ на push. Естественная пара при этом остаётся уникальной.
--
-- Ради этой таблицы push применяется одной транзакцией: если вторая нога перевода
-- или комиссия доедут отдельно от первой, второе устройство увидит половину
-- операции, и баланс кошелька разойдётся с исходным. Сама по себе группа при
-- удалении не снимается — это задача приложения, как и в клиенте.
--
-- type — явная роль связки (обсуждение 2026-09-09, план "Б" по TODO_transfers.md):
-- раньше роль (нога/комиссия) нигде не хранилась и выводилась в коде на лету —
-- сначала по совпадению id со счётом главной проводки, затем по system_kind
-- счёта-источника связанной проводки (обе версии — TransactionActivity.loadLinkedParts/
-- WalletDbLoader.AttachLinksTo). Явное поле нужно уже сейчас: следующие виды
-- связок будут отображаться в окне операции иначе, а вывод по счетам для них
-- уже не с чем сравнивать. Значения совпадают с OperationItem.LinkType на
-- клиенте: 0 = нога, 1 = комиссия. CHECK закрывает набор, как и у
-- account.system_kind/kind — колонка новая, унаследованного мусора нет;
-- следующий вид связки (когда появится) раздвинет CHECK отдельной миграцией,
-- тем же приёмом, что 000012_account_system_kind.
CREATE TABLE operation_link (
    uuid       uuid        NOT NULL,
    ledger_id  uuid        NOT NULL REFERENCES ledger (id) ON DELETE CASCADE,
    seq        bigint      NOT NULL,
    deleted_at timestamptz,
    updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by uuid REFERENCES device (id) ON DELETE SET NULL,

    main_uuid  uuid NOT NULL,
    link_uuid  uuid NOT NULL,
    type       smallint NOT NULL DEFAULT 0 CHECK (type IN (0, 1)),

    CONSTRAINT pk_operation_link PRIMARY KEY (ledger_id, uuid),
    CONSTRAINT fk_operation_link_main
        FOREIGN KEY (ledger_id, main_uuid) REFERENCES operation (ledger_id, uuid) ON DELETE CASCADE,
    CONSTRAINT fk_operation_link_link
        FOREIGN KEY (ledger_id, link_uuid) REFERENCES operation (ledger_id, uuid) ON DELETE CASCADE,
    CONSTRAINT ck_operation_link_distinct CHECK (main_uuid <> link_uuid)
) PARTITION BY HASH (ledger_id);

-- Секционирование — как у operation: HASH (ledger_id), модуль 16, тот же номер
-- секции у строк одного леджера. Реальная миграция —
-- migrations/000040_partition_operation.up.sql, решение —
-- openspec/changes/partition-operation-by-ledger/design.md.
CREATE TABLE operation_link_p00 PARTITION OF operation_link FOR VALUES WITH (MODULUS 16, REMAINDER 0);
CREATE TABLE operation_link_p01 PARTITION OF operation_link FOR VALUES WITH (MODULUS 16, REMAINDER 1);
CREATE TABLE operation_link_p02 PARTITION OF operation_link FOR VALUES WITH (MODULUS 16, REMAINDER 2);
CREATE TABLE operation_link_p03 PARTITION OF operation_link FOR VALUES WITH (MODULUS 16, REMAINDER 3);
CREATE TABLE operation_link_p04 PARTITION OF operation_link FOR VALUES WITH (MODULUS 16, REMAINDER 4);
CREATE TABLE operation_link_p05 PARTITION OF operation_link FOR VALUES WITH (MODULUS 16, REMAINDER 5);
CREATE TABLE operation_link_p06 PARTITION OF operation_link FOR VALUES WITH (MODULUS 16, REMAINDER 6);
CREATE TABLE operation_link_p07 PARTITION OF operation_link FOR VALUES WITH (MODULUS 16, REMAINDER 7);
CREATE TABLE operation_link_p08 PARTITION OF operation_link FOR VALUES WITH (MODULUS 16, REMAINDER 8);
CREATE TABLE operation_link_p09 PARTITION OF operation_link FOR VALUES WITH (MODULUS 16, REMAINDER 9);
CREATE TABLE operation_link_p10 PARTITION OF operation_link FOR VALUES WITH (MODULUS 16, REMAINDER 10);
CREATE TABLE operation_link_p11 PARTITION OF operation_link FOR VALUES WITH (MODULUS 16, REMAINDER 11);
CREATE TABLE operation_link_p12 PARTITION OF operation_link FOR VALUES WITH (MODULUS 16, REMAINDER 12);
CREATE TABLE operation_link_p13 PARTITION OF operation_link FOR VALUES WITH (MODULUS 16, REMAINDER 13);
CREATE TABLE operation_link_p14 PARTITION OF operation_link FOR VALUES WITH (MODULUS 16, REMAINDER 14);
CREATE TABLE operation_link_p15 PARTITION OF operation_link FOR VALUES WITH (MODULUS 16, REMAINDER 15);

CREATE INDEX ix_operation_link_sync ON operation_link (ledger_id, seq);

CREATE UNIQUE INDEX uq_operation_link_natural
    ON operation_link (ledger_id, main_uuid, link_uuid) WHERE deleted_at IS NULL;

-- Обратный обход: по любой проводке найти группу, в которую она входит.
CREATE INDEX ix_operation_link_link ON operation_link (ledger_id, link_uuid);

CREATE TRIGGER trg_operation_link_updated_at BEFORE UPDATE ON operation_link
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

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
