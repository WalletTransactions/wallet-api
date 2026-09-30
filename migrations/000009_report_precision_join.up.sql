-- f_income_for_period / f_expanse_for_period (000002_ledger_sync.up.sql) брали
-- precision округления коррелированным подзапросом в SELECT-листе:
-- (SELECT c."precision" FROM currency c WHERE c.uuid = o.currency_uuid) —
-- коррелирует с o.currency_uuid, колонкой из GROUP BY, и потому выполнялся
-- один раз на выходную (сгруппированную) строку, а не на каждую операцию;
-- (SELECT eq."precision" ... WHERE eq.uuid = p_eq_currency) коррелирует
-- только с параметром функции, и Postgres превращал его в InitPlan — одно
-- выполнение на весь вызов. Проблемы производительности не было, но JOIN
-- читается прямее и не требует от каждого читателя заново продумывать эту
-- тонкость (обсуждение 2026-09-08).
--
-- max(...) вокруг "precision" — не агрегация по смыслу, а обход того, что
-- Postgres не видит функциональной зависимости через JOIN (видит только для
-- PK-колонки той же таблицы, что стоит в GROUP BY): значение и так одно на
-- группу.
--
-- Только замена тела функций: сигнатура, RETURNS TABLE и результат по всем
-- существующим данным не меняются, поэтому GRANT из 000002 трогать не нужно.
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
