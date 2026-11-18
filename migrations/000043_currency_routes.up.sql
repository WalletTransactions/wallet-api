-- Маршруты пересчёта валют (OpenSpec change currency-conversion-routes).
--
-- currency_conversion меняет смысл: раньше — «переопределение направления пары»
-- (ни один клиент в неё не писал), теперь — ШАГ МАРШРУТА. Маршрут from -> to
-- леджера — это цепочка строк с num = 1..N (N <= 3); каждая строка называет пару
-- и направление шага (is_reverse: 0 — от базовой валюты пары к котируемой, 1 —
-- наоборот). Начало и конец шага выводятся из пары и is_reverse.
--
-- Что делает миграция:
--   1. Ограничения и индексы таблицы под новый смысл (маршруты только леджера,
--      num 1..3, один живой маршрут на неупорядоченную пару валют).
--   2. v_currency_conversion — без подмешивания currency_conversion (раньше
--      строка таблицы подменяла у направления пары currency_pair_uuid; теперь
--      строки таблицы — шаги маршрутов, и такая подмена дала бы неверный курс).
--      v_currency_conversion_rate НЕ меняется: она по-прежнему отдаёт только
--      прямые курсы и тождественный.
--   3. rate_on(ledger, from, to, date) — курс на дату с приоритетом: прямой курс
--      (быстрый индексный путь, как у вьюхи) -> явный маршрут -> кросс через USD.
--      Маршрут и USD считаются только для запрошенной пары и только если прямого
--      курса нет, поэтому прямые курсы стоят столько же, сколько раньше.
--      Вариант «всё в одной вьюхе» отвергнут замером (design.md, «Результат
--      замера»): уровень USD строился по всем парам валют леджера.
--   4. Потребители курса (f_balance_to_date, f_balance_to_dates, f_balance_series,
--      f_debts_for_period, f_assets_for_period, v_operation_eq) переведены с
--      подзапроса к v_currency_conversion_rate на rate_on — тот же результат
--      (дата, курс), порядок «последний не позже даты, свой курс поверх общего»
--      теперь внутри rate_on.
--
-- Данных в currency_conversion нет ни на одном контуре — guard падает, если они
-- вдруг появились: преобразовывать нечего, молча стирать нельзя.

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM currency_conversion) THEN
        RAISE EXCEPTION 'currency_conversion не пуста: миграция 000043 меняет смысл строк и не умеет их преобразовать';
    END IF;
END
$$;

-- 1. Таблица ---------------------------------------------------------------

ALTER TABLE currency_conversion ALTER COLUMN ledger_id SET NOT NULL;

ALTER TABLE currency_conversion DROP CONSTRAINT currency_conversion_num_check;
ALTER TABLE currency_conversion ALTER COLUMN num DROP DEFAULT;
ALTER TABLE currency_conversion
    ADD CONSTRAINT ck_currency_conversion_num CHECK (num BETWEEN 1 AND 3);

-- Общих маршрутов больше нет, индекс общего потока синка не нужен.
DROP INDEX ix_currency_conversion_reference_sync;
DROP INDEX uq_currency_conversion_reference;
DROP INDEX uq_currency_conversion_ledger;

-- Шаг маршрута уникален по (леджер, from, to, num). Любой маршрут содержит
-- num = 1, поэтому второй индекс — по НЕупорядоченной паре валют — ловит и
-- прямой, и обратный дубль маршрута уже на первом шаге.
CREATE UNIQUE INDEX uq_currency_conversion_step
    ON currency_conversion (ledger_id, from_currency_uuid, to_currency_uuid, num)
 WHERE deleted_at IS NULL;

CREATE UNIQUE INDEX uq_currency_conversion_unordered
    ON currency_conversion (ledger_id,
                            LEAST(from_currency_uuid, to_currency_uuid),
                            GREATEST(from_currency_uuid, to_currency_uuid),
                            num)
 WHERE deleted_at IS NULL;

-- Таблица стала LedgerOnly: push резолвит конфликт как ON CONFLICT (ledger_id, uuid),
-- ему нужен именно такой уникальный ключ (у остальных таблиц леджера он первичный).
CREATE UNIQUE INDEX uq_currency_conversion_ledger_uuid
    ON currency_conversion (ledger_id, uuid);

