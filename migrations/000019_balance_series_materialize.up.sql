-- Правка 000018_balance_series_incremental.up.sql — по прямому запросу
-- (проверка на РЕАЛЬНЫХ данных ленджера через EXPLAIN ANALYZE, 2026-09-12):
-- f_balance_series на 2.7 года дневным шагом (986 бакетов, 51 счёт, 12 валют)
-- у пользователя выполнялась 9.5-14 СЕКУНД — вместо ожидаемого рывка вниз.
-- Причина — ДВЕ вещи, которых сама по себе "кумулятивная сумма одним окном"
-- (000018) не решает:
--
-- 1. CTE running (без MATERIALIZED) — планировщик встроил её как обычный
--    подзапрос и, встретив JOIN running r ON vao.uuid = r.account_uuid,
--    выбрал Nested Loop: ПЕРЕСЧИТЫВАЛ ВСЮ running (окно по ВСЕМ счетам)
--    ЗАНОВО на каждый из 51 счёта (EXPLAIN: "loops=51" на CTE Scan) — то
--    самое "квадратичное по счетам", от которого 000018 должна была уйти,
--    просто переехавшее в другое место плана. WITH ... AS MATERIALIZED
--    заставляет Postgres посчитать её РОВНО ОДИН РАЗ и заджойнить результат
--    честным Hash Join.
--
-- 2. Резолв курса (LEFT JOIN LATERAL v_currency_conversion_rate) — тот же
--    приём, что и в 000018 (и в f_balance_to_date/wallet_turnover и т.д. по
--    всему проекту), но здесь он выполнялся на КАЖДУЮ строку (счёт, бакет) —
--    48645 раз для 51 счёта, хотя ставка зависит только от (валюта, бакет),
--    а РАЗНЫХ валют у счетов обычно в разы меньше, чем самих счетов (в этом
--    леджере — 12 валют на 51 счёт). Здесь курс считается ОДИН раз на пару
--    (бакет, валюта) в отдельном MATERIALIZED CTE и подмешивается обратно
--    JOIN'ом — вместо 48645 резолвов курса на этом леджере получилось 986×12.
--
-- Итог на тех же данных: 9.5-14с -> ~0.7с. Сама формула баланса и вся
-- логика "было ли движение"/"строго до" из 000018 не меняются — правка
-- только в ЭТИХ двух местах.
CREATE OR REPLACE FUNCTION f_balance_to_dates(
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
    WITH dates AS (
        SELECT d.idx::integer AS idx, d.balance_date
          FROM unnest(p_dates) WITH ORDINALITY AS d(balance_date, idx)
    ),
    events AS (
        SELECT vao.uuid AS account_uuid, o."date" AS event_at, o.amount AS delta,
               false AS is_checkpoint, NULL::integer AS idx
          FROM v_account_operating vao
          JOIN operation o
            ON o.ledger_id = p_ledger_id
           AND o.deleted_at IS NULL
           AND o.acc_to_uuid = vao.uuid
         WHERE vao.ledger_id = p_ledger_id
        UNION ALL
        SELECT vao.uuid, o."date", -o.amount, false, NULL::integer
          FROM v_account_operating vao
          JOIN operation o
            ON o.ledger_id = p_ledger_id
           AND o.deleted_at IS NULL
           AND o.acc_fr_uuid = vao.uuid
         WHERE vao.ledger_id = p_ledger_id
        UNION ALL
        SELECT vao.uuid, d.balance_date, 0, true, d.idx
          FROM v_account_operating vao
          CROSS JOIN dates d
         WHERE vao.ledger_id = p_ledger_id
    ),
    -- MATERIALIZED — см. шапку файла, пункт 1: без него Postgres пересчитывал
    -- бы это окно заново на каждый счёт при джойне ниже.
    running AS MATERIALIZED (
        SELECT account_uuid, is_checkpoint, idx,
               sum(delta) OVER w AS cum,
               count(*) FILTER (WHERE NOT is_checkpoint) OVER w AS ops_before
          FROM events
          WINDOW w AS (
              PARTITION BY account_uuid
              ORDER BY event_at, is_checkpoint DESC
              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
          )
    ),
    -- Курс — на пару (дата, валюта), не (дата, счёт): см. шапку файла,
    -- пункт 2. Разных валют среди счетов леджера обычно заметно меньше, чем
    -- самих счетов.
    date_rates AS MATERIALIZED (
        SELECT d.idx, c.uuid AS currency_uuid,
               (SELECT rr.rate
                  FROM v_currency_conversion_rate rr
                 WHERE rr.from_currency_uuid = c.uuid
                   AND rr.to_currency_uuid   = p_eq_currency
                   AND rr."date"            <= d.balance_date::date
                   AND (rr.ledger_id IS NULL OR rr.ledger_id = p_ledger_id)
                 ORDER BY rr."date" DESC, (rr.ledger_id IS NULL)
                 LIMIT 1) AS rate
          FROM dates d
          CROSS JOIN (
                SELECT DISTINCT currency_uuid FROM v_account_operating WHERE ledger_id = p_ledger_id
               ) vc
          JOIN currency c ON c.uuid = vc.currency_uuid AND c.deleted_at IS NULL
    ),
    acct_bal AS (
        SELECT r.idx,
               vao.uuid AS account_uuid,
               vao.name AS account_name,
               c.uuid   AS currency_uuid,
               c.symbol,
               c."precision",
               round(r.cum, c."precision") AS balance,
               round(dr.rate * r.cum,
                     (SELECT eq."precision" FROM currency eq WHERE eq.uuid = p_eq_currency)) AS eq_value
          FROM running r
          JOIN v_account_operating vao ON vao.uuid = r.account_uuid
          JOIN currency c
            ON c.uuid = vao.currency_uuid
           AND c.deleted_at IS NULL
          LEFT JOIN date_rates dr ON dr.idx = r.idx AND dr.currency_uuid = c.uuid
         WHERE r.is_checkpoint
           AND r.ops_before > 0
    )
    SELECT ab.idx,
           ab.account_uuid,
           ab.account_name,
           ab.currency_uuid,
           ab.symbol,
           ab."precision",
           ab.balance,
           ab.eq_value
      FROM acct_bal ab
     ORDER BY ab.idx, ab.eq_value DESC NULLS LAST;
$$;

-- Сигнатура и RETURNS TABLE не меняются, GRANT из 000011 трогать не нужно.

CREATE OR REPLACE FUNCTION f_balance_series(
    p_ledger_id   uuid,
    p_from        date,
    p_to          date,
    p_step        text,
    p_eq_currency uuid
) RETURNS TABLE (
    date_index    integer,
    bucket_start  date,
    bucket_end    date,
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
    WITH step AS (
        SELECT CASE p_step
                   WHEN 'day'   THEN interval '1 day'
                   WHEN 'week'  THEN interval '7 days'
                   WHEN 'month' THEN interval '1 month'
                   WHEN 'year'  THEN interval '1 year'
               END AS unit,
               CASE p_step
                   WHEN 'day'   THEN p_from
                   WHEN 'week'  THEN p_from - (extract(isodow FROM p_from)::int - 1)
                   WHEN 'month' THEN date_trunc('month', p_from)::date
                   WHEN 'year'  THEN date_trunc('year', p_from)::date
               END AS first_start
    ),
    buckets AS (
        SELECT gs.bucket_start::date AS bucket_start,
               LEAST((gs.bucket_start + step.unit - interval '1 day')::date, p_to) AS bucket_end,
               row_number() OVER (ORDER BY gs.bucket_start)::integer AS idx
          FROM step
          CROSS JOIN LATERAL generate_series(step.first_start, p_to, step.unit) AS gs(bucket_start)
    ),
    events AS (
        SELECT vao.uuid AS account_uuid, o."date" AS event_at, o.amount AS delta,
               false AS is_checkpoint, NULL::integer AS idx
          FROM v_account_operating vao
          JOIN operation o
            ON o.ledger_id = p_ledger_id
           AND o.deleted_at IS NULL
           AND o.acc_to_uuid = vao.uuid
         WHERE vao.ledger_id = p_ledger_id
        UNION ALL
        SELECT vao.uuid, o."date", -o.amount, false, NULL::integer
          FROM v_account_operating vao
          JOIN operation o
            ON o.ledger_id = p_ledger_id
           AND o.deleted_at IS NULL
           AND o.acc_fr_uuid = vao.uuid
         WHERE vao.ledger_id = p_ledger_id
        UNION ALL
        SELECT vao.uuid, (b.bucket_end + 1)::timestamp, 0, true, b.idx
          FROM v_account_operating vao
          CROSS JOIN buckets b
         WHERE vao.ledger_id = p_ledger_id
    ),
    -- MATERIALIZED — см. шапку файла, пункт 1.
    running AS MATERIALIZED (
        SELECT account_uuid, is_checkpoint, idx,
               sum(delta) OVER w AS cum,
               count(*) FILTER (WHERE NOT is_checkpoint) OVER w AS ops_before
          FROM events
          WINDOW w AS (
              PARTITION BY account_uuid
              ORDER BY event_at, is_checkpoint DESC
              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
          )
    ),
    -- Курс — на пару (бакет, валюта), не (бакет, счёт): см. шапку файла,
    -- пункт 2.
    bucket_rates AS MATERIALIZED (
        SELECT bk.idx, c.uuid AS currency_uuid,
               (SELECT rr.rate
                  FROM v_currency_conversion_rate rr
                 WHERE rr.from_currency_uuid = c.uuid
                   AND rr.to_currency_uuid   = p_eq_currency
                   AND rr."date"            <= bk.bucket_end
                   AND (rr.ledger_id IS NULL OR rr.ledger_id = p_ledger_id)
                 ORDER BY rr."date" DESC, (rr.ledger_id IS NULL)
                 LIMIT 1) AS rate
          FROM buckets bk
          CROSS JOIN (
                SELECT DISTINCT currency_uuid FROM v_account_operating WHERE ledger_id = p_ledger_id
               ) vc
          JOIN currency c ON c.uuid = vc.currency_uuid AND c.deleted_at IS NULL
    ),
    acct_bal AS (
        SELECT r.idx,
               vao.uuid AS account_uuid,
               vao.name AS account_name,
               c.uuid   AS currency_uuid,
               c.symbol,
               c."precision",
               round(r.cum, c."precision") AS balance,
               round(br.rate * r.cum,
                     (SELECT eq."precision" FROM currency eq WHERE eq.uuid = p_eq_currency)) AS eq_value
          FROM running r
          JOIN v_account_operating vao ON vao.uuid = r.account_uuid
          JOIN currency c
            ON c.uuid = vao.currency_uuid
           AND c.deleted_at IS NULL
          JOIN buckets bk ON bk.idx = r.idx
          LEFT JOIN bucket_rates br ON br.idx = bk.idx AND br.currency_uuid = c.uuid
         WHERE r.is_checkpoint
           AND r.ops_before > 0
    )
    SELECT b.idx,
           b.bucket_start,
           b.bucket_end,
           ab.account_uuid,
           ab.account_name,
           ab.currency_uuid,
           ab.symbol,
           ab."precision",
           ab.balance,
           ab.eq_value
      FROM buckets b
      LEFT JOIN acct_bal ab ON ab.idx = b.idx
     ORDER BY b.idx, ab.eq_value DESC NULLS LAST;
$$;

-- Сигнатура и RETURNS TABLE не меняются, GRANT из 000017 трогать не нужно.
