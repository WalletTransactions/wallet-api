-- Срок хранения удалённых строк синка (change purge-synced-tombstones).
--
-- device.last_ack_seq с 000002 был справочной копией курсора, код его не
-- писал. Теперь это подтверждение: GET /sync/pull записывает курсор из
-- запроса — всё до этого seq устройство применило и сохранило. Второе
-- подтверждение — для потока справочников. По минимуму подтверждений
-- активных устройств считается горизонт чистки потока.
--
-- change_stream.purged_seq — до какого seq поток вычищен: pull с курсором
-- 0 < cursor < purged_seq получает reset_reason "purged". purged_at —
-- момент последней чистки, по нему чистка идёт не чаще раза в час.
-- Константный DEFAULT не переписывает таблицу.
ALTER TABLE device ADD COLUMN last_ack_reference_seq bigint;

ALTER TABLE change_stream
    ADD COLUMN purged_seq bigint NOT NULL DEFAULT 0 CHECK (purged_seq >= 0),
    ADD COLUMN purged_at  timestamptz;

COMMENT ON COLUMN device.last_ack_seq IS
    'Подтверждение потока леджера: курсор ledger_seq последнего GET /sync/pull — всё до него устройство применило. NULL — устройство не читало поток своего текущего леджера (бот, только push; или сразу после перехода в другой леджер). Входит в горизонт чистки tombstone.';
COMMENT ON COLUMN device.last_ack_reference_seq IS
    'Подтверждение потока справочников: курсор reference_seq последнего GET /sync/pull. NULL — устройство не читало поток. Входит в горизонт чистки tombstone справочников.';
COMMENT ON COLUMN change_stream.purged_seq IS
    'До какого seq поток вычищен от tombstone. pull с курсором 0 < cursor < purged_seq отвечает reset: true, reset_reason: "purged". 0 — чистки не было.';
COMMENT ON COLUMN change_stream.purged_at IS
    'Момент последней чистки потока (или попытки) — троттлинг «не чаще раза в час». NULL — чистки не было.';
