-- Экран "Обзор" (веб-отчёт, servers/wallet-web) — по прямому запросу
-- "сделай обзор по дизайну" (Design/.../Отчёты - веб.dc.html). Две новые
-- отчётные функции: помесячный доход/расход (график "Расход по месяцам") и
-- расход по дню недели (график "По дням недели"). Ни группы категорий, ни
-- "обязательные платежи" из дизайна сюда не входят — по прямому указанию
-- пользователя ("группы по прежнему не нужны, обязательные платежи не
-- нужны"), первое и так исключено ещё в 000004 (плоские категории), второе
-- потребовало бы отдельного механизма определения регулярных списаний,
-- которого в схеме нет вовсе.
--
-- Обе функции нулят месяцы/дни недели без операций (generate_series +
-- LEFT JOIN), а не просто отдают то, что нашли: график должен показывать
-- ВСЕ 12 месяцев/7 дней недели ровными столбцами, включая нулевые, а не
-- сжиматься до количества месяцев с реальной активностью.
--
-- incomplete считается ТОЛЬКО по реально существующим операциям
-- (o.uuid IS NOT NULL AND o.amount_eq IS NULL) — месяц/день без единой
-- операции (o.uuid IS NULL — LEFT JOIN не нашёл ничего) НЕ несёт признак
-- неполноты, это просто "не было расходов", а не "курс не нашёлся".
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
     GROUP BY months.month_start
     ORDER BY months.month_start;
$$;

GRANT EXECUTE ON FUNCTION f_income_expense_by_month(uuid, timestamp, timestamp, uuid) TO wallet_reader;

-- Расход (не доход — "ритм" в дизайне про то, в какие дни тратят) по дню
-- недели, isodow: 1=понедельник..7=воскресенье (не extract(dow) — тот 0=
-- воскресенье, естественнее для Пн..Вс подписей на графике).
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

GRANT EXECUTE ON FUNCTION f_expense_by_weekday_for_period(uuid, timestamp, timestamp, uuid) TO wallet_reader;
