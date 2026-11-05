-- Откат 000031: тело f_expense_by_category_by_month из 000030 дословно.
CREATE OR REPLACE FUNCTION f_expense_by_category_by_month(
    p_ledger_id   uuid,
    p_from        timestamp,
    p_to          timestamp,
    p_eq_currency uuid
) RETURNS TABLE (
    account_uuid       uuid,
    account_name       text,
    icon_sha256        text,
    month_start        date,
    amount_eq          numeric,
    op_count           bigint,
    incomplete         boolean,
    category_amount_eq numeric,
    category_op_count  bigint,
    total_eq           numeric
)
    LANGUAGE sql
    STABLE
    PARALLEL SAFE
AS $$
    WITH prec AS (
        SELECT eq."precision" AS p FROM currency eq WHERE eq.uuid = p_eq_currency
    ),
    regular AS (
        SELECT o.acc_to_uuid                          AS account_uuid,
               date_trunc('month', o."date")::date    AS month_start,
               sum(o.amount_eq)                       AS amt,
               count(*)                               AS n,
               bool_or(o.amount_eq IS NULL)           AS inc
          FROM v_operation_eq o
         WHERE o.ledger_id        = p_ledger_id
           AND o.to_currency_uuid = p_eq_currency
           AND o."date" BETWEEN p_from AND p_to
           AND o.acc_from_is_operating
           AND NOT o.acc_to_is_operating
           AND NOT EXISTS (
                   SELECT 1 FROM operation_link ol
                    WHERE ol.ledger_id = p_ledger_id AND ol.main_uuid = o.uuid
                      AND ol.type = 0 AND ol.deleted_at IS NULL
               )
         GROUP BY o.acc_to_uuid, date_trunc('month', o."date")
    ),
    transfer_legs AS (
        SELECT date_trunc('month', o."date")::date AS month_start,
               ol.main_uuid,
               CASE WHEN ol.link_uuid = o.uuid THEN o.amount_eq ELSE -o.amount_eq END AS signed_eq,
               o.amount_eq IS NULL AS no_rate
          FROM v_operation_eq o
          JOIN operation_link ol
            ON ol.ledger_id = p_ledger_id
           AND (ol.main_uuid = o.uuid OR ol.link_uuid = o.uuid)
           AND ol.type = 0
           AND ol.deleted_at IS NULL
         WHERE o.ledger_id        = p_ledger_id
           AND o.to_currency_uuid = p_eq_currency
           AND o."date" BETWEEN p_from AND p_to
    ),
    transfer_account AS (
        SELECT a.uuid FROM account a
         WHERE a.ledger_id = p_ledger_id AND a.system_kind = 1 AND a.deleted_at IS NULL
    ),
    cats AS (
        SELECT r.account_uuid, sum(r.amt) AS amt, sum(r.n)::bigint AS n
          FROM regular r
         GROUP BY r.account_uuid
        UNION ALL
        SELECT ta.uuid, -sum(tl.signed_eq), count(DISTINCT tl.main_uuid)
          FROM transfer_legs tl CROSS JOIN transfer_account ta
         GROUP BY ta.uuid
        HAVING sum(tl.signed_eq) < 0
    ),
    cells AS (
        SELECT r.account_uuid, r.month_start, r.amt, r.n, r.inc
          FROM regular r
        UNION ALL
        SELECT ta.uuid, tl.month_start, -sum(tl.signed_eq), count(DISTINCT tl.main_uuid), bool_or(tl.no_rate)
          FROM transfer_legs tl CROSS JOIN transfer_account ta
         GROUP BY ta.uuid, tl.month_start
        HAVING sum(tl.signed_eq) IS DISTINCT FROM 0
    ),
    cats_rounded AS (
        SELECT c.account_uuid, round(c.amt, (SELECT p FROM prec)) AS amt, c.n FROM cats c
    )
    SELECT c.account_uuid,
           a.name,
           encode(i.content_sha256, 'hex'),
           m.month_start,
           round(m.amt, (SELECT p FROM prec)),
           m.n::bigint,
           m.inc,
           c.amt,
           c.n,
           (SELECT COALESCE(sum(cr.amt), 0) FROM cats_rounded cr)
      FROM cats_rounded c
      JOIN cells   m ON m.account_uuid = c.account_uuid
      JOIN account a ON a.ledger_id = p_ledger_id AND a.uuid = c.account_uuid
      JOIN icon    i ON i.uuid = a.icon_uuid
     ORDER BY c.amt DESC NULLS LAST, c.account_uuid, m.month_start;
$$;

COMMENT ON FUNCTION f_expense_by_category_by_month(uuid, timestamp, timestamp, uuid) IS
    'Расход «категория × календарный месяц» по правилам f_expanse_by_category_for_period (ноги перевода сведены в Transfer): строка на непустую клетку с суммой, числом операций и incomplete; итог и число операций категории за период и общий total_eq — в каждой строке. Миграция 000030.';
