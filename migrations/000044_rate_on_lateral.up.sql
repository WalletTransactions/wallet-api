-- Change rate-on-lateral (wallet-report#29): прямой курс в rate_on — по индексу, а не «все курсы пары».
--
-- Было: подзапрос к v_currency_conversion_rate (пары × все курсы + тождественные строки) с
-- ORDER BY date DESC LIMIT 1. Планировщик не проталкивает LIMIT через JOIN вьюхи, поэтому на каждую
-- операцию строил ВСЕ курсы пары до её даты (замер: 247 строк на операцию при ежедневных курсах за
-- 900 дней) и сортировал; стоимость ≈ число операций × число курсов пары и росла с историей.
-- Стало: по каждой подходящей паре — один последний курс не позже даты через LATERAL … LIMIT 1 по
-- индексу ix_currency_pair_rate_lookup (currency_pair_uuid, date DESC), затем лучший из них.
--
-- Контракт и приоритеты те же (прямой курс → явный маршрут → кросс через USD; ledger поверх общего при
-- равных датах; нет курса — пусто), сигнатура, привилегии и потребители не меняются: CREATE OR REPLACE.
-- Результат сверен с прежней функцией: 0 расхождений на 3000 операциях нагрузочного леджера и на 47 628
-- пробах (леджер × из × в × дата, 9 992 с найденным курсом) со случайными данными: курсы леджера и общие
-- на одни даты, обратные пары, свои валюты и своя USD леджера, 5 % удалённых курсов, тождественные курсы,
-- ветка rate_fallback. Интеграционные тесты wallet-api (224) и wallet-report (84) проходят на новой функции.
-- Замер (операции окна 365 дней, ежедневные курсы EUR→USD): 296–307 мс → 104–111 мс на 1508 операциях,
-- f_expanse_by_category_for_period 154 → 70 мс.

CREATE OR REPLACE FUNCTION rate_on(p_ledger uuid, p_from uuid, p_to uuid, p_date date)
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
    'Курс from -> to леджера на дату: прямой курс (последний не позже даты по индексу), иначе явный маршрут, иначе кросс через USD; нет курса — пусто.';
