-- Откат 000019_balance_series_materialize.up.sql — возвращает тела
-- f_balance_to_dates/f_balance_series к состоянию 000018_balance_series_incremental.up.sql
-- (кумулятивная сумма без MATERIALIZED и без дедупликации курса по валюте).
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
    running AS (
        SELECT account_uuid, event_at, is_checkpoint, idx,
               sum(delta) OVER w AS cum,
               count(*) FILTER (WHERE NOT is_checkpoint) OVER w AS ops_before
          FROM events
          WINDOW w AS (
              PARTITION BY account_uuid
              ORDER BY event_at, is_checkpoint DESC
              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
          )
    ),
    acct_bal AS (
        SELECT r.idx,
               vao.uuid AS account_uuid,
               vao.name AS account_name,
               c.uuid   AS currency_uuid,
               c.symbol,
               c."precision",
               round(r.cum, c."precision") AS balance,
               round(rate.rate * r.cum,
                     (SELECT eq."precision" FROM currency eq WHERE eq.uuid = p_eq_currency)) AS eq_value
          FROM running r
          JOIN v_account_operating vao ON vao.uuid = r.account_uuid
          JOIN currency c
            ON c.uuid = vao.currency_uuid
           AND c.deleted_at IS NULL
          LEFT JOIN LATERAL (
                SELECT rr.rate
                  FROM v_currency_conversion_rate rr
                 WHERE rr.from_currency_uuid = c.uuid
                   AND rr.to_currency_uuid   = p_eq_currency
                   AND rr."date"            <= r.event_at::date
                   AND (rr.ledger_id IS NULL OR rr.ledger_id = p_ledger_id)
                 ORDER BY rr."date" DESC, (rr.ledger_id IS NULL)
                 LIMIT 1
               ) rate ON true
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
    running AS (
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
    acct_bal AS (
        SELECT r.idx,
               vao.uuid AS account_uuid,
               vao.name AS account_name,
               c.uuid   AS currency_uuid,
               c.symbol,
               c."precision",
               round(r.cum, c."precision") AS balance,
               round(rate.rate * r.cum,
                     (SELECT eq."precision" FROM currency eq WHERE eq.uuid = p_eq_currency)) AS eq_value
          FROM running r
          JOIN v_account_operating vao ON vao.uuid = r.account_uuid
          JOIN currency c
            ON c.uuid = vao.currency_uuid
           AND c.deleted_at IS NULL
          JOIN buckets bk ON bk.idx = r.idx
          LEFT JOIN LATERAL (
                SELECT rr.rate
                  FROM v_currency_conversion_rate rr
                 WHERE rr.from_currency_uuid = c.uuid
                   AND rr.to_currency_uuid   = p_eq_currency
                   AND rr."date"            <= bk.bucket_end
                   AND (rr.ledger_id IS NULL OR rr.ledger_id = p_ledger_id)
                 ORDER BY rr."date" DESC, (rr.ledger_id IS NULL)
                 LIMIT 1
               ) rate ON true
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
