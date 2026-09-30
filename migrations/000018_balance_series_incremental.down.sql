-- Откат 000018_balance_series_incremental.up.sql — возвращает тела
-- f_balance_to_dates/f_balance_series к состоянию 000011_balance_to_dates.up.sql
-- и 000017_balance_series.up.sql соответственно (наивный пересчёт SUM(...)
-- WHERE date < X на каждую дату/бакет заново).
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
    SELECT d.idx::integer,
           vao.uuid,
           vao.name,
           c.uuid,
           c.symbol,
           c."precision",
           round(coalesce(opt.amount_to, 0) - coalesce(opf.amount_fr, 0), c."precision"),
           round(r.rate * (coalesce(opt.amount_to, 0) - coalesce(opf.amount_fr, 0)),
                 (SELECT eq."precision" FROM currency eq WHERE eq.uuid = p_eq_currency))
               AS eq_value
      FROM unnest(p_dates) WITH ORDINALITY AS d(balance_date, idx)
      CROSS JOIN v_account_operating vao
      JOIN currency c
        ON c.uuid = vao.currency_uuid
       AND c.deleted_at IS NULL
      LEFT JOIN LATERAL (
            SELECT sum(o.amount) AS amount_to
              FROM operation o
             WHERE o.ledger_id = p_ledger_id
               AND o.deleted_at IS NULL
               AND o.acc_to_uuid = vao.uuid
               AND o."date" < d.balance_date
           ) opt ON true
      LEFT JOIN LATERAL (
            SELECT sum(o.amount) AS amount_fr
              FROM operation o
             WHERE o.ledger_id = p_ledger_id
               AND o.deleted_at IS NULL
               AND o.acc_fr_uuid = vao.uuid
               AND o."date" < d.balance_date
           ) opf ON true
      LEFT JOIN LATERAL (
            SELECT rr."date", rr.rate
              FROM v_currency_conversion_rate rr
             WHERE rr.from_currency_uuid = c.uuid
               AND rr.to_currency_uuid   = p_eq_currency
               AND rr."date"            <= d.balance_date::date
               AND (rr.ledger_id IS NULL OR rr.ledger_id = p_ledger_id)
             ORDER BY rr."date" DESC, (rr.ledger_id IS NULL)
             LIMIT 1
           ) r ON true
     WHERE vao.ledger_id = p_ledger_id
       AND (opt.amount_to IS NOT NULL OR opf.amount_fr IS NOT NULL)
     ORDER BY d.idx, eq_value DESC NULLS LAST;
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
    acct_bal AS (
        SELECT b.idx,
               vao.uuid AS account_uuid,
               vao.name AS account_name,
               c.uuid   AS currency_uuid,
               c.symbol,
               c."precision",
               round(coalesce(opt.amount_to, 0) - coalesce(opf.amount_fr, 0), c."precision") AS balance,
               round(r.rate * (coalesce(opt.amount_to, 0) - coalesce(opf.amount_fr, 0)),
                     (SELECT eq."precision" FROM currency eq WHERE eq.uuid = p_eq_currency)) AS eq_value
          FROM buckets b
          CROSS JOIN v_account_operating vao
          JOIN currency c
            ON c.uuid = vao.currency_uuid
           AND c.deleted_at IS NULL
          LEFT JOIN LATERAL (
                SELECT sum(o.amount) AS amount_to
                  FROM operation o
                 WHERE o.ledger_id = p_ledger_id
                   AND o.deleted_at IS NULL
                   AND o.acc_to_uuid = vao.uuid
                   AND o."date" < (b.bucket_end + 1)::timestamp
               ) opt ON true
          LEFT JOIN LATERAL (
                SELECT sum(o.amount) AS amount_fr
                  FROM operation o
                 WHERE o.ledger_id = p_ledger_id
                   AND o.deleted_at IS NULL
                   AND o.acc_fr_uuid = vao.uuid
                   AND o."date" < (b.bucket_end + 1)::timestamp
               ) opf ON true
          LEFT JOIN LATERAL (
                SELECT rr.rate
                  FROM v_currency_conversion_rate rr
                 WHERE rr.from_currency_uuid = c.uuid
                   AND rr.to_currency_uuid   = p_eq_currency
                   AND rr."date"            <= b.bucket_end
                   AND (rr.ledger_id IS NULL OR rr.ledger_id = p_ledger_id)
                 ORDER BY rr."date" DESC, (rr.ledger_id IS NULL)
                 LIMIT 1
               ) r ON true
         WHERE vao.ledger_id = p_ledger_id
           AND (opt.amount_to IS NOT NULL OR opf.amount_fr IS NOT NULL)
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
