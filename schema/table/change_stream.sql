-- Счётчики версий строк. Источник значения seq, по которому клиент забирает
-- изменения: pull — это «отдай всё, у чего seq больше моего курсора».
--
-- Потоков два вида:
--   'ledger'    — по одному на каждый леджер, личные данные пользователя;
--   'reference' — один на всю базу, общие справочники (иконки, валюты, пары, курсы).
-- Клиент держит два курсора соответственно, см. ../README.md.
--
-- Поток леджера и сам леджер — одна строка, разнесённая по двум таблицам
-- с общим первичным ключом (ledger.id = change_stream.id). Тот же приём, что
-- account_operating над account в клиентской схеме.
--
-- Почему счётчик в таблице, а не SEQUENCE — см. ../function/next_seq.sql.
CREATE TABLE change_stream (
    id   uuid PRIMARY KEY,
    kind text   NOT NULL CHECK (kind IN ('ledger', 'reference')),
    seq  bigint NOT NULL DEFAULT 0 CHECK (seq >= 0),
    -- Чистка tombstone (change purge-synced-tombstones, миграция 000028).
    purged_seq bigint NOT NULL DEFAULT 0 CHECK (purged_seq >= 0),
    purged_at  timestamptz
);

-- Поток общих справочников. Это константа схемы, а не пользовательские данные:
-- на этот id ссылается весь код, работающий со справочниками.
INSERT INTO change_stream (id, kind)
VALUES ('00000000-0000-0000-0000-000000000001', 'reference');

COMMENT ON TABLE change_stream IS
    'Счётчики версий строк (seq): одна строка на каждый леджер (kind=''ledger'') плюс одна константная строка на общие справочники (kind=''reference''). next_seq() инкрементирует нужную строку в той же транзакции, что и сами изменения.';
COMMENT ON COLUMN change_stream.id IS
    'Для kind=''ledger'' совпадает с ledger.id того же леджера. Для kind=''reference'' — фиксированное значение 00000000-0000-0000-0000-000000000001, на которое ссылается весь код, работающий со справочниками.';
COMMENT ON COLUMN change_stream.kind IS
    '''ledger'' — персональный поток одного леджера (счета, операции, свои валюты/иконки); ''reference'' — общий поток на всю базу (общие иконки/валюты/пары/курсы).';
COMMENT ON COLUMN change_stream.seq IS
    'Текущее значение счётчика версий этого потока. Растёт монотонно только через next_seq() — не SEQUENCE и не время (см. ../README.md, "Версия строки — seq, а не время").';
COMMENT ON COLUMN change_stream.purged_seq IS
    'До какого seq поток вычищен от tombstone. pull с курсором 0 < cursor < purged_seq отвечает reset: true, reset_reason: "purged". 0 — чистки не было.';
COMMENT ON COLUMN change_stream.purged_at IS
    'Момент последней чистки потока (или попытки) — троттлинг «не чаще раза в час». NULL — чистки не было.';
