-- Курс from -> to леджера на дату: последний не позже даты, при равных датах
-- курс леджера поверх общего. Приоритет источников: прямой курс (rate_direct) ->
-- явный маршрут -> кросс через USD (rate_fallback). Нет курса — ни одной строки
-- (пересчёта 1:1 нет).
--
-- SQL-функция: инлайнится в запрос потребителя, ветка rate_fallback вычисляется
-- только если прямого курса не нашлось (LIMIT 1 останавливает Append). Прямой
-- курс — rate_direct (по индексу, миграция 000044: по каждой паре один последний
-- курс не позже даты через LATERAL … LIMIT 1, а не «все курсы пары, затем сортировка»).
-- Маршрут и USD считаются только для запрошенной пары и даты. Вариант «всё в одной вьюхе»
-- отвергнут замером (openspec currency-conversion-routes, design.md): уровень
-- USD строился по всем парам валют леджера.
CREATE FUNCTION rate_on(p_ledger uuid, p_from uuid, p_to uuid, p_date date)
RETURNS TABLE ("date" date, rate numeric)
LANGUAGE sql
STABLE
AS $$
    (SELECT d."date", d.rate FROM rate_direct(p_ledger, p_from, p_to, p_date) d)
    UNION ALL
    SELECT f.rate_date, f.rate
      FROM (SELECT 1
             WHERE
               -- Необходимое условие непустого rate_fallback, дешёвое и без plpgsql (wallet-api#51): явный
               -- маршрут между from и to ИЛИ у обеих валют есть живая пара с курсом (иначе плечо кросса через
               -- USD не найдётся). Нет условия — rate_fallback не вызывается вовсе: вызов plpgsql-функции
               -- (4–5 запросов) стоил больше всего остального поиска курса.
               EXISTS (SELECT 1 FROM currency_conversion cc
                        WHERE cc.ledger_id = p_ledger AND cc.deleted_at IS NULL AND cc.num = 1
                          AND ((cc.from_currency_uuid = p_from AND cc.to_currency_uuid = p_to)
                            OR (cc.from_currency_uuid = p_to   AND cc.to_currency_uuid = p_from)))
               OR (EXISTS (SELECT 1 FROM currency_pair cp
                            WHERE cp.deleted_at IS NULL AND (cp.base_currency_uuid = p_from OR cp.quote_currency_uuid = p_from)
                              AND (cp.ledger_id IS NULL OR cp.ledger_id = p_ledger)
                              AND EXISTS (SELECT 1 FROM currency_pair_rate r
                                           WHERE r.currency_pair_uuid = cp.uuid AND r.deleted_at IS NULL
                                             AND (r.ledger_id IS NULL OR r.ledger_id = p_ledger)))
                   AND EXISTS (SELECT 1 FROM currency_pair cp
                                WHERE cp.deleted_at IS NULL AND (cp.base_currency_uuid = p_to OR cp.quote_currency_uuid = p_to)
                                  AND (cp.ledger_id IS NULL OR cp.ledger_id = p_ledger)
                                  AND EXISTS (SELECT 1 FROM currency_pair_rate r
                                               WHERE r.currency_pair_uuid = cp.uuid AND r.deleted_at IS NULL
                                                 AND (r.ledger_id IS NULL OR r.ledger_id = p_ledger))))
           ) gd
     CROSS JOIN LATERAL rate_fallback(p_ledger, p_from, p_to, p_date) f
    LIMIT 1
$$;

COMMENT ON FUNCTION rate_on(uuid, uuid, uuid, date) IS
    'Курс from -> to леджера на дату: прямой курс, иначе явный маршрут, иначе кросс через USD; нет курса — пусто.';
