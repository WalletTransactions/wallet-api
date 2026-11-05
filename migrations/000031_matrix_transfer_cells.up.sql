-- Матрица «категория × месяц»: клетки Transfer согласованы с её итогом.
--
-- В 000030 помесячные курсовые разницы переводов шли в клетки Transfer
-- всегда, а в итог категории — только при потере за весь период. Если за
-- период выигрыш, а в категорию Transfer есть обычная трата, у Transfer
-- итог — эта трата, а в месяцах — все курсовые разницы (и две строки одного
-- месяца). Тогда «лето + остальные месяцы» у wallet-mcp не сходились с
-- периодом целиком (живая проверка на test 2026-11-05: Transfer 60.00 против
-- суммы месяцев -2117.27).
--
-- Теперь курсовая разница и её месяцы входят только при потере за период,
-- обычная трата и разница одного месяца — одна клетка. Сигнатура и колонки не
-- меняются (CREATE OR REPLACE), wallet-report правок не требует.
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
    -- Курсовая разница переводов входит в Transfer, только если за ВЕСЬ
    -- период это потеря (net < 0) — условие строки Transfer в структуре. Тогда
    -- же и только тогда в клетки идут её помесячные части: сумма месяцев
    -- Transfer равна её итогу (000031; в 000030 клетки шли всегда и при
    -- выигрыше за период расходились с итогом).
    transfer_period AS (
        SELECT sum(tl.signed_eq) AS net, count(DISTINCT tl.main_uuid) AS n
          FROM transfer_legs tl
    ),
    transfer_cells AS (
        SELECT ta.uuid AS account_uuid, tl.month_start,
               -sum(tl.signed_eq) AS amt, count(DISTINCT tl.main_uuid) AS n, bool_or(tl.no_rate) AS inc
          FROM transfer_legs tl CROSS JOIN transfer_account ta
         WHERE (SELECT tp.net FROM transfer_period tp) < 0
         GROUP BY ta.uuid, tl.month_start
        HAVING sum(tl.signed_eq) IS DISTINCT FROM 0
    ),
    -- Обычная трата в саму категорию Transfer и курсовая потеря — одна
    -- категория и одна клетка на месяц (в 000030 — две строки одного месяца).
    cats AS (
        SELECT x.account_uuid, sum(x.amt) AS amt, sum(x.n)::bigint AS n
          FROM (SELECT r.account_uuid, r.amt, r.n FROM regular r
                UNION ALL
                SELECT ta.uuid, -tp.net, tp.n
                  FROM transfer_period tp CROSS JOIN transfer_account ta
                 WHERE tp.net < 0) x
         GROUP BY x.account_uuid
    ),
    cells AS (
        SELECT x.account_uuid, x.month_start, sum(x.amt) AS amt, sum(x.n)::bigint AS n, bool_or(x.inc) AS inc
          FROM (SELECT r.account_uuid, r.month_start, r.amt, r.n, r.inc FROM regular r
                UNION ALL
                SELECT tc.account_uuid, tc.month_start, tc.amt, tc.n, tc.inc FROM transfer_cells tc) x
         GROUP BY x.account_uuid, x.month_start
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
