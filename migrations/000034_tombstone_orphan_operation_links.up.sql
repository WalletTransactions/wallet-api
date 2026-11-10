-- 000034 cascade-link-tombstones: разовая чистка живых связей операций, у
-- которых удалена хотя бы одна операция. Дальше то же правило держит
-- push_batch (src/sync_repo.cpp, tombstone_links_of_deleted_operations).
--
-- Только данные, схема не меняется. Каждому затронутому леджеру — свой
-- next_seq: tombstone связи должен уйти в pull устройствам, которые уже
-- дочитали поток дальше прежнего seq связи. updated_by = NULL — изменение
-- сервера, не устройства.

DO $$
DECLARE
    l_ledger uuid;
    l_seq    bigint;
BEGIN
    FOR l_ledger IN
        SELECT DISTINCT l.ledger_id
          FROM operation_link l
         WHERE l.deleted_at IS NULL
           AND EXISTS (SELECT 1 FROM operation o
                        WHERE o.ledger_id = l.ledger_id
                          AND o.uuid IN (l.main_uuid, l.link_uuid)
                          AND o.deleted_at IS NOT NULL)
    LOOP
        l_seq := next_seq(l_ledger);
        UPDATE operation_link l
           SET deleted_at = now(), seq = l_seq, updated_by = NULL
         WHERE l.ledger_id = l_ledger
           AND l.deleted_at IS NULL
           AND EXISTS (SELECT 1 FROM operation o
                        WHERE o.ledger_id = l.ledger_id
                          AND o.uuid IN (l.main_uuid, l.link_uuid)
                          AND o.deleted_at IS NOT NULL);
    END LOOP;
END
$$;
