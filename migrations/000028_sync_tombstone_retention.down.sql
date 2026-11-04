-- Откат 000028_sync_tombstone_retention.up.sql. Вычищенные строки не
-- возвращаются — их уже получили все активные устройства.
ALTER TABLE change_stream
    DROP COLUMN purged_at,
    DROP COLUMN purged_seq;

ALTER TABLE device DROP COLUMN last_ack_reference_seq;

COMMENT ON COLUMN device.last_ack_seq IS
    'Справочная копия курсора клиента — только для диагностики и "сбросить синхронизацию на этом устройстве". Авторитетный курсор всё равно хранится на клиенте — сервер не знает, доехала ли до него последняя страница.';
