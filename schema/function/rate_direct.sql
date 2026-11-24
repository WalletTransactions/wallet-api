-- Прямой курс from -> to леджера на дату: последний не позже даты, при равных
-- датах курс леджера поверх общего. Без маршрута и кросса через USD — только
-- прямая или обратная пара и тождественный курс валюты на саму себя. Нет курса —
-- ни одной строки.
--
-- Общая часть rate_on (первый приоритет) и rate_fallback (проверка «есть ли прямой
-- курс вообще» и два плеча кросса через USD): по каждой подходящей паре ОДИН
-- последний курс не позже даты по индексу ix_currency_pair_rate_lookup (пара,
-- дата DESC) через LATERAL … LIMIT 1, затем лучший из них. Раньше rate_fallback
-- читал v_currency_conversion_rate с ORDER BY … LIMIT 1 — планировщик строит всю
-- вьюху (все курсы пары) и сортирует, на каждую операцию без прямого курса
-- (wallet-api#51).
--
-- p_date = 'infinity' даёт «есть ли курс на какую-нибудь дату».
CREATE FUNCTION rate_direct(p_ledger uuid, p_from uuid, p_to uuid, p_date date)
RETURNS TABLE ("date" date, rate numeric)
LANGUAGE sql
STABLE
AS $$
    SELECT x.d, x.rate
      FROM (
            SELECT r.d, CASE WHEN cc.is_reverse THEN 1.0 / r.rate ELSE r.rate END AS rate, r.is_ref
              FROM v_currency_conversion cc
             CROSS JOIN LATERAL (
                    SELECT rr."date" AS d, rr.rate,
                           (COALESCE(rr.ledger_id, cc.ledger_id) IS NULL) AS is_ref
                      FROM currency_pair_rate rr
                     WHERE rr.currency_pair_uuid = cc.currency_pair_uuid
                       AND rr.deleted_at IS NULL
                       AND (cc.ledger_id IS NULL OR rr.ledger_id IS NULL OR rr.ledger_id = cc.ledger_id)
                       AND (COALESCE(rr.ledger_id, cc.ledger_id) IS NULL
                            OR COALESCE(rr.ledger_id, cc.ledger_id) = p_ledger)
                       AND rr."date" <= p_date
                     ORDER BY rr."date" DESC, (COALESCE(rr.ledger_id, cc.ledger_id) IS NULL)
                     LIMIT 1) r
             WHERE cc.from_currency_uuid = p_from
               AND cc.to_currency_uuid   = p_to
               AND (cc.ledger_id IS NULL OR cc.ledger_id = p_ledger)
            UNION ALL
            -- «Тождественный» курс валюты на саму себя (как вторая ветка v_currency_conversion_rate).
            SELECT DATE '2000-01-01', 1::numeric, (c.ledger_id IS NULL)
              FROM currency c
             WHERE c.uuid = p_from AND p_from = p_to AND c.deleted_at IS NULL
               AND (c.ledger_id IS NULL OR c.ledger_id = p_ledger)
       ) x
     ORDER BY x.d DESC, x.is_ref
     LIMIT 1
$$;

COMMENT ON FUNCTION rate_direct(uuid, uuid, uuid, date) IS
    'Прямой курс from -> to леджера на дату (прямая или обратная пара, тождественный курс), по индексу; без маршрута и кросса через USD. Нет курса — пусто.';
