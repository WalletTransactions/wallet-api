-- Change rate-fallback-indexed (wallet-api#51): rate_fallback без запросов к вьюхе курсов.
--
-- Было: rate_on на каждую операцию без прямого курса звал rate_fallback (plpgsql), а тот читал
-- v_currency_conversion_rate с ORDER BY … LIMIT 1 — планировщик строит всю вьюху (все курсы пары) и
-- сортирует: шаг 0 «есть ли прямой курс на какую-нибудь дату» и оба плеча кросса через USD.
-- Стало: прямой курс вынесен в rate_direct (тот же индексный LATERAL … LIMIT 1, что был внутри rate_on,
-- миграция 000044), rate_on и плечи USD берут его; шаг 0 — EXISTS по паре и курсам без развёртки вьюхи;
-- плечи кросса считаются по очереди (нет первого — второе не считаем). Главное — rate_on вызывает
-- rate_fallback (plpgsql, 4–5 запросов: сам по себе дороже всего остального поиска курса) только если
-- выполнено необходимое условие непустого результата (явный маршрут между валютами ИЛИ у обеих валют есть
-- живая пара с курсом); иначе — вообще без вызова. Замер (одноразовый postgres, 900 дней курсов): операция
-- без курса 0.29 → 0.025 мс (прямой курс 0.12 мс), в т. ч. когда пары у валют есть, а курсов нет.
--
-- Контракт и приоритеты те же (прямой курс → явный маршрут → кросс через USD; «валидный маршрут без курса
-- у шага блокирует USD»; ledger поверх общего при равных датах), сигнатуры rate_on/rate_fallback,
-- потребители и привилегии не меняются: CREATE OR REPLACE.
-- Результат сверен со старыми функциями на случайных данных (два леджера со своими валютами и своей USD,
-- общие и леджерные пары и курсы на одни даты, обратные пары, маршруты 1–3 шага (в т. ч. сломанные),
-- удалённые пары/курсы/шаги/валюты): 4 набора по 8460 проб (леджер × из × в × дата), ≈3400–3700 с курсом, 455 троек
-- с веткой rate_fallback, 90 с явным маршрутом — 0 расхождений.

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

-- Маршрут и кросс через USD для пары (from, to) — только когда прямого курса
-- нет. Зовётся из rate_on, напрямую потребителями не используется.
--
-- Порядок:
--   0) есть ЛЮБОЙ живой прямой курс (на любую дату) — маршрута нет вовсе, даже
--      если все прямые курсы позже даты: прямой всегда приоритетнее;
--   1) явный маршрут леджера: цепочка шагов без разрывов (номера подряд с 1,
--      шаги стыкуются, концы = from/to; пары и валюты шагов живы). Курс =
--      произведение курсов шагов, каждый шаг — последний курс не позже даты
--      независимо от других; нет курса у какого-либо шага — курса нет. Такой
--      маршрут БЛОКИРУЕТ USD: молчаливая подмена исказила бы намерение;
--   2) кросс через USD: from -> USD -> to по двум прямым курсам. USD — валюта с
--      iso_code = 'USD', видимая леджеру (своя перекрывает общую); для самой USD
--      кросса нет.
-- rate_date — наибольшая из дат использованных курсов (дата, на которую
-- составной курс последний раз менялся).
CREATE OR REPLACE FUNCTION rate_fallback(p_ledger uuid, p_from uuid, p_to uuid, p_date date)
RETURNS TABLE (rate_date date, rate numeric)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_usd     uuid;
    v_n       int;
    v_rf      uuid;
    v_rt      uuid;
    v_prod    numeric;
    v_max     date;
    v_cnt     int;
    v_ok      boolean;
    v_at      uuid;
    v_ad      date;
    v_ar      numeric;
    v_bd      date;
    v_br      numeric;
    s         record;
    x         record;
