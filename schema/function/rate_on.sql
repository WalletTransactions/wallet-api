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
    SELECT f.rate_date, f.rate FROM rate_fallback(p_ledger, p_from, p_to, p_date) f
    LIMIT 1
$$;

COMMENT ON FUNCTION rate_on(uuid, uuid, uuid, date) IS
    'Курс from -> to леджера на дату: прямой курс, иначе явный маршрут, иначе кросс через USD; нет курса — пусто.';
