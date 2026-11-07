-- Расширение кошелька — признак капитального актива (квартира, машина,
-- прочее имущество; change capital-assets, миграция 000033). Строка есть и
-- жива — кошелёк считается активом: его остаток — оценка имущества, вложения
-- в него идут переводом, а переоценка — проводкой с системной категорией
-- «Переоценка» (account.system_kind = 3). Мягкое удаление возвращает кошелёк
-- в ликвидные, не трогая его операции и баланс.
--
-- Наследование через общий PK, как у account_operating, но FK смотрит на
-- account_operating, а не на account: «актив только у кошелька» держит сама
-- схема — строка на категории даёт 23503 (409 missing_reference в push).
-- Каскад от удаления леджера идёт account → account_operating →
-- account_asset. Живость FK не проверяет: отчёты считают активом только
-- кошелёк, у которого живы все три строки (v_account_operating).
CREATE TABLE account_asset (
    uuid          uuid        NOT NULL,
    ledger_id     uuid        NOT NULL,
    seq           bigint      NOT NULL,
    deleted_at    timestamptz,
    updated_at    timestamptz NOT NULL DEFAULT now(),
    updated_by    uuid REFERENCES device (id) ON DELETE SET NULL,

    asset_type           smallint NOT NULL CHECK (asset_type IN (1, 2, 3)),
    include_in_net_worth boolean  NOT NULL DEFAULT true,
    comment              text     NOT NULL DEFAULT '',

    CONSTRAINT pk_account_asset PRIMARY KEY (ledger_id, uuid),
    CONSTRAINT fk_account_asset_account_operating
        FOREIGN KEY (ledger_id, uuid) REFERENCES account_operating (ledger_id, uuid) ON DELETE CASCADE
);

CREATE INDEX ix_account_asset_sync ON account_asset (ledger_id, seq);

CREATE TRIGGER trg_account_asset_updated_at BEFORE UPDATE ON account_asset
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE account_asset IS
    'Признак капитального актива у кошелька: живая строка — кошелёк является активом (недвижимость, авто, прочее). uuid всегда равен account.uuid и account_operating.uuid.';
COMMENT ON COLUMN account_asset.uuid IS '= account_operating.uuid того же кошелька.';
COMMENT ON COLUMN account_asset.ledger_id IS '= account_operating.ledger_id того же кошелька.';
COMMENT ON COLUMN account_asset.seq IS 'Версия строки в потоке изменений леджера — своя, отдельная от account.seq.';
COMMENT ON COLUMN account_asset.deleted_at IS
    'Момент мягкого удаления (снятие признака актива); NULL — кошелёк является активом.';
COMMENT ON COLUMN account_asset.updated_at IS 'Момент последнего изменения строки — только диагностика.';
COMMENT ON COLUMN account_asset.updated_by IS 'Устройство, применившее последнее изменение этой строки.';
COMMENT ON COLUMN account_asset.asset_type IS 'Тип актива: 1 = недвижимость, 2 = авто, 3 = прочее.';
COMMENT ON COLUMN account_asset.include_in_net_worth IS
    'Входит ли оценка актива в итог «всего с капиталом» (net_worth_eq в wallet-report).';
COMMENT ON COLUMN account_asset.comment IS 'Свободный комментарий к активу (адрес, VIN и т. п.).';
