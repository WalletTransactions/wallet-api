-- Откат 000010_wallet_turnover_eq.up.sql — восстанавливает f_wallet_turnover_for_period
-- в виде 000008_wallet_turnover.up.sql (3 параметра, без эквивалента).
DROP FUNCTION IF EXISTS f_wallet_turnover_for_period(uuid, timestamp, timestamp, uuid);

CREATE FUNCTION f_wallet_turnover_for_period(
    p_ledger_id uuid,
    p_from      timestamp,
    p_to        timestamp
) RETURNS TABLE (
    account_uuid  uuid,
    account_name  text,
    comment       text,
    is_archived   boolean,
    currency_uuid uuid,
    symbol        text,
    "precision"   smallint,
    icon_sha256   text,
    turnover_in   numeric,
    turnover_out  numeric
)
    LANGUAGE sql
    STABLE
    PARALLEL SAFE
AS $$
    SELECT vao.uuid,
           vao.name,
           vao.comment,
           vao.is_archived,
           c.uuid,
           c.symbol,
           c."precision",
           encode(ic.content_sha256, 'hex'),
           round(coalesce(opt.amount_to, 0), c."precision"),
           round(coalesce(opf.amount_fr, 0), c."precision")
      FROM v_account_operating vao
      JOIN currency c
        ON c.uuid = vao.currency_uuid
       AND c.deleted_at IS NULL
      JOIN icon ic ON ic.uuid = vao.icon_uuid
      LEFT JOIN (
            SELECT o.acc_to_uuid, sum(o.amount) AS amount_to
              FROM operation o
             WHERE o.ledger_id = p_ledger_id
               AND o.deleted_at IS NULL
               AND o."date" BETWEEN p_from AND p_to
             GROUP BY o.acc_to_uuid
           ) opt ON opt.acc_to_uuid = vao.uuid
      LEFT JOIN (
            SELECT o.acc_fr_uuid, sum(o.amount) AS amount_fr
              FROM operation o
             WHERE o.ledger_id = p_ledger_id
               AND o.deleted_at IS NULL
               AND o."date" BETWEEN p_from AND p_to
             GROUP BY o.acc_fr_uuid
           ) opf ON opf.acc_fr_uuid = vao.uuid
     WHERE vao.ledger_id = p_ledger_id
     ORDER BY vao.name;
$$;

GRANT EXECUTE ON FUNCTION f_wallet_turnover_for_period(uuid, timestamp, timestamp) TO wallet_reader;
