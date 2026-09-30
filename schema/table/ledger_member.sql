-- Кто имеет доступ к леджеру и с какими правами.
--
-- Таблица заведена с первого дня, даже если пользователь один: без неё общий
-- кошелёк потом требует переписывания всех запросов, а с ней — только выдачи
-- второй строки.
--
-- Владелец ровно один (uq_ledger_member_owner): роль owner — это право удалить
-- леджер и раздать доступ, и «два владельца» не имеет разумной семантики при
-- конфликте. Передача владения — UPDATE двух строк в одной транзакции.
CREATE TABLE ledger_member (
    ledger_id uuid        NOT NULL REFERENCES ledger (id)   ON DELETE CASCADE,
    user_id   uuid        NOT NULL REFERENCES app_user (id) ON DELETE CASCADE,
    role      text        NOT NULL CHECK (role IN ('owner', 'member', 'reader')),
    joined_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT pk_ledger_member PRIMARY KEY (ledger_id, user_id)
);

CREATE UNIQUE INDEX uq_ledger_member_owner ON ledger_member (ledger_id) WHERE role = 'owner';

CREATE INDEX ix_ledger_member_user ON ledger_member (user_id);

COMMENT ON TABLE ledger_member IS
    'Права доступа пользователя к леджеру — кто может видеть/писать/владеть. Заведена с первого дня, даже если пользователь у леджера всегда один: общий кошелёк потом требует только выдачи второй строки, а не переписывания всех запросов.';
COMMENT ON COLUMN ledger_member.ledger_id IS 'Леджер, к которому относится право доступа.';
COMMENT ON COLUMN ledger_member.user_id IS 'Пользователь, которому выдано право доступа.';
COMMENT ON COLUMN ledger_member.role IS
    '''owner'' — ровно один на леджер (см. uq_ledger_member_owner), может удалить леджер и раздать доступ; ''member'' — обычный участник; ''reader'' — только чтение.';
COMMENT ON COLUMN ledger_member.joined_at IS 'Момент выдачи доступа к леджеру.';
