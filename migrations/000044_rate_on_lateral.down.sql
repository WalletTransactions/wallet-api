-- Откат 000044: прежнее тело rate_on (подзапрос к v_currency_conversion_rate), дословно из 000043.
-- Данные не затрагиваются.

CREATE OR REPLACE FUNCTION rate_on(p_ledger uuid, p_from uuid, p_to uuid, p_date date)
RETURNS TABLE ("date" date, rate numeric)
LANGUAGE sql
STABLE
AS $$
    (SELECT rr."date", rr.rate
       FROM v_currency_conversion_rate rr
      WHERE rr.from_currency_uuid = p_from
        AND rr.to_currency_uuid   = p_to
        AND rr."date"            <= p_date
        AND (rr.ledger_id IS NULL OR rr.ledger_id = p_ledger)
      ORDER BY rr."date" DESC, (rr.ledger_id IS NULL)
      LIMIT 1)
    UNION ALL
    SELECT f.rate_date, f.rate FROM rate_fallback(p_ledger, p_from, p_to, p_date) f
    LIMIT 1
$$;

COMMENT ON FUNCTION rate_on(uuid, uuid, uuid, date) IS
    'Курс from -> to леджера на дату: прямой курс, иначе явный маршрут, иначе кросс через USD; нет курса — пусто.';
