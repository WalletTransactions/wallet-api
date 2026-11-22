-- Курс from -> to леджера на дату: последний не позже даты, при равных датах
-- курс леджера поверх общего. Приоритет источников: прямой курс (вьюха
-- v_currency_conversion_rate) -> явный маршрут -> кросс через USD (rate_fallback).
-- Нет курса — ни одной строки (пересчёта 1:1 нет).
--
-- SQL-функция: инлайнится в запрос потребителя, ветка rate_fallback вычисляется
-- только если прямого курса не нашлось (LIMIT 1 останавливает Append). Прямой
-- курс берётся по индексу (миграция 000044): по каждой паре один последний курс
-- не позже даты через LATERAL … LIMIT 1, а не «все курсы пары, затем сортировка».
-- Маршрут и USD считаются только для запрошенной пары и даты. Вариант «всё в одной вьюхе»
-- отвергнут замером (openspec currency-conversion-routes, design.md): уровень
-- USD строился по всем парам валют леджера.
CREATE FUNCTION rate_on(p_ledger uuid, p_from uuid, p_to uuid, p_date date)
RETURNS TABLE ("date" date, rate numeric)
LANGUAGE sql
STABLE
AS $$
    (SELECT x.d, x.rate
       FROM (
            -- Прямой курс: по каждой подходящей паре (прямой или обратной) — ОДИН последний курс не позже
            -- даты по индексу ix_currency_pair_rate_lookup (пара, дата DESC), затем лучший из них. Раньше
            -- здесь был подзапрос к v_currency_conversion_rate с ORDER BY … LIMIT 1: планировщик не
            -- проталкивает LIMIT через JOIN вьюхи и строил ВСЕ курсы пары до даты операции (сотни строк на
            -- операцию), стоимость росла вместе с историей курсов.
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
      LIMIT 1)
    UNION ALL
    SELECT f.rate_date, f.rate FROM rate_fallback(p_ledger, p_from, p_to, p_date) f
    LIMIT 1
$$;

COMMENT ON FUNCTION rate_on(uuid, uuid, uuid, date) IS
    'Курс from -> to леджера на дату: прямой курс, иначе явный маршрут, иначе кросс через USD; нет курса — пусто.';
