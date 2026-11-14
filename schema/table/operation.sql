-- Единственная таблица транзакций. Любая операция — перевод между двумя account:
-- расход это «кошелёк → категория», доход «категория → кошелёк», перевод
-- «кошелёк → кошелёк».
--
-- Тип date — timestamp БЕЗ часового пояса, и это принципиально. Это бизнес-дата,
-- по которой считаются периоды, балансы и курс на дату; она приходит от клиента
-- в его локальном времени и такой же хранится. Перевод в timestamptz (то есть
-- в UTC) сдвинул бы часть операций через границу суток и молча разъехал отчёты
-- за период на двух устройствах в разных поясах. Служебные метки времени
-- (updated_at, created_at) — наоборот, всегда timestamptz.
--
-- amount numeric(20,8), а не double. В клиенте объявлено DECIMAL(15,2), но SQLite
-- тип игнорирует, а Java работает с double — суммы уже накопили погрешность
-- двоичной дроби. Сервер — первое место, где деньги действительно десятичные,
-- и это единственная причина, по которой numeric стоит своей цены.
--
-- CHECK (amount >= 0) строже клиента: там знак не проверяется, а направление
-- расхода задаётся парой acc_fr/acc_to, не минусом. Отрицательная сумма означает
-- ошибку на клиенте, и лучше получить отказ на push, чем перевёрнутую проводку
-- в истории. То же с ck_operation_sides: проводка сама в себя не имеет смысла,
-- в клиенте её отсекает только валидация экрана.
-- Первичный ключ составной, (ledger_id, uuid): и потому, что на него ссылается
-- operation_link, и потому, что одиночный uuid в первичном ключе закрыл бы
-- секционирование по ledger_id — PostgreSQL требует ключ секционирования в
-- каждом уникальном ограничении. См. ../README.md, раздел «Объёмы».
--
-- Таблица секционирована: PARTITION BY HASH (ledger_id), 16 секций, тот же
-- модуль, что у operation_link. Реальная миграция —
-- migrations/000040_partition_operation.up.sql, решение —
-- openspec/changes/partition-operation-by-ledger/design.md. Секции создаются
-- в конце файла.
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
        FOREIGN KEY (ledger_id, acc_fr_uuid) REFERENCES account (ledger_id, uuid)
        DEFERRABLE INITIALLY IMMEDIATE, -- откладывает удаление аккаунта, миграция 000025
    CONSTRAINT fk_operation_acc_to
        FOREIGN KEY (ledger_id, acc_to_uuid) REFERENCES account (ledger_id, uuid)
        DEFERRABLE INITIALLY IMMEDIATE,
    CONSTRAINT ck_operation_sides CHECK (acc_fr_uuid <> acc_to_uuid)
) PARTITION BY HASH (ledger_id);

-- Модуль 16, одинаковый у обеих таблиц. Удвоение — см. ../README.md.
CREATE TABLE operation_p00 PARTITION OF operation FOR VALUES WITH (MODULUS 16, REMAINDER 0);
CREATE TABLE operation_p01 PARTITION OF operation FOR VALUES WITH (MODULUS 16, REMAINDER 1);
CREATE TABLE operation_p02 PARTITION OF operation FOR VALUES WITH (MODULUS 16, REMAINDER 2);
CREATE TABLE operation_p03 PARTITION OF operation FOR VALUES WITH (MODULUS 16, REMAINDER 3);
CREATE TABLE operation_p04 PARTITION OF operation FOR VALUES WITH (MODULUS 16, REMAINDER 4);
CREATE TABLE operation_p05 PARTITION OF operation FOR VALUES WITH (MODULUS 16, REMAINDER 5);
CREATE TABLE operation_p06 PARTITION OF operation FOR VALUES WITH (MODULUS 16, REMAINDER 6);
CREATE TABLE operation_p07 PARTITION OF operation FOR VALUES WITH (MODULUS 16, REMAINDER 7);
CREATE TABLE operation_p08 PARTITION OF operation FOR VALUES WITH (MODULUS 16, REMAINDER 8);
CREATE TABLE operation_p09 PARTITION OF operation FOR VALUES WITH (MODULUS 16, REMAINDER 9);
CREATE TABLE operation_p10 PARTITION OF operation FOR VALUES WITH (MODULUS 16, REMAINDER 10);
CREATE TABLE operation_p11 PARTITION OF operation FOR VALUES WITH (MODULUS 16, REMAINDER 11);
CREATE TABLE operation_p12 PARTITION OF operation FOR VALUES WITH (MODULUS 16, REMAINDER 12);
CREATE TABLE operation_p13 PARTITION OF operation FOR VALUES WITH (MODULUS 16, REMAINDER 13);
CREATE TABLE operation_p14 PARTITION OF operation FOR VALUES WITH (MODULUS 16, REMAINDER 14);
CREATE TABLE operation_p15 PARTITION OF operation FOR VALUES WITH (MODULUS 16, REMAINDER 15);

CREATE INDEX ix_operation_sync ON operation (ledger_id, seq);

-- Лента и отчёты за период — всегда «операции леджера по дате».
CREATE INDEX ix_operation_date ON operation (ledger_id, "date" DESC) WHERE deleted_at IS NULL;

-- Баланс кошелька — разница поступлений и списаний до даты, то есть два
-- независимых обхода по каждой из сторон проводки.
CREATE INDEX ix_operation_acc_fr ON operation (ledger_id, acc_fr_uuid, "date") WHERE deleted_at IS NULL;
CREATE INDEX ix_operation_acc_to ON operation (ledger_id, acc_to_uuid, "date") WHERE deleted_at IS NULL;

CREATE TRIGGER trg_operation_updated_at BEFORE UPDATE ON operation
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
