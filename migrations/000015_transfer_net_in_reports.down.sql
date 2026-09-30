-- Откат 000015_transfer_net_in_reports.up.sql — возвращает тела функций к
-- состоянию 000009_report_precision_join.up.sql (последнее место, где они
-- менялись до этой миграции).
CREATE OR REPLACE FUNCTION f_income_for_period(
    p_ledger_id   uuid,
    p_from        timestamp,
    p_to          timestamp,
    p_eq_currency uuid
) RETURNS TABLE (
    account_uuid  uuid,
    account_name  text,
    currency_uuid uuid,
    amount        numeric,
    amount_eq     numeric
)
    LANGUAGE sql
    STABLE
    PARALLEL SAFE
AS $$
    SELECT o.acc_fr_uuid,
           o.acc_fr_name,
           o.currency_uuid,
           round(sum(o.amount),    max(c."precision")),
           round(sum(o.amount_eq), max(eq."precision"))
               AS eq_value
      FROM v_operation_eq o
      JOIN currency c  ON c.uuid  = o.currency_uuid
      JOIN currency eq ON eq.uuid = p_eq_currency
     WHERE o.ledger_id        = p_ledger_id
       AND o.to_currency_uuid = p_eq_currency
       AND o."date" BETWEEN p_from AND p_to
       AND o.acc_to_is_operating
       AND NOT o.acc_from_is_operating
     GROUP BY o.acc_fr_uuid, o.acc_fr_name, o.currency_uuid
     ORDER BY eq_value DESC NULLS LAST;
$$;

CREATE OR REPLACE FUNCTION f_expanse_for_period(
    p_ledger_id   uuid,
    p_from        timestamp,
    p_to          timestamp,
    p_eq_currency uuid
) RETURNS TABLE (
    account_uuid  uuid,
    account_name  text,
    currency_uuid uuid,
    amount        numeric,
    amount_eq     numeric
)
    LANGUAGE sql
    STABLE
    PARALLEL SAFE
AS $$
    SELECT o.acc_to_uuid,
           o.acc_to_name,
           o.currency_uuid,
           round(sum(o.amount),    max(c."precision")),
           round(sum(o.amount_eq), max(eq."precision"))
               AS eq_value
      FROM v_operation_eq o
      JOIN currency c  ON c.uuid  = o.currency_uuid
      JOIN currency eq ON eq.uuid = p_eq_currency
     WHERE o.ledger_id        = p_ledger_id
       AND o.to_currency_uuid = p_eq_currency
       AND o."date" BETWEEN p_from AND p_to
       AND o.acc_from_is_operating
       AND NOT o.acc_to_is_operating
     GROUP BY o.acc_to_uuid, o.acc_to_name, o.currency_uuid
     ORDER BY eq_value DESC NULLS LAST;
$$;
