-- Приглашение по одноразовой ссылке (servers/TODO_mobile_sync.md, Фаза 6,
-- пп. 9.1-9.3) — второй, явный путь получить строку в ledger_member, кроме
-- ленивого provisioning "первый вход = свой леджер" (см. provisioning.cpp).
--
-- role ограничена ('member', 'reader') — второго owner'а леджера ссылкой
-- пригласить нельзя, для этого отдельная операция передачи владения (см.
-- комментарий в ledger.sql, "Передача владения — UPDATE двух строк").
--
-- token_hash — sha256(сырой токен) в hex, тем же приёмом, что google-auth
-- хранит refresh/access-токены (store_refresh_token/store_access_token,
-- google-auth/src/repo.hpp): сырой токен уходит в ссылку и в ответ на
-- создание РОВНО ОДИН РАЗ, в этой таблице его нет вообще — прочитавший эту
-- таблицу не может выдать себя за приглашённого.
--
-- "Активно" не хранится отдельным полем-статусом — вычисляется на каждый
-- запрос как revoked_at IS NULL AND used_at IS NULL AND expires_at > now()
-- (тот же приём, что deleted_at у account/operation, см.
-- schema/server/README.md, "Удаление — deleted_at, не DELETE"). used_at/
-- used_by заполняются РОВНО ОДИН РАЗ — UPDATE ... WHERE used_at IS NULL в
-- момент приёма (см. invites_repo.cpp::accept_invite) — это и есть
-- "одноразовая ссылка": вторая попытка accept тем же токеном находит 0
-- строк и получает 410, а не тихо создаёт вторую строку ledger_member.
CREATE TABLE ledger_invite (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    ledger_id  uuid        NOT NULL REFERENCES ledger (id)   ON DELETE CASCADE,
    role       text        NOT NULL CHECK (role IN ('member', 'reader')),
    token_hash text        NOT NULL,
    created_by uuid        NOT NULL REFERENCES app_user (id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL CHECK (expires_at > created_at),
    revoked_at timestamptz,
    used_at    timestamptz,
    used_by    uuid REFERENCES app_user (id) ON DELETE CASCADE,

    -- used_at и used_by — только вместе (или оба NULL, или оба заполнены).
    CONSTRAINT ck_ledger_invite_used_together CHECK ((used_at IS NULL) = (used_by IS NULL)),
    -- Принятая (used_at) ссылка не может быть ЕЩЁ и отозвана — обе мутации
    -- идут через WHERE used_at IS NULL AND revoked_at IS NULL, это
    -- инвариант защищает от гонки, а не только документирует её отсутствие.
    CONSTRAINT ck_ledger_invite_not_used_and_revoked CHECK (used_at IS NULL OR revoked_at IS NULL)
);

CREATE UNIQUE INDEX uq_ledger_invite_token_hash ON ledger_invite (token_hash);
CREATE INDEX ix_ledger_invite_ledger ON ledger_invite (ledger_id);

COMMENT ON TABLE ledger_invite IS
    'Одноразовая пригласительная ссылка в леджер — второй путь (кроме первого входа) получить строку в ledger_member. role не допускает owner — для передачи владения отдельная операция.';
COMMENT ON COLUMN ledger_invite.ledger_id IS 'Леджер, в который приглашают.';
COMMENT ON COLUMN ledger_invite.role IS 'Роль, которую получит принявший приглашение — ''member'' или ''reader'' (не ''owner'').';
COMMENT ON COLUMN ledger_invite.token_hash IS 'sha256(сырой токен из ссылки), hex — сырой токен в БД не хранится, только в ответе на создание и в самой ссылке.';
COMMENT ON COLUMN ledger_invite.created_by IS 'Кто выпустил приглашение (владелец леджера на момент создания).';
COMMENT ON COLUMN ledger_invite.created_at IS 'Момент создания.';
COMMENT ON COLUMN ledger_invite.expires_at IS 'Истекает по сроку, выбранному при создании (2/7/30 дней) — приём после этого момента отклоняется (410).';
COMMENT ON COLUMN ledger_invite.revoked_at IS 'Отозвана владельцем вручную, до истечения срока и до использования.';
COMMENT ON COLUMN ledger_invite.used_at IS 'Момент, когда кто-то перешёл по ссылке и стал участником — заполняется ровно один раз (см. шапку файла).';
COMMENT ON COLUMN ledger_invite.used_by IS 'Кто принял приглашение (новый ledger_member этого леджера).';
