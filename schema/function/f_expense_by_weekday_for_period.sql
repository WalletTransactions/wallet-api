-- "Обзор" (веб-отчёт, wallet-api/src/reports_repo.cpp
-- ::expense_by_weekday) — расход по дню недели, график "По дням недели".
-- isodow: 1=понедельник..7=воскресенье (не extract(dow) — тот 0=воскресенье,
-- естественнее для подписей Пн..Вс на графике). Расход, не доход — панель
-- про то, в какие дни недели тратят.
--
-- days.isodow — РОВНО 7 строк (generate_series + LEFT JOIN), включая дни
-- без расхода, тем же приёмом zero-fill, что и у f_income_expense_by_month.
--
-- Источник истины — реальная миграция
-- wallet-api/migrations/000006_overview.up.sql (см.
-- ../../README.md про этот принцип); этот файл — читаемое зеркало.
CREATE FUNCTION f_expense_by_weekday_for_period(
    p_ledger_id   uuid,
    p_from        timestamp,
    p_to          timestamp,
    p_eq_currency uuid
) RETURNS TABLE (
    isodow      smallint,
    expense_eq  numeric,
    incomplete  boolean
)
    LANGUAGE sql
    STABLE
    PARALLEL SAFE
AS $$
    SELECT days.isodow,
           round(coalesce(sum(o.amount_eq), 0),
                 (SELECT c."precision" FROM currency c WHERE c.uuid = p_eq_currency)),
           bool_or(o.uuid IS NOT NULL AND o.amount_eq IS NULL)
      FROM generate_series(1, 7) AS days(isodow)
      LEFT JOIN v_operation_eq o
             ON extract(isodow FROM o."date")::smallint = days.isodow
            AND o.ledger_id        = p_ledger_id
            AND o.to_currency_uuid = p_eq_currency
            AND o."date" BETWEEN p_from AND p_to
            AND o.acc_from_is_operating
            AND NOT o.acc_to_is_operating
     GROUP BY days.isodow
     ORDER BY days.isodow;
$$;