-- Каскад мягкого удаления пары находит шаги по паре.
CREATE INDEX ix_currency_conversion_pair
    ON currency_conversion (currency_pair_uuid)
 WHERE deleted_at IS NULL;

COMMENT ON TABLE currency_conversion IS
    'Шаги маршрутов пересчёта валют леджера: маршрут from -> to — цепочка строк с num = 1..3, каждая называет пару и направление шага. Нужен там, где прямой пары нет.';
COMMENT ON COLUMN currency_conversion.uuid IS 'Идентификатор шага.';
COMMENT ON COLUMN currency_conversion.ledger_id IS 'Леджер-владелец маршрута; общих маршрутов нет.';
COMMENT ON COLUMN currency_conversion.seq IS 'Версия строки в потоке изменений леджера.';
COMMENT ON COLUMN currency_conversion.from_currency_uuid IS 'Валюта, из которой считается весь маршрут (одинакова у всех шагов маршрута).';
COMMENT ON COLUMN currency_conversion.to_currency_uuid IS 'Валюта, в которую считается весь маршрут (одинакова у всех шагов маршрута).';
COMMENT ON COLUMN currency_conversion.num IS 'Номер шага маршрута, 1..3.';
COMMENT ON COLUMN currency_conversion.currency_pair_uuid IS 'Пара, курс которой используется на этом шаге.';
COMMENT ON COLUMN currency_conversion.is_reverse IS
    'false — шаг идёт от базовой валюты пары к котируемой (курс rate), true — наоборот (курс 1/rate).';

-- 2. Направления пар --------------------------------------------------------

CREATE OR REPLACE VIEW v_currency_conversion AS
SELECT fk.ledger_id                 AS ledger_id,
       fc.uuid                      AS from_currency_uuid,
       fc.name                      AS from_currency_name,
       fc.iso_code                  AS from_currency_iso,
       tc.uuid                      AS to_currency_uuid,
       tc.name                      AS to_currency_name,
       tc.iso_code                  AS to_currency_iso,
       fk.currency_pair_uuid        AS currency_pair_uuid,
       fk.num                       AS num,
       fk.is_reverse                AS is_reverse
  FROM (
        SELECT cp.uuid                AS currency_pair_uuid,
               cp.ledger_id,
               cp.base_currency_uuid  AS from_currency_uuid,
               cp.quote_currency_uuid AS to_currency_uuid,
               0::smallint            AS num,
               false                  AS is_reverse
          FROM currency_pair cp
         WHERE cp.deleted_at IS NULL
        UNION ALL
        SELECT cp.uuid,
               cp.ledger_id,
               cp.quote_currency_uuid,
               cp.base_currency_uuid,
               0::smallint,
               true
          FROM currency_pair cp
         WHERE cp.deleted_at IS NULL
       ) fk
  JOIN currency fc
    ON fc.uuid = fk.from_currency_uuid
   AND fc.deleted_at IS NULL
  JOIN currency tc
    ON tc.uuid = fk.to_currency_uuid
   AND tc.deleted_at IS NULL;

-- 3. Курс на дату -----------------------------------------------------------

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
-- составной курс последний раз менялся), как у строки вьюхи.
CREATE FUNCTION rate_fallback(p_ledger uuid, p_from uuid, p_to uuid, p_date date)
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
    s         record;
    x         record;
BEGIN
    -- 0. прямой курс есть (хоть на какую-то дату) — маршрут не применяется
    IF EXISTS (SELECT 1 FROM v_currency_conversion_rate d
                WHERE d.from_currency_uuid = p_from AND d.to_currency_uuid = p_to
                  AND (d.ledger_id IS NULL OR d.ledger_id = p_ledger)) THEN
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

    RETURN QUERY
    SELECT greatest(a."date", b."date"), a.rate * b.rate
      FROM (SELECT rr."date", rr.rate FROM v_currency_conversion_rate rr
             WHERE rr.from_currency_uuid = p_from AND rr.to_currency_uuid = v_usd
               AND rr."date" <= p_date AND (rr.ledger_id IS NULL OR rr.ledger_id = p_ledger)
             ORDER BY rr."date" DESC, (rr.ledger_id IS NULL) LIMIT 1) a,
           (SELECT rr."date", rr.rate FROM v_currency_conversion_rate rr
             WHERE rr.from_currency_uuid = v_usd AND rr.to_currency_uuid = p_to
               AND rr."date" <= p_date AND (rr.ledger_id IS NULL OR rr.ledger_id = p_ledger)
             ORDER BY rr."date" DESC, (rr.ledger_id IS NULL) LIMIT 1) b;
