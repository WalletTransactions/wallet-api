-- capital-assets (wallet-api/openspec/changes/capital-assets): капитальные
-- активы (квартира, машина, прочее) и их переоценка.
--
-- 1. account_asset — признак актива у кошелька, синхронизируемая таблица
--    потока ledger (design D1/D2); GRANT SELECT роли wallet_reader — для
--    LEFT JOIN в wallet-report (/wallet-turnover, /accounts).
-- 2. account.system_kind = 3 — системная категория «Переоценка».
-- 3. v_account_operating отдаёт asset_type/include_in_net_worth (D4), а
--    f_balance_to_date/f_balance_to_dates/f_balance_series — те же две колонки
--    в конце RETURNS TABLE (DROP + CREATE + GRANT: DROP снимает привилегии).
-- 4. Переоценка — проводка, одна из сторон которой счёт с system_kind = 3, —
--    исключается из дохода/расхода/оборотов (D5) одним и тем же предикатом
--    NOT EXISTS (... r.system_kind = 3) без фильтра deleted_at; лента отдаёт
--    ей kind = 'revaluation' (D6), сальдо f_operations_total её не считает.
--    f_expense_by_category_by_month (000030) добавлена к шести функциям
--    design: тот же расход, иначе цифры разъехались бы.
-- 5. f_assets_for_period — отчёт «Капитал» (D7).
--
-- Источники прежних определений: v_account_operating — 000002;
-- f_balance_to_date — 000002; f_balance_to_dates, f_balance_series — 000019;
-- f_income_for_period, f_expanse_for_period — 000015;
-- f_expanse_by_category_for_period — 000030; f_expense_by_category_by_month —
-- 000031; f_income_expense_by_month, f_expense_by_weekday_for_period — 000006;
-- f_wallet_turnover_for_period — 000021; f_operations_for_period,
-- f_operations_total — 000032. Читаемые зеркала — schema/table/account_asset.sql,
-- schema/view/v_account_operating.sql, schema/function/*.sql.

CREATE TABLE account_asset (
    uuid          uuid        NOT NULL,
    ledger_id     uuid        NOT NULL,
    seq           bigint      NOT NULL,
    deleted_at    timestamptz,
    updated_at    timestamptz NOT NULL DEFAULT now(),
    updated_by    uuid REFERENCES device (id) ON DELETE SET NULL,

    asset_type           smallint NOT NULL CHECK (asset_type IN (1, 2, 3)),
    include_in_net_worth boolean  NOT NULL DEFAULT true,
    comment              text     NOT NULL DEFAULT '',

    CONSTRAINT pk_account_asset PRIMARY KEY (ledger_id, uuid),
    CONSTRAINT fk_account_asset_account_operating
        FOREIGN KEY (ledger_id, uuid) REFERENCES account_operating (ledger_id, uuid) ON DELETE CASCADE
);

CREATE INDEX ix_account_asset_sync ON account_asset (ledger_id, seq);

CREATE TRIGGER trg_account_asset_updated_at BEFORE UPDATE ON account_asset
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE account_asset IS
    'Признак капитального актива у кошелька: живая строка — кошелёк является активом (недвижимость, авто, прочее). uuid всегда равен account.uuid и account_operating.uuid.';
COMMENT ON COLUMN account_asset.uuid IS '= account_operating.uuid того же кошелька.';
COMMENT ON COLUMN account_asset.ledger_id IS '= account_operating.ledger_id того же кошелька.';
COMMENT ON COLUMN account_asset.seq IS 'Версия строки в потоке изменений леджера — своя, отдельная от account.seq.';
COMMENT ON COLUMN account_asset.deleted_at IS
    'Момент мягкого удаления (снятие признака актива); NULL — кошелёк является активом.';
COMMENT ON COLUMN account_asset.updated_at IS 'Момент последнего изменения строки — только диагностика.';
COMMENT ON COLUMN account_asset.updated_by IS 'Устройство, применившее последнее изменение этой строки.';
COMMENT ON COLUMN account_asset.asset_type IS 'Тип актива: 1 = недвижимость, 2 = авто, 3 = прочее.';
COMMENT ON COLUMN account_asset.include_in_net_worth IS
    'Входит ли оценка актива в итог «всего с капиталом» (net_worth_eq в wallet-report).';
COMMENT ON COLUMN account_asset.comment IS 'Свободный комментарий к активу (адрес, VIN и т. п.).';

GRANT SELECT ON account_asset TO wallet_reader;

ALTER TABLE account DROP CONSTRAINT account_system_kind_check;
ALTER TABLE account ADD CONSTRAINT account_system_kind_check CHECK (system_kind IN (0, 1, 2, 3));
COMMENT ON COLUMN account.system_kind IS
    'Явный признак системной категории вместо распознавания по name: 0 = обычная, 1 = Transfer, 2 = Transfer commission, 3 = Revaluation — переоценка капитального актива, миграция 000033 (см. AccountItem.SystemKind на клиенте).';

-- Новые колонки — в конце: CREATE OR REPLACE VIEW это допускает.
CREATE OR REPLACE VIEW v_account_operating AS
SELECT a.uuid, a.ledger_id, a.name, a.comment, a.icon_uuid, a.is_archived, ao.currency_uuid,
       aa.asset_type, aa.include_in_net_worth
  FROM account a
  JOIN account_operating ao
    ON ao.ledger_id = a.ledger_id
   AND ao.uuid      = a.uuid
  LEFT JOIN account_asset aa
    ON aa.ledger_id  = a.ledger_id
   AND aa.uuid       = a.uuid
   AND aa.deleted_at IS NULL
 WHERE a.deleted_at IS NULL
   AND ao.deleted_at IS NULL;

-- Балансовые функции: новые колонки в конце RETURNS TABLE.
DROP FUNCTION f_balance_to_date(uuid, timestamp, uuid);

CREATE FUNCTION f_balance_to_date(
    p_ledger_id   uuid,
    p_date        timestamp,
    p_eq_currency uuid
) RETURNS TABLE (
    account_uuid  uuid,
    account_name  text,
    currency_uuid uuid,
    symbol        text,
    "precision"   smallint,
    balance       numeric,
    balance_eq    numeric,
    -- capital-assets (000033): признак актива из v_account_operating; NULL —
    -- ликвидный кошелёк (и пустой бакет f_balance_series).
    asset_type           smallint,
    include_in_net_worth boolean
)
    LANGUAGE sql
    STABLE
    PARALLEL SAFE
AS $$
    SELECT vao.uuid,
           vao.name,
           c.uuid,
           c.symbol,
           c."precision",
           round(coalesce(opt.amount_to, 0) - coalesce(opf.amount_fr, 0), c."precision"),
           round(r.rate * (coalesce(opt.amount_to, 0) - coalesce(opf.amount_fr, 0)),
                 (SELECT eq."precision" FROM currency eq WHERE eq.uuid = p_eq_currency))
               AS eq_value,
           vao.asset_type,
           vao.include_in_net_worth
      FROM v_account_operating vao
      JOIN currency c
        ON c.uuid = vao.currency_uuid
       AND c.deleted_at IS NULL
      LEFT JOIN (
            SELECT o.acc_to_uuid, sum(o.amount) AS amount_to
              FROM operation o
             WHERE o.ledger_id = p_ledger_id
               AND o.deleted_at IS NULL
               AND o."date" < p_date
             GROUP BY o.acc_to_uuid
           ) opt ON opt.acc_to_uuid = vao.uuid
      LEFT JOIN (
            SELECT o.acc_fr_uuid, sum(o.amount) AS amount_fr
              FROM operation o
             WHERE o.ledger_id = p_ledger_id
               AND o.deleted_at IS NULL
               AND o."date" < p_date
             GROUP BY o.acc_fr_uuid
           ) opf ON opf.acc_fr_uuid = vao.uuid
      LEFT JOIN LATERAL (
            SELECT rr.rate
              FROM v_currency_conversion_rate rr
             WHERE rr.from_currency_uuid = c.uuid
               AND rr.to_currency_uuid   = p_eq_currency
               AND rr."date"            <= p_date::date
               AND (rr.ledger_id IS NULL OR rr.ledger_id = p_ledger_id)
             ORDER BY rr."date" DESC, (rr.ledger_id IS NULL)
             LIMIT 1
           ) r ON true
     WHERE vao.ledger_id = p_ledger_id
       AND (opt.acc_to_uuid IS NOT NULL OR opf.acc_fr_uuid IS NOT NULL)
     ORDER BY eq_value DESC NULLS LAST;
$$;

GRANT EXECUTE ON FUNCTION f_balance_to_date(uuid, timestamp, uuid) TO wallet_reader;

DROP FUNCTION f_balance_to_dates(uuid, timestamp[], uuid);

CREATE FUNCTION f_balance_to_dates(
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
    balance_eq    numeric,
    -- capital-assets (000033): признак актива из v_account_operating; NULL —
    -- ликвидный кошелёк (и пустой бакет f_balance_series).
    asset_type           smallint,
    include_in_net_worth boolean
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
    -- MATERIALIZED — см. шапку файла, "ДОБАВЛЕНО В 000019" пункт 1.
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
    -- "ДОБАВЛЕНО В 000019" пункт 2.
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
                     (SELECT eq."precision" FROM currency eq WHERE eq.uuid = p_eq_currency)) AS eq_value,
               vao.asset_type,
               vao.include_in_net_worth
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
           ab.eq_value,
           ab.asset_type,
           ab.include_in_net_worth
      FROM acct_bal ab
     ORDER BY ab.idx, ab.eq_value DESC NULLS LAST;
$$;

GRANT EXECUTE ON FUNCTION f_balance_to_dates(uuid, timestamp[], uuid) TO wallet_reader;

DROP FUNCTION f_balance_series(uuid, date, date, text, uuid);

CREATE FUNCTION f_balance_series(
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
    balance_eq    numeric,
    -- capital-assets (000033): признак актива из v_account_operating; NULL —
    -- ликвидный кошелёк (и пустой бакет f_balance_series).
    asset_type           smallint,
    include_in_net_worth boolean
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
    -- MATERIALIZED — см. шапку файла, "ДОБАВЛЕНО В 000019" пункт 1.
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
    -- "ДОБАВЛЕНО В 000019" пункт 2.
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
                     (SELECT eq."precision" FROM currency eq WHERE eq.uuid = p_eq_currency)) AS eq_value,
               vao.asset_type,
               vao.include_in_net_worth
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
           ab.eq_value,
           ab.asset_type,
           ab.include_in_net_worth
      FROM buckets b
      LEFT JOIN acct_bal ab ON ab.idx = b.idx
     ORDER BY b.idx, ab.eq_value DESC NULLS LAST;
$$;

GRANT EXECUTE ON FUNCTION f_balance_series(uuid, date, date, text, uuid) TO wallet_reader;

-- Сигнатуры не меняются — CREATE OR REPLACE, гранты сохраняются.

CREATE OR REPLACE FUNCTION f_income_for_period(
    p_ledger_id   uuid,
    p_from        timestamp,
    p_to          timestamp,
    p_eq_currency uuid
) RETURNS TABLE (
    account_uuid  uuid,
    account_name  text,
    currency_uuid uuid,
    amount        numeric,
    amount_eq     numeric
)
    LANGUAGE sql
    STABLE
    PARALLEL SAFE
AS $$
    WITH transfer_net AS (
        -- credit-нога (Transfer -> кошелёк) минус debit-нога (кошелёк -> Transfer) —
        -- обе ноги одного и того же перевода, см. комментарий выше/f_expanse_for_period.sql.
        SELECT sum(CASE WHEN ol.link_uuid = o.uuid THEN o.amount_eq ELSE -o.amount_eq END) AS net
          FROM v_operation_eq o
          JOIN operation_link ol
            ON ol.ledger_id = p_ledger_id
           AND (ol.main_uuid = o.uuid OR ol.link_uuid = o.uuid)
           AND ol.type = 0
           AND ol.deleted_at IS NULL
         WHERE o.ledger_id        = p_ledger_id
           AND o.to_currency_uuid = p_eq_currency
           AND o."date" BETWEEN p_from AND p_to
    )
    SELECT o.acc_fr_uuid,
           o.acc_fr_name,
           o.currency_uuid,
           round(sum(o.amount),    max(c."precision")),
           round(sum(o.amount_eq), max(eq."precision"))
               AS eq_value
      FROM v_operation_eq o
      JOIN currency c  ON c.uuid  = o.currency_uuid
      JOIN currency eq ON eq.uuid = p_eq_currency
     WHERE o.ledger_id        = p_ledger_id
       AND o.to_currency_uuid = p_eq_currency
       AND o."date" BETWEEN p_from AND p_to
       AND o.acc_to_is_operating
       AND NOT o.acc_from_is_operating
       AND NOT EXISTS (
               SELECT 1 FROM operation_link ol
                WHERE ol.ledger_id = p_ledger_id AND ol.link_uuid = o.uuid
                  AND ol.type = 0 AND ol.deleted_at IS NULL
           )
       -- Переоценка актива — не доход (capital-assets, 000033): сторона с
       -- system_kind = 3, без фильтра deleted_at.
       AND NOT EXISTS (
               SELECT 1 FROM account r
                WHERE r.ledger_id = p_ledger_id
                  AND r.uuid IN (o.acc_fr_uuid, o.acc_to_uuid)
                  AND r.system_kind = 3
           )
     GROUP BY o.acc_fr_uuid, o.acc_fr_name, o.currency_uuid

    UNION ALL

    SELECT a.uuid, a.name, p_eq_currency,
           round(tn.net, eq."precision"), round(tn.net, eq."precision")
      FROM transfer_net tn
      JOIN account  a  ON a.ledger_id = p_ledger_id AND a.system_kind = 1 AND a.deleted_at IS NULL
      JOIN currency eq ON eq.uuid = p_eq_currency
     WHERE tn.net > 0

     ORDER BY eq_value DESC NULLS LAST;
$$;

CREATE OR REPLACE FUNCTION f_expanse_for_period(
    p_ledger_id   uuid,
    p_from        timestamp,
    p_to          timestamp,
    p_eq_currency uuid
) RETURNS TABLE (
    account_uuid  uuid,
    account_name  text,
    currency_uuid uuid,
    amount        numeric,
    amount_eq     numeric
)
    LANGUAGE sql
    STABLE
    PARALLEL SAFE
AS $$
    WITH transfer_net AS (
        -- credit-нога (Transfer -> кошелёк) минус debit-нога (кошелёк -> Transfer) —
        -- обе ноги одного и того же перевода, см. комментарий выше.
        SELECT sum(CASE WHEN ol.link_uuid = o.uuid THEN o.amount_eq ELSE -o.amount_eq END) AS net
          FROM v_operation_eq o
          JOIN operation_link ol
            ON ol.ledger_id = p_ledger_id
           AND (ol.main_uuid = o.uuid OR ol.link_uuid = o.uuid)
           AND ol.type = 0
           AND ol.deleted_at IS NULL
         WHERE o.ledger_id        = p_ledger_id
           AND o.to_currency_uuid = p_eq_currency
           AND o."date" BETWEEN p_from AND p_to
    )
    SELECT o.acc_to_uuid,
           o.acc_to_name,
           o.currency_uuid,
           round(sum(o.amount),    max(c."precision")),
           round(sum(o.amount_eq), max(eq."precision"))
               AS eq_value
      FROM v_operation_eq o
      JOIN currency c  ON c.uuid  = o.currency_uuid
      JOIN currency eq ON eq.uuid = p_eq_currency
     WHERE o.ledger_id        = p_ledger_id
       AND o.to_currency_uuid = p_eq_currency
       AND o."date" BETWEEN p_from AND p_to
       AND o.acc_from_is_operating
       AND NOT o.acc_to_is_operating
       AND NOT EXISTS (
               SELECT 1 FROM operation_link ol
                WHERE ol.ledger_id = p_ledger_id AND ol.main_uuid = o.uuid
                  AND ol.type = 0 AND ol.deleted_at IS NULL
           )
       -- Переоценка актива — не расход (capital-assets, 000033): сторона с
       -- system_kind = 3, без фильтра deleted_at.
       AND NOT EXISTS (
               SELECT 1 FROM account r
                WHERE r.ledger_id = p_ledger_id
                  AND r.uuid IN (o.acc_fr_uuid, o.acc_to_uuid)
                  AND r.system_kind = 3
           )
     GROUP BY o.acc_to_uuid, o.acc_to_name, o.currency_uuid

    UNION ALL

    SELECT a.uuid, a.name, p_eq_currency,
           round(-tn.net, eq."precision"), round(-tn.net, eq."precision")
      FROM transfer_net tn
      JOIN account  a  ON a.ledger_id = p_ledger_id AND a.system_kind = 1 AND a.deleted_at IS NULL
      JOIN currency eq ON eq.uuid = p_eq_currency
     WHERE tn.net < 0

     ORDER BY eq_value DESC NULLS LAST;
$$;

CREATE OR REPLACE FUNCTION f_expanse_by_category_for_period(
    p_ledger_id   uuid,
    p_from        timestamp,
    p_to          timestamp,
    p_eq_currency uuid
) RETURNS TABLE (
    account_uuid  uuid,
    account_name  text,
    amount_eq     numeric,
    icon_sha256   text,
    op_count      bigint
)
    LANGUAGE sql
    STABLE
    PARALLEL SAFE
AS $$
    WITH transfer_net AS (
        -- credit-нога (Transfer -> кошелёк) минус debit-нога (кошелёк -> Transfer) —
        -- обе ноги одного и того же перевода, см. f_expanse_for_period (000015).
        SELECT sum(CASE WHEN ol.link_uuid = o.uuid THEN o.amount_eq ELSE -o.amount_eq END) AS net,
               count(DISTINCT ol.main_uuid) AS n
          FROM v_operation_eq o
          JOIN operation_link ol
            ON ol.ledger_id = p_ledger_id
           AND (ol.main_uuid = o.uuid OR ol.link_uuid = o.uuid)
           AND ol.type = 0
           AND ol.deleted_at IS NULL
         WHERE o.ledger_id        = p_ledger_id
           AND o.to_currency_uuid = p_eq_currency
           AND o."date" BETWEEN p_from AND p_to
    )
    SELECT o.acc_to_uuid,
           o.acc_to_name,
           round(sum(o.amount_eq),
                 (SELECT eq."precision" FROM currency eq WHERE eq.uuid = p_eq_currency))
               AS eq_value,
           encode(i.content_sha256, 'hex'),
           count(*)
      FROM v_operation_eq o
      JOIN account a ON a.ledger_id = o.ledger_id AND a.uuid = o.acc_to_uuid
      JOIN icon    i ON i.uuid = a.icon_uuid
     WHERE o.ledger_id        = p_ledger_id
       AND o.to_currency_uuid = p_eq_currency
       AND o."date" BETWEEN p_from AND p_to
       AND o.acc_from_is_operating
       AND NOT o.acc_to_is_operating
       AND NOT EXISTS (
               SELECT 1 FROM operation_link ol
                WHERE ol.ledger_id = p_ledger_id AND ol.main_uuid = o.uuid
                  AND ol.type = 0 AND ol.deleted_at IS NULL
           )
       -- Переоценка актива — не расход (capital-assets, 000033): сторона с
       -- system_kind = 3, без фильтра deleted_at.
       AND NOT EXISTS (
               SELECT 1 FROM account r
                WHERE r.ledger_id = p_ledger_id
                  AND r.uuid IN (o.acc_fr_uuid, o.acc_to_uuid)
                  AND r.system_kind = 3
           )
     GROUP BY o.acc_to_uuid, o.acc_to_name, i.content_sha256

    UNION ALL

    SELECT a.uuid, a.name,
           round(-tn.net, eq."precision"),
           encode(i.content_sha256, 'hex'),
           tn.n
      FROM transfer_net tn
      JOIN account  a  ON a.ledger_id = p_ledger_id AND a.system_kind = 1 AND a.deleted_at IS NULL
      JOIN icon     i  ON i.uuid = a.icon_uuid
      JOIN currency eq ON eq.uuid = p_eq_currency
     WHERE tn.net < 0

     ORDER BY eq_value DESC NULLS LAST;
$$;

CREATE OR REPLACE FUNCTION f_expense_by_category_by_month(
    p_ledger_id   uuid,
    p_from        timestamp,
    p_to          timestamp,
    p_eq_currency uuid
) RETURNS TABLE (
    account_uuid       uuid,
    account_name       text,
    icon_sha256        text,
    month_start        date,
    amount_eq          numeric,
    op_count           bigint,
    incomplete         boolean,
    category_amount_eq numeric,
    category_op_count  bigint,
    total_eq           numeric
)
    LANGUAGE sql
    STABLE
    PARALLEL SAFE
AS $$
    WITH prec AS (
        SELECT eq."precision" AS p FROM currency eq WHERE eq.uuid = p_eq_currency
    ),
    regular AS (
        SELECT o.acc_to_uuid                          AS account_uuid,
               date_trunc('month', o."date")::date    AS month_start,
               sum(o.amount_eq)                       AS amt,
               count(*)                               AS n,
               bool_or(o.amount_eq IS NULL)           AS inc
          FROM v_operation_eq o
         WHERE o.ledger_id        = p_ledger_id
           AND o.to_currency_uuid = p_eq_currency
           AND o."date" BETWEEN p_from AND p_to
           AND o.acc_from_is_operating
           AND NOT o.acc_to_is_operating
           AND NOT EXISTS (
                   SELECT 1 FROM operation_link ol
                    WHERE ol.ledger_id = p_ledger_id AND ol.main_uuid = o.uuid
                      AND ol.type = 0 AND ol.deleted_at IS NULL
               )
           -- Переоценка актива — не расход (capital-assets, 000033): сторона с
           -- system_kind = 3, без фильтра deleted_at.
           AND NOT EXISTS (
                   SELECT 1 FROM account r
                    WHERE r.ledger_id = p_ledger_id
                      AND r.uuid IN (o.acc_fr_uuid, o.acc_to_uuid)
                      AND r.system_kind = 3
               )
         GROUP BY o.acc_to_uuid, date_trunc('month', o."date")
    ),
    transfer_legs AS (
        SELECT date_trunc('month', o."date")::date AS month_start,
               ol.main_uuid,
               CASE WHEN ol.link_uuid = o.uuid THEN o.amount_eq ELSE -o.amount_eq END AS signed_eq,
               o.amount_eq IS NULL AS no_rate
          FROM v_operation_eq o
          JOIN operation_link ol
            ON ol.ledger_id = p_ledger_id
           AND (ol.main_uuid = o.uuid OR ol.link_uuid = o.uuid)
           AND ol.type = 0
           AND ol.deleted_at IS NULL
         WHERE o.ledger_id        = p_ledger_id
           AND o.to_currency_uuid = p_eq_currency
           AND o."date" BETWEEN p_from AND p_to
    ),
    transfer_account AS (
        SELECT a.uuid FROM account a
         WHERE a.ledger_id = p_ledger_id AND a.system_kind = 1 AND a.deleted_at IS NULL
    ),
    -- Курсовая разница переводов входит в Transfer, только если за ВЕСЬ
    -- период это потеря (net < 0) — условие строки Transfer в структуре. Тогда
    -- же и только тогда в клетки идут её помесячные части: сумма месяцев
    -- Transfer равна её итогу (000031; в 000030 клетки шли всегда и при
    -- выигрыше за период расходились с итогом).
    transfer_period AS (
        SELECT sum(tl.signed_eq) AS net, count(DISTINCT tl.main_uuid) AS n
          FROM transfer_legs tl
    ),
    transfer_cells AS (
        SELECT ta.uuid AS account_uuid, tl.month_start,
               -sum(tl.signed_eq) AS amt, count(DISTINCT tl.main_uuid) AS n, bool_or(tl.no_rate) AS inc
          FROM transfer_legs tl CROSS JOIN transfer_account ta
         WHERE (SELECT tp.net FROM transfer_period tp) < 0
         GROUP BY ta.uuid, tl.month_start
        HAVING sum(tl.signed_eq) IS DISTINCT FROM 0
    ),
    -- Обычная трата в саму категорию Transfer и курсовая потеря — одна
    -- категория и одна клетка на месяц (в 000030 — две строки одного месяца).
    cats AS (
        SELECT x.account_uuid, sum(x.amt) AS amt, sum(x.n)::bigint AS n
          FROM (SELECT r.account_uuid, r.amt, r.n FROM regular r
                UNION ALL
                SELECT ta.uuid, -tp.net, tp.n
                  FROM transfer_period tp CROSS JOIN transfer_account ta
                 WHERE tp.net < 0) x
         GROUP BY x.account_uuid
    ),
    cells AS (
        SELECT x.account_uuid, x.month_start, sum(x.amt) AS amt, sum(x.n)::bigint AS n, bool_or(x.inc) AS inc
          FROM (SELECT r.account_uuid, r.month_start, r.amt, r.n, r.inc FROM regular r
                UNION ALL
                SELECT tc.account_uuid, tc.month_start, tc.amt, tc.n, tc.inc FROM transfer_cells tc) x
         GROUP BY x.account_uuid, x.month_start
    ),
    cats_rounded AS (
        SELECT c.account_uuid, round(c.amt, (SELECT p FROM prec)) AS amt, c.n FROM cats c
    )
    SELECT c.account_uuid,
           a.name,
           encode(i.content_sha256, 'hex'),
           m.month_start,
           round(m.amt, (SELECT p FROM prec)),
           m.n::bigint,
           m.inc,
           c.amt,
           c.n,
           (SELECT COALESCE(sum(cr.amt), 0) FROM cats_rounded cr)
      FROM cats_rounded c
      JOIN cells   m ON m.account_uuid = c.account_uuid
      JOIN account a ON a.ledger_id = p_ledger_id AND a.uuid = c.account_uuid
      JOIN icon    i ON i.uuid = a.icon_uuid
     ORDER BY c.amt DESC NULLS LAST, c.account_uuid, m.month_start;
$$;

COMMENT ON FUNCTION f_expense_by_category_by_month(uuid, timestamp, timestamp, uuid) IS
    'Расход «категория × календарный месяц» по правилам f_expanse_by_category_for_period (ноги перевода сведены в Transfer): строка на непустую клетку с суммой, числом операций и incomplete; итог и число операций категории за период и общий total_eq — в каждой строке. Миграция 000030.';

CREATE OR REPLACE FUNCTION f_income_expense_by_month(
    p_ledger_id   uuid,
    p_from        timestamp,
    p_to          timestamp,
    p_eq_currency uuid
) RETURNS TABLE (
    month_start  date,
    income_eq    numeric,
    expense_eq   numeric,
    incomplete   boolean
)
    LANGUAGE sql
    STABLE
    PARALLEL SAFE
AS $$
    SELECT months.month_start::date,
           round(coalesce(sum(o.amount_eq)
                     FILTER (WHERE o.acc_to_is_operating AND NOT o.acc_from_is_operating), 0),
                 (SELECT c."precision" FROM currency c WHERE c.uuid = p_eq_currency)),
           round(coalesce(sum(o.amount_eq)
                     FILTER (WHERE o.acc_from_is_operating AND NOT o.acc_to_is_operating), 0),
                 (SELECT c."precision" FROM currency c WHERE c.uuid = p_eq_currency)),
           bool_or(o.uuid IS NOT NULL AND o.amount_eq IS NULL)
      FROM generate_series(date_trunc('month', p_from), date_trunc('month', p_to), interval '1 month')
               AS months(month_start)
      LEFT JOIN v_operation_eq o
             ON date_trunc('month', o."date") = months.month_start
            AND o.ledger_id        = p_ledger_id
            AND o.to_currency_uuid = p_eq_currency
            AND o."date" BETWEEN p_from AND p_to
            AND o.acc_from_is_operating <> o.acc_to_is_operating -- расход ИЛИ доход, не перевод кошелёк-кошелёк
            -- Переоценка актива — ни доход, ни расход (capital-assets, 000033).
            AND NOT EXISTS (
                    SELECT 1 FROM account r
                     WHERE r.ledger_id = p_ledger_id
                       AND r.uuid IN (o.acc_fr_uuid, o.acc_to_uuid)
                       AND r.system_kind = 3
                )
     GROUP BY months.month_start
     ORDER BY months.month_start;
$$;

CREATE OR REPLACE FUNCTION f_expense_by_weekday_for_period(
    p_ledger_id   uuid,
    p_from        timestamp,
    p_to          timestamp,
    p_eq_currency uuid
) RETURNS TABLE (
    isodow      smallint,
    expense_eq  numeric,
    incomplete  boolean
)
    LANGUAGE sql
    STABLE
    PARALLEL SAFE
AS $$
    SELECT days.isodow,
           round(coalesce(sum(o.amount_eq), 0),
                 (SELECT c."precision" FROM currency c WHERE c.uuid = p_eq_currency)),
           bool_or(o.uuid IS NOT NULL AND o.amount_eq IS NULL)
      FROM generate_series(1, 7) AS days(isodow)
      LEFT JOIN v_operation_eq o
             ON extract(isodow FROM o."date")::smallint = days.isodow
            AND o.ledger_id        = p_ledger_id
            AND o.to_currency_uuid = p_eq_currency
            AND o."date" BETWEEN p_from AND p_to
            AND o.acc_from_is_operating
            AND NOT o.acc_to_is_operating
            -- Переоценка актива — не расход (capital-assets, 000033).
            AND NOT EXISTS (
                    SELECT 1 FROM account r
                     WHERE r.ledger_id = p_ledger_id
                       AND r.uuid IN (o.acc_fr_uuid, o.acc_to_uuid)
                       AND r.system_kind = 3
                )
     GROUP BY days.isodow
     ORDER BY days.isodow;
$$;

CREATE OR REPLACE FUNCTION f_wallet_turnover_for_period(
    p_ledger_id   uuid,
    p_from        timestamp,
    p_to          timestamp,
    p_eq_currency uuid
) RETURNS TABLE (
    account_uuid    uuid,
    account_name    text,
    comment         text,
    is_archived     boolean,
    currency_uuid   uuid,
    symbol          text,
    "precision"     smallint,
    icon_sha256     text,
    turnover_in     numeric,
    turnover_out    numeric,
    turnover_in_eq  numeric,
    turnover_out_eq numeric,
    incomplete      boolean
)
    LANGUAGE sql
    STABLE
    PARALLEL SAFE
AS $$
    WITH oe AS MATERIALIZED (
        SELECT oe.acc_to_uuid, oe.acc_fr_uuid, oe.amount_eq
          FROM v_operation_eq oe
         WHERE oe.ledger_id        = p_ledger_id
           AND oe.to_currency_uuid = p_eq_currency
           AND oe."date" BETWEEN p_from AND p_to
           -- Переоценка актива — не оборот (capital-assets, 000033): сторона
           -- с system_kind = 3, без фильтра deleted_at. Здесь и в opt/opf ниже
           -- одним текстом, иначе своя валюта и эквивалент разъедутся.
           AND NOT EXISTS (
                   SELECT 1 FROM account r
                    WHERE r.ledger_id = p_ledger_id
                      AND r.uuid IN (oe.acc_fr_uuid, oe.acc_to_uuid)
                      AND r.system_kind = 3
               )
    ),
    oe_by_account AS (
        SELECT acc_to_uuid AS acc_uuid, amount_eq, true AS is_in FROM oe
        UNION ALL
        SELECT acc_fr_uuid AS acc_uuid, amount_eq, false AS is_in FROM oe
    ),
    oe_agg AS (
        SELECT acc_uuid,
               sum(amount_eq) FILTER (WHERE is_in)                 AS amount_in_eq,
               sum(amount_eq) FILTER (WHERE NOT is_in)              AS amount_out_eq,
               bool_or(amount_eq IS NULL) FILTER (WHERE is_in)      AS incomplete_in,
               bool_or(amount_eq IS NULL) FILTER (WHERE NOT is_in)  AS incomplete_out
          FROM oe_by_account
         GROUP BY acc_uuid
    )
    SELECT vao.uuid,
           vao.name,
           vao.comment,
           vao.is_archived,
           c.uuid,
           c.symbol,
           c."precision",
           encode(ic.content_sha256, 'hex'),
           round(coalesce(opt.amount_to, 0), c."precision"),
           round(coalesce(opf.amount_fr, 0), c."precision"),
           round(coalesce(oe_agg.amount_in_eq, 0),
                 (SELECT eq."precision" FROM currency eq WHERE eq.uuid = p_eq_currency)),
           round(coalesce(oe_agg.amount_out_eq, 0),
                 (SELECT eq."precision" FROM currency eq WHERE eq.uuid = p_eq_currency)),
           coalesce(oe_agg.incomplete_in, false) OR coalesce(oe_agg.incomplete_out, false)
      FROM v_account_operating vao
      JOIN currency c
        ON c.uuid = vao.currency_uuid
       AND c.deleted_at IS NULL
      JOIN icon ic ON ic.uuid = vao.icon_uuid
      LEFT JOIN (
            SELECT o.acc_to_uuid, sum(o.amount) AS amount_to
              FROM operation o
             WHERE o.ledger_id = p_ledger_id
               AND o.deleted_at IS NULL
               AND o."date" BETWEEN p_from AND p_to
               AND NOT EXISTS (
                       SELECT 1 FROM account r
                        WHERE r.ledger_id = p_ledger_id
                          AND r.uuid IN (o.acc_fr_uuid, o.acc_to_uuid)
                          AND r.system_kind = 3
                   )
             GROUP BY o.acc_to_uuid
           ) opt ON opt.acc_to_uuid = vao.uuid
      LEFT JOIN (
            SELECT o.acc_fr_uuid, sum(o.amount) AS amount_fr
              FROM operation o
             WHERE o.ledger_id = p_ledger_id
               AND o.deleted_at IS NULL
               AND o."date" BETWEEN p_from AND p_to
               AND NOT EXISTS (
                       SELECT 1 FROM account r
                        WHERE r.ledger_id = p_ledger_id
                          AND r.uuid IN (o.acc_fr_uuid, o.acc_to_uuid)
                          AND r.system_kind = 3
                   )
             GROUP BY o.acc_fr_uuid
           ) opf ON opf.acc_fr_uuid = vao.uuid
      LEFT JOIN oe_agg ON oe_agg.acc_uuid = vao.uuid
     WHERE vao.ledger_id = p_ledger_id
     ORDER BY vao.name;
$$;

CREATE OR REPLACE FUNCTION f_operations_for_period(
    p_ledger_id              uuid,
    p_from                   timestamp,
    p_to                     timestamp,
    p_eq_currency            uuid,
    p_limit                  integer   DEFAULT 1000,
    p_cursor_date            timestamp DEFAULT NULL,
    p_cursor_uuid            uuid      DEFAULT NULL,
    p_category_uuids         uuid[]    DEFAULT NULL,
    p_wallet_uuids           uuid[]    DEFAULT NULL,
    p_kind                   text      DEFAULT NULL,
    p_q                      text      DEFAULT NULL,
    p_exclude_category_uuids uuid[]    DEFAULT NULL,
    p_qs                     text[]    DEFAULT NULL
) RETURNS TABLE (
    operation_uuid uuid,
    "date"         timestamp,
    kind           text,
    amount         numeric,
    currency_uuid  uuid,
    symbol         text,
    "precision"    smallint,
    amount_eq      numeric,
    comment        text,
    category_uuid  uuid,
    category_name  text,
    icon_sha256    text,
    wallet_uuid    uuid,
    wallet_name    text,
    from_uuid      uuid,
    from_name      text,
    to_uuid        uuid,
    to_name        text
)
    LANGUAGE sql
    STABLE
    PARALLEL SAFE
AS $$
    SELECT o.uuid,
           o."date",
           CASE WHEN EXISTS (SELECT 1 FROM account r
                             WHERE r.ledger_id = p_ledger_id
                               AND r.uuid IN (o.acc_fr_uuid, o.acc_to_uuid)
                               AND r.system_kind = 3)                    THEN 'revaluation'
                WHEN o.acc_from_is_operating AND o.acc_to_is_operating THEN 'transfer'
                WHEN o.acc_from_is_operating                           THEN 'expense'
                ELSE                                                        'income' END,
           round(o.amount, cur."precision"),
           o.currency_uuid,
           cur.symbol,
           cur."precision",
           o.amount_eq,
           o.comment,
           cat.uuid,
           cat.name,
           encode(ic.content_sha256, 'hex'),
           wal.uuid,
           wal.name,
           o.acc_fr_uuid,
           o.acc_fr_name,
           o.acc_to_uuid,
           o.acc_to_name
      FROM v_operation_eq o
      JOIN currency cur ON cur.uuid = o.currency_uuid
      LEFT JOIN account cat
             ON cat.ledger_id = o.ledger_id
            AND cat.uuid = CASE WHEN NOT o.acc_from_is_operating THEN o.acc_fr_uuid
                                 WHEN NOT o.acc_to_is_operating  THEN o.acc_to_uuid END
      LEFT JOIN icon ic ON ic.uuid = cat.icon_uuid
      LEFT JOIN account wal
             ON wal.ledger_id = o.ledger_id
            AND wal.uuid = CASE WHEN     o.acc_from_is_operating AND NOT o.acc_to_is_operating THEN o.acc_fr_uuid
                                 WHEN NOT o.acc_from_is_operating AND     o.acc_to_is_operating THEN o.acc_to_uuid END
     WHERE o.ledger_id        = p_ledger_id
       AND o.to_currency_uuid = p_eq_currency
       AND o."date" BETWEEN p_from AND p_to
       AND (p_category_uuids IS NULL
            OR (NOT o.acc_from_is_operating AND o.acc_fr_uuid = ANY (p_category_uuids))
            OR (NOT o.acc_to_is_operating   AND o.acc_to_uuid = ANY (p_category_uuids)))
       AND (p_exclude_category_uuids IS NULL
            OR NOT ((NOT o.acc_from_is_operating AND o.acc_fr_uuid = ANY (p_exclude_category_uuids))
                 OR (NOT o.acc_to_is_operating   AND o.acc_to_uuid = ANY (p_exclude_category_uuids))))
       AND (p_wallet_uuids IS NULL
            OR (o.acc_from_is_operating AND o.acc_fr_uuid = ANY (p_wallet_uuids))
            OR (o.acc_to_is_operating   AND o.acc_to_uuid = ANY (p_wallet_uuids)))
       AND (p_kind IS NULL
            OR CASE WHEN EXISTS (SELECT 1 FROM account r
                                 WHERE r.ledger_id = p_ledger_id
                                   AND r.uuid IN (o.acc_fr_uuid, o.acc_to_uuid)
                                   AND r.system_kind = 3)                    THEN 'revaluation'
                    WHEN o.acc_from_is_operating AND o.acc_to_is_operating THEN 'transfer'
                    WHEN o.acc_from_is_operating                           THEN 'expense'
                    ELSE                                                        'income' END = p_kind)
       AND (p_q IS NULL
            OR strpos(lower(translate(o.comment, 'Ёё', 'Ее')), lower(translate(p_q, 'Ёё', 'Ее'))) > 0)
       AND (p_qs IS NULL
            OR EXISTS (SELECT 1 FROM unnest(p_qs) AS v(q)
                        WHERE strpos(lower(translate(o.comment, 'Ёё', 'Ее')), lower(translate(v.q, 'Ёё', 'Ее'))) > 0))
       AND (p_cursor_date IS NULL OR (o."date", o.uuid) < (p_cursor_date, p_cursor_uuid))
     ORDER BY o."date" DESC, o.uuid DESC
     LIMIT p_limit;
$$;

COMMENT ON FUNCTION f_operations_for_period(uuid, timestamp, timestamp, uuid, integer, timestamp, uuid, uuid[], uuid[], text, text, uuid[], text[]) IS
    'Лента операций периода с курсором (date, uuid) и фильтрами (категории, исключённые категории, кошельки, kind, подстрока комментария q или любой из вариантов p_qs) до курсора и LIMIT. Необязательные параметры передаются именованной нотацией, например p_kind => $6; NULL — фильтр не задан. Миграции 000027, 000030, 000032.';

CREATE OR REPLACE FUNCTION f_operations_total(
    p_ledger_id              uuid,
    p_from                   timestamp,
    p_to                     timestamp,
    p_eq_currency            uuid,
    p_category_uuids         uuid[] DEFAULT NULL,
    p_wallet_uuids           uuid[] DEFAULT NULL,
    p_kind                   text   DEFAULT NULL,
    p_q                      text   DEFAULT NULL,
    p_exclude_category_uuids uuid[] DEFAULT NULL,
    p_qs                     text[] DEFAULT NULL
) RETURNS TABLE (
    total_eq   numeric,
    incomplete boolean,
    matched    bigint
)
    LANGUAGE sql
    STABLE
    PARALLEL SAFE
AS $$
    WITH m AS (
        SELECT CASE WHEN EXISTS (SELECT 1 FROM account r
                                 WHERE r.ledger_id = p_ledger_id
                                   AND r.uuid IN (o.acc_fr_uuid, o.acc_to_uuid)
                                   AND r.system_kind = 3)                    THEN 'revaluation'
                    WHEN o.acc_from_is_operating AND o.acc_to_is_operating THEN 'transfer'
                    WHEN o.acc_from_is_operating                           THEN 'expense'
                    ELSE                                                        'income' END AS kind,
               o.amount_eq
          FROM v_operation_eq o
          JOIN currency cur ON cur.uuid = o.currency_uuid
         WHERE o.ledger_id        = p_ledger_id
           AND o.to_currency_uuid = p_eq_currency
           AND o."date" BETWEEN p_from AND p_to
           AND (p_category_uuids IS NULL
                OR (NOT o.acc_from_is_operating AND o.acc_fr_uuid = ANY (p_category_uuids))
                OR (NOT o.acc_to_is_operating   AND o.acc_to_uuid = ANY (p_category_uuids)))
           AND (p_exclude_category_uuids IS NULL
                OR NOT ((NOT o.acc_from_is_operating AND o.acc_fr_uuid = ANY (p_exclude_category_uuids))
                     OR (NOT o.acc_to_is_operating   AND o.acc_to_uuid = ANY (p_exclude_category_uuids))))
           AND (p_wallet_uuids IS NULL
                OR (o.acc_from_is_operating AND o.acc_fr_uuid = ANY (p_wallet_uuids))
                OR (o.acc_to_is_operating   AND o.acc_to_uuid = ANY (p_wallet_uuids)))
           AND (p_kind IS NULL
                OR CASE WHEN EXISTS (SELECT 1 FROM account r
                                     WHERE r.ledger_id = p_ledger_id
                                       AND r.uuid IN (o.acc_fr_uuid, o.acc_to_uuid)
                                       AND r.system_kind = 3)                    THEN 'revaluation'
                        WHEN o.acc_from_is_operating AND o.acc_to_is_operating THEN 'transfer'
                        WHEN o.acc_from_is_operating                           THEN 'expense'
                        ELSE                                                        'income' END = p_kind)
           AND (p_q IS NULL
                OR strpos(lower(translate(o.comment, 'Ёё', 'Ее')), lower(translate(p_q, 'Ёё', 'Ее'))) > 0)
           AND (p_qs IS NULL
                OR EXISTS (SELECT 1 FROM unnest(p_qs) AS v(q)
                            WHERE strpos(lower(translate(o.comment, 'Ёё', 'Ее')), lower(translate(v.q, 'Ёё', 'Ее'))) > 0))
    )
    SELECT COALESCE(sum(CASE WHEN p_kind IS NOT NULL THEN m.amount_eq
                             WHEN m.kind = 'income'  THEN m.amount_eq
                             WHEN m.kind = 'expense' THEN -m.amount_eq
                             ELSE 0 END), 0),
           COALESCE(bool_or(m.amount_eq IS NULL), false),
           count(*)
      FROM m;
$$;

COMMENT ON FUNCTION f_operations_total(uuid, timestamp, timestamp, uuid, uuid[], uuid[], text, text, uuid[], text[]) IS
    'Итог ленты по тем же фильтрам за весь период: total_eq (с p_kind — сумма, без — сальдо income − expense, переводы 0), incomplete (есть операции без курса, в сумму не вошли), matched. Ровно одна строка. Миграции 000027, 000030, 000032.';

CREATE FUNCTION f_assets_for_period(
    p_ledger_id   uuid,
    p_from        timestamp,
    p_to          timestamp,
    p_eq_currency uuid
) RETURNS TABLE (
    account_uuid          uuid,
    account_name          text,
    is_archived           boolean,
    icon_sha256           text,
    asset_type            smallint,
    include_in_net_worth  boolean,
    currency_uuid         uuid,
    symbol                text,
    "precision"           smallint,
    value                 numeric,
    revaluation_total     numeric,
    revaluation_period    numeric,
    invested              numeric,
    return_pct            numeric,
    value_eq              numeric,
    invested_eq           numeric,
    revaluation_total_eq  numeric,
    revaluation_period_eq numeric
)
    LANGUAGE sql
    STABLE
    PARALLEL SAFE
AS $$
    WITH assets AS MATERIALIZED (
        SELECT vao.uuid, vao.name, vao.is_archived, vao.icon_uuid, vao.currency_uuid,
               vao.asset_type, vao.include_in_net_worth
          FROM v_account_operating vao
         WHERE vao.ledger_id = p_ledger_id
           AND vao.asset_type IS NOT NULL
    ),
    moves AS (
        SELECT a.uuid AS account_uuid, o."date", o.amount AS delta,
               EXISTS (SELECT 1 FROM account r
                        WHERE r.ledger_id = p_ledger_id
                          AND r.uuid IN (o.acc_fr_uuid, o.acc_to_uuid)
                          AND r.system_kind = 3) AS is_reval
          FROM assets a
          JOIN operation o
            ON o.ledger_id = p_ledger_id
           AND o.deleted_at IS NULL
           AND o.acc_to_uuid = a.uuid
           AND o."date" <= p_to
        UNION ALL
        SELECT a.uuid, o."date", -o.amount,
               EXISTS (SELECT 1 FROM account r
                        WHERE r.ledger_id = p_ledger_id
                          AND r.uuid IN (o.acc_fr_uuid, o.acc_to_uuid)
                          AND r.system_kind = 3)
          FROM assets a
          JOIN operation o
            ON o.ledger_id = p_ledger_id
           AND o.deleted_at IS NULL
           AND o.acc_fr_uuid = a.uuid
           AND o."date" <= p_to
    ),
    sums AS (
        SELECT m.account_uuid,
               sum(m.delta)                                                AS value,
               sum(m.delta) FILTER (WHERE m.is_reval)                      AS reval_total,
               sum(m.delta) FILTER (WHERE m.is_reval AND m."date" >= p_from) AS reval_period
          FROM moves m
         GROUP BY m.account_uuid
    ),
    eqp AS (
        SELECT eq."precision" AS p FROM currency eq WHERE eq.uuid = p_eq_currency
    )
    SELECT a.uuid,
           a.name,
           a.is_archived,
           encode(ic.content_sha256, 'hex'),
           a.asset_type,
           a.include_in_net_worth,
           c.uuid,
           c.symbol,
           c."precision",
           v.value,
           v.rt,
           v.rp,
           v.value - v.rt,
           CASE WHEN v.value - v.rt > 0 THEN (v.value / (v.value - v.rt) - 1) * 100 END,
           ve.value_eq,
           ve.value_eq - ve.rt_eq,
           ve.rt_eq,
           ve.rp_eq
      FROM assets a
      JOIN currency c
        ON c.uuid = a.currency_uuid
       AND c.deleted_at IS NULL
      LEFT JOIN icon ic ON ic.uuid = a.icon_uuid
      LEFT JOIN sums s ON s.account_uuid = a.uuid
      CROSS JOIN LATERAL (
            SELECT round(coalesce(s.value, 0),        c."precision") AS value,
                   round(coalesce(s.reval_total, 0),  c."precision") AS rt,
                   round(coalesce(s.reval_period, 0), c."precision") AS rp
           ) v
      LEFT JOIN LATERAL (
            SELECT rr.rate
              FROM v_currency_conversion_rate rr
             WHERE rr.from_currency_uuid = c.uuid
               AND rr.to_currency_uuid   = p_eq_currency
               AND rr."date"            <= p_to::date
               AND (rr.ledger_id IS NULL OR rr.ledger_id = p_ledger_id)
             ORDER BY rr."date" DESC, (rr.ledger_id IS NULL)
             LIMIT 1
           ) r ON true
      CROSS JOIN LATERAL (
            SELECT round(r.rate * v.value, (SELECT p FROM eqp)) AS value_eq,
                   round(r.rate * v.rt,    (SELECT p FROM eqp)) AS rt_eq,
                   round(r.rate * v.rp,    (SELECT p FROM eqp)) AS rp_eq
           ) ve
     ORDER BY ve.value_eq DESC NULLS LAST, a.name, a.uuid;
$$;

COMMENT ON FUNCTION f_assets_for_period(uuid, timestamp, timestamp, uuid) IS
    'Отчёт «Капитал»: строка на каждый живой актив леджера — оценка (value) на p_to включительно, переоценка накопленная и за период, вложено = value − revaluation_total, доходность в процентах; эквиваленты по одному курсу на p_to. Миграция 000033.';

GRANT EXECUTE ON FUNCTION f_assets_for_period(uuid, timestamp, timestamp, uuid) TO wallet_reader;