BEGIN
    -- 0. прямой курс есть (хоть на какую-то дату) — маршрут не применяется
    -- Прямая или обратная пара с живым курсом на любую дату, либо тождественный курс валюты. Те же условия,
    -- что в rate_direct, но без выбора «лучшего» курса и без развёртки вьюхи v_currency_conversion — только
    -- факт существования, по индексу ix_currency_pair_rate_lookup (раньше читалась вся вьюха курсов, wallet-api#51).
    IF EXISTS (SELECT 1
                 FROM currency_pair cp
                WHERE cp.deleted_at IS NULL
                  AND ((cp.base_currency_uuid = p_from AND cp.quote_currency_uuid = p_to)
                    OR (cp.base_currency_uuid = p_to   AND cp.quote_currency_uuid = p_from))
                  AND (cp.ledger_id IS NULL OR cp.ledger_id = p_ledger)
                  AND EXISTS (SELECT 1 FROM currency c WHERE c.uuid = cp.base_currency_uuid  AND c.deleted_at IS NULL)
                  AND EXISTS (SELECT 1 FROM currency c WHERE c.uuid = cp.quote_currency_uuid AND c.deleted_at IS NULL)
                  AND EXISTS (SELECT 1
                                FROM currency_pair_rate r
                               WHERE r.currency_pair_uuid = cp.uuid AND r.deleted_at IS NULL
                                 AND (cp.ledger_id IS NULL OR r.ledger_id IS NULL OR r.ledger_id = cp.ledger_id)
                                 AND (COALESCE(r.ledger_id, cp.ledger_id) IS NULL
                                      OR COALESCE(r.ledger_id, cp.ledger_id) = p_ledger)))
       OR (p_from = p_to AND EXISTS (SELECT 1 FROM currency c
                                      WHERE c.uuid = p_from AND c.deleted_at IS NULL
                                        AND (c.ledger_id IS NULL OR c.ledger_id = p_ledger))) THEN
        RETURN;
    END IF;

    -- 1. явный маршрут (в любом порядке from/to; у любого маршрута есть шаг 1)
    SELECT cc.from_currency_uuid, cc.to_currency_uuid INTO v_rf, v_rt
      FROM currency_conversion cc
     WHERE cc.ledger_id = p_ledger AND cc.deleted_at IS NULL AND cc.num = 1
       AND ((cc.from_currency_uuid = p_from AND cc.to_currency_uuid = p_to)
         OR (cc.from_currency_uuid = p_to   AND cc.to_currency_uuid = p_from))
     LIMIT 1;
    IF FOUND THEN
        SELECT count(*) INTO v_n
          FROM currency_conversion cc
         WHERE cc.ledger_id = p_ledger AND cc.deleted_at IS NULL
           AND cc.from_currency_uuid = v_rf AND cc.to_currency_uuid = v_rt;
        v_at := v_rf; v_ok := true; v_prod := 1; v_max := DATE '2000-01-01'; v_cnt := 0;
        FOR s IN
            SELECT cc.num, cc.is_reverse, cc.currency_pair_uuid,
                   p.base_currency_uuid AS b, p.quote_currency_uuid AS q
              FROM currency_conversion cc
              JOIN currency_pair p ON p.uuid = cc.currency_pair_uuid AND p.deleted_at IS NULL
                                  AND (p.ledger_id IS NULL OR p.ledger_id = p_ledger)
              JOIN currency cb ON cb.uuid = p.base_currency_uuid  AND cb.deleted_at IS NULL
              JOIN currency cq ON cq.uuid = p.quote_currency_uuid AND cq.deleted_at IS NULL
             WHERE cc.ledger_id = p_ledger AND cc.deleted_at IS NULL
               AND cc.from_currency_uuid = v_rf AND cc.to_currency_uuid = v_rt
             ORDER BY cc.num
        LOOP
            v_cnt := v_cnt + 1;
            IF s.num <> v_cnt OR (CASE WHEN s.is_reverse THEN s.q ELSE s.b END) <> v_at THEN
                v_ok := false;
                EXIT;
            END IF;
            v_at := CASE WHEN s.is_reverse THEN s.b ELSE s.q END;
            SELECT r."date" AS d, CASE WHEN s.is_reverse THEN 1.0 / r.rate ELSE r.rate END AS step_rate
              INTO x
              FROM currency_pair_rate r
             WHERE r.currency_pair_uuid = s.currency_pair_uuid AND r.deleted_at IS NULL
               AND (r.ledger_id IS NULL OR r.ledger_id = p_ledger) AND r."date" <= p_date
             ORDER BY r."date" DESC, (r.ledger_id IS NULL)
             LIMIT 1;
            IF NOT FOUND THEN
                v_prod := NULL;
            ELSIF v_prod IS NOT NULL THEN
                v_prod := v_prod * x.step_rate;
                v_max := greatest(v_max, x.d);
            END IF;
        END LOOP;
        IF v_ok AND v_cnt = v_n AND v_at = v_rt THEN
            -- структурно валидный маршрут: курс по нему либо есть, либо нет — USD не подставляется
            IF v_prod IS NOT NULL THEN
                rate_date := v_max;
                rate := CASE WHEN v_rf = p_from THEN v_prod ELSE 1.0 / v_prod END;
                RETURN NEXT;
            END IF;
            RETURN;
        END IF;
    END IF;

    -- 2. кросс через USD
    SELECT c.uuid INTO v_usd
      FROM currency c
     WHERE c.iso_code = 'USD' AND c.deleted_at IS NULL
       AND (c.ledger_id IS NULL OR c.ledger_id = p_ledger)
     ORDER BY (c.ledger_id IS NULL)
     LIMIT 1;
    IF v_usd IS NULL OR p_from = v_usd OR p_to = v_usd THEN RETURN; END IF;

    -- Плечи по очереди: нет первого — второе не считаем (оба нужны, иначе курса нет).
    SELECT d."date", d.rate INTO v_ad, v_ar FROM rate_direct(p_ledger, p_from, v_usd, p_date) d;
    IF NOT FOUND THEN RETURN; END IF;
    SELECT d."date", d.rate INTO v_bd, v_br FROM rate_direct(p_ledger, v_usd, p_to, p_date) d;
    IF NOT FOUND THEN RETURN; END IF;
    rate_date := greatest(v_ad, v_bd);
    rate := v_ar * v_br;
    RETURN NEXT;
END
$$;

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
CREATE OR REPLACE FUNCTION rate_on(p_ledger uuid, p_from uuid, p_to uuid, p_date date)
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

GRANT EXECUTE ON FUNCTION rate_direct(uuid, uuid, uuid, date) TO wallet_api, wallet_reader;
