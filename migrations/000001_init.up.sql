-- Перенесено из infra/db/init-db.sh (см. infra/db/README.md, "Схема / миграции").
-- owner_id — НЕ внешний ключ: своей таблицы users в этой базе нет и не
-- будет, это просто "sub" из уже проверенного access-токена (см. README
-- wallet-api, "Своя БД").
CREATE TABLE wallets (
    id UUID PRIMARY KEY,
    owner_id UUID NOT NULL,
    currency TEXT NOT NULL,
    label TEXT NOT NULL,
    balance_cents BIGINT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX wallets_owner_id_idx ON wallets(owner_id);