END
$$;

-- Курс from -> to леджера на дату: последний не позже даты, при равных датах
-- курс леджера поверх общего. Приоритет источников: прямой курс (вьюха) ->
-- явный маршрут -> кросс через USD. Нет курса — ни одной строки (пересчёта 1:1
-- нет). SQL-функция: инлайнится в запрос потребителя, ветка rate_fallback
-- вычисляется только если прямого курса не нашлось (LIMIT 1 останавливает Append).
CREATE FUNCTION rate_on(p_ledger uuid, p_from uuid, p_to uuid, p_date date)
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

-- 4. Потребители ------------------------------------------------------------

-- Функции отчётов переписываются по тексту: в каждой ровно один (или два, как у
-- f_balance_series/f_balance_to_dates — по числу подзапросов) одинаковый по форме
-- подзапрос «последний курс не позже даты». Число замен проверяется — если форма
-- разошлась, миграция падает, а не пропускает потребителя молча.
DO $$
DECLARE
    -- from, to, date, ledger — каждое выражение на своей строке.
    pattern text := 'FROM v_currency_conversion_rate rr\s+'
                    'WHERE rr\.from_currency_uuid = ([^\n]+)\s+'
                    'AND rr\.to_currency_uuid\s+= ([^\n]+)\s+'
                    'AND rr\."date"\s+<= ([^\n]+)\s+'
                    'AND \(rr\.ledger_id IS NULL OR rr\.ledger_id = ([^\n)]+)\)\s+'
                    'ORDER BY rr\."date" DESC, \(rr\.ledger_id IS NULL\)\s+'
                    'LIMIT 1';
    fn      text;
    expected int;
    r       record;
    def     text;
    patched text;
    found   int;
BEGIN
    FOR fn, expected IN VALUES ('f_balance_to_date', 1), ('f_balance_to_dates', 1),
                               ('f_balance_series', 1), ('f_debts_for_period', 1),
                               ('f_assets_for_period', 1)
    LOOP
        found := 0;
        FOR r IN SELECT p.oid FROM pg_proc p
                  WHERE p.proname = fn AND p.pronamespace = 'public'::regnamespace
        LOOP
            def := pg_get_functiondef(r.oid);
            patched := regexp_replace(def, pattern, 'FROM rate_on(\4, \1, \2, \3) rr', 'g');
            IF patched <> def THEN
                found := found + 1;
                EXECUTE patched;
            END IF;
        END LOOP;
        IF found <> expected THEN
            RAISE EXCEPTION 'миграция 000043: в % нашлось % подзапросов курса вместо %', fn, found, expected;
        END IF;
    END LOOP;
END
$$;

CREATE OR REPLACE VIEW v_operation_eq AS
SELECT o.ledger_id,
       o.uuid,
       o."date",
       o.acc_fr_uuid,
       o.acc_to_uuid,
       o.amount,
       o.comment,
       o.acc_fr_name,
       o.acc_to_name,
       o.acc_from_is_operating,
       o.acc_to_is_operating,
       o.currency_uuid,
       tc.uuid                                   AS to_currency_uuid,
       r."date"                                  AS max_date_rate,
       r.rate,
       round(r.rate * o.amount, tc."precision")  AS amount_eq
  FROM v_operation o
  CROSS JOIN LATERAL (
        SELECT c.uuid, c."precision"
          FROM currency c
         WHERE c.deleted_at IS NULL
           AND (c.ledger_id IS NULL OR c.ledger_id = o.ledger_id)
       ) tc
  LEFT JOIN LATERAL (
        SELECT rr."date", rr.rate
          FROM rate_on(o.ledger_id, o.currency_uuid, tc.uuid, o."date"::date) rr
       ) r ON true;

GRANT EXECUTE ON FUNCTION rate_fallback(uuid, uuid, uuid, date) TO wallet_api, wallet_reader;
GRANT EXECUTE ON FUNCTION rate_on(uuid, uuid, uuid, date) TO wallet_api, wallet_reader;
