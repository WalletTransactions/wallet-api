-- "Обзор" (веб-отчёт, wallet-api/src/reports_repo.cpp
-- ::income_expense_by_month) — доход и расход по календарным месяцам,
-- график "Расход по месяцам". Не порт клиента — эта агрегация нужна только
-- веб-отчёту.
--
-- months.month_start — РОВНО по одному элементу на каждый календарный месяц
-- между p_from и p_to (generate_series + LEFT JOIN), включая месяцы без
-- единой операции: график должен показывать все 12 месяцев ровными
-- столбцами, а не сжиматься до месяцев с реальной активностью. Расход и
-- доход отличает НАПРАВЛЕНИЕ проводки (acc_from_is_operating /
-- acc_to_is_operating), не знак суммы; перевод кошелёк-кошелёк (обе стороны
-- operating) в оборот ни дохода, ни расхода не входит.
--
-- incomplete считается ТОЛЬКО по реально существующим операциям
-- (o.uuid IS NOT NULL AND o.amount_eq IS NULL) — месяц без единой операции
-- (o.uuid IS NULL, LEFT JOIN не нашёл ничего) НЕ несёт признак неполноты,
-- это просто "не было расходов", а не "курс не нашёлся".
--
-- Источник истины — реальная миграция
-- wallet-api/migrations/000006_overview.up.sql (см.
-- ../../README.md про этот принцип); этот файл — читаемое зеркало.
CREATE FUNCTION f_income_expense_by_month(
    p_ledger_id   uuid,
    p_from        timestamp,
    p_to          timestamp,
    p_eq_currency uuid
) RETURNS TABLE (
    month_start  date,
    income_eq    numeric,
    expense_eq   numeric,
    incomplete   boolean
)
    LANGUAGE sql
    STABLE
    PARALLEL SAFE
AS $$
    SELECT months.month_start::date,
           round(coalesce(sum(o.amount_eq)
                     FILTER (WHERE o.acc_to_is_operating AND NOT o.acc_from_is_operating), 0),
                 (SELECT c."precision" FROM currency c WHERE c.uuid = p_eq_currency)),
           round(coalesce(sum(o.amount_eq)
                     FILTER (WHERE o.acc_from_is_operating AND NOT o.acc_to_is_operating), 0),
                 (SELECT c."precision" FROM currency c WHERE c.uuid = p_eq_currency)),
           bool_or(o.uuid IS NOT NULL AND o.amount_eq IS NULL)
      FROM generate_series(date_trunc('month', p_from), date_trunc('month', p_to), interval '1 month')
               AS months(month_start)
      LEFT JOIN v_operation_eq o
             ON date_trunc('month', o."date") = months.month_start
            AND o.ledger_id        = p_ledger_id
            AND o.to_currency_uuid = p_eq_currency
            AND o."date" BETWEEN p_from AND p_to
            AND o.acc_from_is_operating <> o.acc_to_is_operating -- расход ИЛИ доход, не перевод кошелёк-кошелёк
            -- Переоценка актива — ни доход, ни расход (capital-assets, 000033).
            AND NOT EXISTS (
                    SELECT 1 FROM account r
                     WHERE r.ledger_id = p_ledger_id
                       AND r.uuid IN (o.acc_fr_uuid, o.acc_to_uuid)
                       AND r.system_kind = 3
                )
     GROUP BY months.month_start
     ORDER BY months.month_start;
$$;
