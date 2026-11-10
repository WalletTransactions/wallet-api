-- 000035 cascade-asset-tombstones: разовая чистка живых account_asset, у
-- которых удалён кошелёк (account_operating) или сам счёт (тот же uuid). Дальше
-- то же правило держит push_batch (src/sync_repo.cpp, cascade_rules()) — тем же
-- механизмом, что связи операций (000034).
--
-- Только данные, схема не меняется. Каждому затронутому леджеру — свой
-- next_seq: tombstone актива должен уйти в pull устройствам, которые уже
-- дочитали поток дальше прежнего seq. updated_by = NULL — изменение сервера.

DO $$
DECLARE
    l_ledger uuid;
    l_seq    bigint;
BEGIN
    FOR l_ledger IN
        SELECT DISTINCT aa.ledger_id
          FROM account_asset aa
         WHERE aa.deleted_at IS NULL
           AND (EXISTS (SELECT 1 FROM account_operating ao
                         WHERE ao.ledger_id = aa.ledger_id AND ao.uuid = aa.uuid
                           AND ao.deleted_at IS NOT NULL)
                OR EXISTS (SELECT 1 FROM account a
                            WHERE a.ledger_id = aa.ledger_id AND a.uuid = aa.uuid
                              AND a.deleted_at IS NOT NULL))
    LOOP
        l_seq := next_seq(l_ledger);
        UPDATE account_asset aa
           SET deleted_at = now(), seq = l_seq, updated_by = NULL
         WHERE aa.ledger_id = l_ledger
           AND aa.deleted_at IS NULL
           AND (EXISTS (SELECT 1 FROM account_operating ao
                         WHERE ao.ledger_id = aa.ledger_id AND ao.uuid = aa.uuid
                           AND ao.deleted_at IS NOT NULL)
                OR EXISTS (SELECT 1 FROM account a
                            WHERE a.ledger_id = aa.ledger_id AND a.uuid = aa.uuid
                              AND a.deleted_at IS NOT NULL));
    END LOOP;
END
$$;
