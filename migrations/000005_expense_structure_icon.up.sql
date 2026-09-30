-- Иконка категории на "Структуре расходов" (веб-отчёт, servers/wallet-web —
-- по прямому запросу "добавь иконки категорий (как и в дизайне)"). Меняет
-- набор колонок f_expanse_by_category_for_period (000004) — Postgres не даёт
-- CREATE OR REPLACE менять RETURNS TABLE, отсюда DROP+CREATE и повторный
-- GRANT (DROP снимает все привилегии на объект).
--
-- account.icon_uuid — NOT NULL REFERENCES icon(uuid), значит у КАЖДОЙ
-- категории есть иконка гарантированно; сама иконка ссылается на
-- содержимое в blob.sha256 (icon.content_sha256 — bytea, WEBP 256x256, см.
-- table/blob.sql), которое веб-клиент скачивает как есть через уже
-- существующий GET /sync/blobs/:sha256 (blob.cpp) — сессионной куки
-- достаточно, device_id не нужен (см. blob.hpp, "ничей" контент). Тут
-- только отдаём сам sha256 текстом (encode(...,'hex')) — тем же приёмом,
-- что hex_columns в протоколе синка (sync_repo.cpp), только сделано прямо
-- в SQL, а не отдельным полем TableSpec, раз это одна-единственная функция.
DROP FUNCTION IF EXISTS f_expanse_by_category_for_period(uuid, timestamp, timestamp, uuid);

CREATE FUNCTION f_expanse_by_category_for_period(
    p_ledger_id   uuid,
    p_from        timestamp,
    p_to          timestamp,
    p_eq_currency uuid
) RETURNS TABLE (
    account_uuid  uuid,
    account_name  text,
    amount_eq     numeric,
    icon_sha256   text
)
    LANGUAGE sql
    STABLE
    PARALLEL SAFE
AS $$
    SELECT o.acc_to_uuid,
           o.acc_to_name,
           round(sum(o.amount_eq),
                 (SELECT eq."precision" FROM currency eq WHERE eq.uuid = p_eq_currency))
               AS eq_value,
           encode(i.content_sha256, 'hex')
      FROM v_operation_eq o
      JOIN account a ON a.ledger_id = o.ledger_id AND a.uuid = o.acc_to_uuid
      JOIN icon    i ON i.uuid = a.icon_uuid
     WHERE o.ledger_id        = p_ledger_id
       AND o.to_currency_uuid = p_eq_currency
       AND o."date" BETWEEN p_from AND p_to
       AND o.acc_from_is_operating
       AND NOT o.acc_to_is_operating
     GROUP BY o.acc_to_uuid, o.acc_to_name, i.content_sha256
     ORDER BY eq_value DESC NULLS LAST;
$$;

GRANT EXECUTE ON FUNCTION f_expanse_by_category_for_period(uuid, timestamp, timestamp, uuid) TO wallet_reader;
