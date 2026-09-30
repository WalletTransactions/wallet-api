-- "Кошельки и остатки"/"Обзор" (по прямому запросу — "отдавать балком за
-- период для нескольких кошельков": экран балансов делал до 14 отдельных
-- GET /api/reports/balance на один показ — начало периода, конец периода,
-- 12 точек спарклайна; "Обзор" — ещё 12 на линию остатка "Расхода по
-- месяцам") — баланс каждого кошелька леджера сразу на НЕСКОЛЬКО дат, одним
-- запросом к СУБД вместо N.
--
-- Та же формула, что и f_balance_to_date (обороты "на счёт" минус "со
-- счёта" СТРОГО ДО даты, курс — последний не позже даты), просто
-- unnest(p_dates) WITH ORDINALITY кросс-джойнится с v_account_operating
-- вместо одной даты. date_index — 1-based позиция даты во входном массиве
-- (WITH ORDINALITY нумерует с 1) — вызывающий код группирует строки ответа
-- по НЕЙ, а не по тексту даты: Postgres нормализует "2026-01-30" в
-- "2026-01-30 00:00:00" при выводе timestamp, сравнивать строки запроса и
-- ответа посимвольно было бы хрупко.
--
-- Даты БЕЗ единого кошелька в результат ВООБЩЕ не попадают (тот же фильтр
-- "было хоть какое-то движение", что и у f_balance_to_date) — восстановление
-- ПОЛНОГО списка дат (ровно один блок на каждую p_dates[i], включая пустые)
-- лежит на вызывающем коде (servers/wallet-report/src/reports_repo.cpp).
--
-- Те же две ловушки, что и в f_balance_to_date (см. её комментарий) —
-- NULLS LAST в сортировке и отсутствие COALESCE на курсе — актуальны и
-- здесь.
CREATE FUNCTION f_balance_to_dates(
    p_ledger_id   uuid,
    p_dates       timestamp[],
    p_eq_currency uuid
) RETURNS TABLE (
    date_index    integer,
    account_uuid  uuid,
    account_name  text,
    currency_uuid uuid,
    symbol        text,
    "precision"   smallint,
    balance       numeric,
    balance_eq    numeric
)
    LANGUAGE sql
    STABLE
    PARALLEL SAFE
AS $$
    SELECT d.idx::integer,
           vao.uuid,
           vao.name,
           c.uuid,
           c.symbol,
           c."precision",
           round(coalesce(opt.amount_to, 0) - coalesce(opf.amount_fr, 0), c."precision"),
           round(r.rate * (coalesce(opt.amount_to, 0) - coalesce(opf.amount_fr, 0)),
                 (SELECT eq."precision" FROM currency eq WHERE eq.uuid = p_eq_currency))
               AS eq_value
      FROM unnest(p_dates) WITH ORDINALITY AS d(balance_date, idx)
      CROSS JOIN v_account_operating vao
      JOIN currency c
        ON c.uuid = vao.currency_uuid
       AND c.deleted_at IS NULL
      LEFT JOIN LATERAL (
            SELECT sum(o.amount) AS amount_to
              FROM operation o
             WHERE o.ledger_id = p_ledger_id
               AND o.deleted_at IS NULL
               AND o.acc_to_uuid = vao.uuid
               AND o."date" < d.balance_date
           ) opt ON true
      LEFT JOIN LATERAL (
            SELECT sum(o.amount) AS amount_fr
              FROM operation o
             WHERE o.ledger_id = p_ledger_id
               AND o.deleted_at IS NULL
               AND o.acc_fr_uuid = vao.uuid
               AND o."date" < d.balance_date
           ) opf ON true
      LEFT JOIN LATERAL (
            SELECT rr.rate
              FROM v_currency_conversion_rate rr
             WHERE rr.from_currency_uuid = c.uuid
               AND rr.to_currency_uuid   = p_eq_currency
               AND rr."date"            <= d.balance_date::date
               AND (rr.ledger_id IS NULL OR rr.ledger_id = p_ledger_id)
             ORDER BY rr."date" DESC, (rr.ledger_id IS NULL)
             LIMIT 1
           ) r ON true
     WHERE vao.ledger_id = p_ledger_id
       AND (opt.amount_to IS NOT NULL OR opf.amount_fr IS NOT NULL)
     ORDER BY d.idx, eq_value DESC NULLS LAST;
$$;

GRANT EXECUTE ON FUNCTION f_balance_to_dates(uuid, timestamp[], uuid) TO wallet_reader;
