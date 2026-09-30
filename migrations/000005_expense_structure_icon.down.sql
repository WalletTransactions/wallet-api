-- Откат 000005_expense_structure_icon.up.sql — восстанавливает функцию
-- ровно в том виде, в каком её создала 000004_expense_structure.up.sql
-- (без icon_sha256), с тем же грантом.
DROP FUNCTION IF EXISTS f_expanse_by_category_for_period(uuid, timestamp, timestamp, uuid);

CREATE FUNCTION f_expanse_by_category_for_period(
    p_ledger_id   uuid,
    p_from        timestamp,
    p_to          timestamp,
    p_eq_currency uuid
) RETURNS TABLE (
    account_uuid  uuid,
    account_name  text,
    amount_eq     numeric
)
    LANGUAGE sql
    STABLE
    PARALLEL SAFE
AS $$
    SELECT o.acc_to_uuid,
           o.acc_to_name,
           round(sum(o.amount_eq),
                 (SELECT eq."precision" FROM currency eq WHERE eq.uuid = p_eq_currency))
               AS eq_value
      FROM v_operation_eq o
     WHERE o.ledger_id        = p_ledger_id
       AND o.to_currency_uuid = p_eq_currency
       AND o."date" BETWEEN p_from AND p_to
       AND o.acc_from_is_operating
       AND NOT o.acc_to_is_operating
     GROUP BY o.acc_to_uuid, o.acc_to_name
     ORDER BY eq_value DESC NULLS LAST;
$$;

GRANT EXECUTE ON FUNCTION f_expanse_by_category_for_period(uuid, timestamp, timestamp, uuid) TO wallet_reader;
