-- Идемпотентность отправки изменений.
--
-- Клиент офлайновый, значит повторы неизбежны: батч доехал, ответ потерялся,
-- клиент шлёт то же самое снова. Без этой таблицы повтор выглядит как чужая
-- правка (seq строки уже больше присланного base_seq) и возвращает 409 на
-- собственную запись пользователя.
--
-- batch_id генерирует клиент. Повтор с тем же batch_id возвращает сохранённый
-- response, ничего не применяя. Ключ именно на батч, а не на отдельную строку:
-- батч и так применяется одной транзакцией, и записать один факт дешевле, чем
-- разбирать построчно, какая правка своя, а какая чужая.
--
-- response хранит выданные seq по каждой строке и список конфликтов — ровно то,
-- что вернул первый вызов.
--
-- Строки живут недолго (порядка недели) и чистятся по расписанию: клиент,
-- не получивший ответ неделю назад, всё равно давно пересобрал батч заново.
CREATE TABLE sync_push_batch (
    batch_id   uuid PRIMARY KEY,
    device_id  uuid        NOT NULL REFERENCES device (id) ON DELETE CASCADE,
    ledger_id  uuid        NOT NULL REFERENCES ledger (id) ON DELETE CASCADE,
    seq        bigint      NOT NULL,
    response   jsonb       NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ix_sync_push_batch_created ON sync_push_batch (created_at);
CREATE INDEX ix_sync_push_batch_device  ON sync_push_batch (device_id, created_at DESC);

COMMENT ON TABLE sync_push_batch IS
    'Идемпотентность отправки изменений: сохранённый ответ на уже применённый батч, чтобы повтор того же batch_id (офлайновый клиент, ответ потерялся) не применял изменения повторно, а получил тот же ответ.';
COMMENT ON COLUMN sync_push_batch.batch_id IS
    'Идентификатор батча, генерирует клиент. Первичный ключ — повтор с тем же значением находит эту строку и возвращает её response, ничего не применяя заново.';
COMMENT ON COLUMN sync_push_batch.device_id IS 'Устройство, приславшее батч.';
COMMENT ON COLUMN sync_push_batch.ledger_id IS 'Леджер, к которому применён батч.';
COMMENT ON COLUMN sync_push_batch.seq IS
    'Значение seq, выданное этому батчу через next_seq() — то же самое значение записано во все изменённые этим батчом строки.';
COMMENT ON COLUMN sync_push_batch.response IS
    'Сохранённое тело HTTP-ответа (JSON) — то, что будет возвращено при повторе того же batch_id.';
COMMENT ON COLUMN sync_push_batch.created_at IS
    'Момент применения батча — по этому полю строки чистятся по расписанию (живут порядка недели).';
