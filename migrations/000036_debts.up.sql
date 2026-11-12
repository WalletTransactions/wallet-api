-- debts (wallet-api/openspec/changes/debts): учёт долгов. Долг — кошелёк
-- контрагента; знак баланса — направление («+» — мне должны, «−» — я должен).
--
-- 1. counterparty — контрагент, синхронизируемая таблица потока ledger
--    (design D1). Имя уникально среди живых контрагентов леджера без учёта
--    регистра, пробелов по краям и «ё»/«е» (правило uq_account_name из 000024
--    плюс btrim, решение 2026-11-12).
-- 2. account_debt — признак долгового кошелька по образцу account_asset
--    (design D2); уникальности «контрагент + валюта» нет намеренно: один
--    заём — один кошелёк. GRANT SELECT роли wallet_reader на обе таблицы —
--    для LEFT JOIN в wallet-report.
-- 3. Ссылки внутри леджера (counterparty.icon_uuid, account_debt →
--    counterparty) — NO ACTION DEFERRABLE INITIALLY IMMEDIATE, как в 000025:
--    push проверяется сразу (409 missing_reference), удаление леджера
--    откладывает проверку до COMMIT (account_deletion_repo).
-- 4. v_account_operating отдаёт counterparty_uuid (D5), а
--    f_balance_to_date/f_balance_to_dates/f_balance_series — ту же колонку в
--    конце RETURNS TABLE (DROP + CREATE + GRANT: DROP снимает привилегии).
-- 5. f_operations_for_period и f_operations_total: kind = 'debt' — прямой
--    перевод, у которого ровно одна сторона — долговой кошелёк (D6); фильтр
--    p_kind принимает 'debt', сальдо без p_kind его не считает (ELSE 0).
-- 6. f_debts_for_period — сводка по долговым кошелькам (D7).
--
-- Каскад tombstone кошелька → account_debt держит push_batch
-- (src/sync_repo.cpp, cascade_rules()), как у account_asset (000035). Разовой
-- чистки осиротевших строк, как в 000035, здесь нет: таблица создаётся этой
-- же миграцией, строк в ней ещё нет.
--
-- Источники прежних определений (последняя миграция, которая их задавала,
-- сверено 2026-11-12; partition-operation-by-ledger миграции ещё не имеет):
-- v_account_operating, f_balance_to_date, f_balance_to_dates,
-- f_balance_series, f_operations_for_period, f_operations_total — 000033.
-- Читаемые зеркала — schema/table/counterparty.sql, schema/table/account_debt.sql,
-- schema/view/v_account_operating.sql, schema/function/*.sql.

CREATE TABLE counterparty (
    uuid          uuid        NOT NULL,
    ledger_id     uuid        NOT NULL REFERENCES ledger (id) ON DELETE CASCADE,
    seq           bigint      NOT NULL,
    deleted_at    timestamptz,
    updated_at    timestamptz NOT NULL DEFAULT now(),
    updated_by    uuid REFERENCES device (id) ON DELETE SET NULL,

    name          text        NOT NULL,
    comment       text        NOT NULL DEFAULT '',
    icon_uuid     uuid,
    is_archived   boolean     NOT NULL DEFAULT false,

    CONSTRAINT pk_counterparty PRIMARY KEY (ledger_id, uuid),
    CONSTRAINT fk_counterparty_icon
        FOREIGN KEY (icon_uuid) REFERENCES icon (uuid)
        ON DELETE NO ACTION DEFERRABLE INITIALLY IMMEDIATE
);

CREATE INDEX ix_counterparty_sync ON counterparty (ledger_id, seq);
CREATE INDEX ix_counterparty_icon ON counterparty (icon_uuid);

CREATE UNIQUE INDEX uq_counterparty_name
    ON counterparty (ledger_id, lower(btrim(translate(name, 'Ёё', 'Ее'))))
    WHERE deleted_at IS NULL;

CREATE TRIGGER trg_counterparty_updated_at BEFORE UPDATE ON counterparty
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE counterparty IS
    'Контрагент долгов (человек или организация): к нему привязаны долговые кошельки (account_debt). Общий для всех участников леджера.';
COMMENT ON COLUMN counterparty.uuid IS 'Идентификатор контрагента, выдаёт клиент.';
COMMENT ON COLUMN counterparty.ledger_id IS 'Леджер-владелец.';
COMMENT ON COLUMN counterparty.seq IS 'Версия строки в потоке изменений леджера.';
COMMENT ON COLUMN counterparty.deleted_at IS
    'Момент мягкого удаления; NULL — контрагент жив. Удаление при живых account_debt отклоняется (409 counterparty_in_use).';
COMMENT ON COLUMN counterparty.updated_at IS 'Момент последнего изменения строки — только диагностика.';
COMMENT ON COLUMN counterparty.updated_by IS 'Устройство, применившее последнее изменение этой строки.';
COMMENT ON COLUMN counterparty.name IS
    'Имя контрагента — уникально среди живых строк леджера без учёта регистра, пробелов по краям и «ё»/«е», см. uq_counterparty_name.';
COMMENT ON COLUMN counterparty.comment IS 'Свободный комментарий к контрагенту (телефон и т. п.).';
COMMENT ON COLUMN counterparty.icon_uuid IS 'Иконка контрагента; NULL — без иконки.';
COMMENT ON COLUMN counterparty.is_archived IS 'Архивный контрагент — признак интерфейса, на долги не влияет.';

CREATE TABLE account_debt (
    uuid              uuid        NOT NULL,
    ledger_id         uuid        NOT NULL,
    seq               bigint      NOT NULL,
    deleted_at        timestamptz,
    updated_at        timestamptz NOT NULL DEFAULT now(),
    updated_by        uuid REFERENCES device (id) ON DELETE SET NULL,

    counterparty_uuid uuid        NOT NULL,
    comment           text        NOT NULL DEFAULT '',
    due_date          date,

    CONSTRAINT pk_account_debt PRIMARY KEY (ledger_id, uuid),
    CONSTRAINT fk_account_debt_account_operating
        FOREIGN KEY (ledger_id, uuid) REFERENCES account_operating (ledger_id, uuid) ON DELETE CASCADE,
    CONSTRAINT fk_account_debt_counterparty
        FOREIGN KEY (ledger_id, counterparty_uuid) REFERENCES counterparty (ledger_id, uuid)
        ON DELETE NO ACTION DEFERRABLE INITIALLY IMMEDIATE
);

CREATE INDEX ix_account_debt_sync ON account_debt (ledger_id, seq);
CREATE INDEX ix_account_debt_counterparty ON account_debt (ledger_id, counterparty_uuid);

CREATE TRIGGER trg_account_debt_updated_at BEFORE UPDATE ON account_debt
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE account_debt IS
    'Признак долгового кошелька: живая строка — кошелёк является долгом перед контрагентом или контрагента. Баланс «+» — контрагент должен леджеру, «−» — леджер должен контрагенту. uuid всегда равен account.uuid и account_operating.uuid.';
COMMENT ON COLUMN account_debt.uuid IS '= account_operating.uuid того же кошелька.';
COMMENT ON COLUMN account_debt.ledger_id IS '= account_operating.ledger_id того же кошелька.';
COMMENT ON COLUMN account_debt.seq IS 'Версия строки в потоке изменений леджера — своя, отдельная от account.seq.';
COMMENT ON COLUMN account_debt.deleted_at IS
    'Момент мягкого удаления (снятие признака долга); NULL — кошелёк долговой.';
COMMENT ON COLUMN account_debt.updated_at IS 'Момент последнего изменения строки — только диагностика.';
COMMENT ON COLUMN account_debt.updated_by IS 'Устройство, применившее последнее изменение этой строки.';
COMMENT ON COLUMN account_debt.counterparty_uuid IS
    'Контрагент долга. Уникальности «контрагент + валюта» нет: у контрагента может быть несколько займов.';
COMMENT ON COLUMN account_debt.comment IS 'Свободный комментарий к займу.';
COMMENT ON COLUMN account_debt.due_date IS 'Срок возврата; NULL — срок не задан.';

GRANT SELECT ON counterparty TO wallet_reader;
GRANT SELECT ON account_debt TO wallet_reader;

-- Новая колонка — в конце: CREATE OR REPLACE VIEW это допускает.
CREATE OR REPLACE VIEW v_account_operating AS
SELECT a.uuid, a.ledger_id, a.name, a.comment, a.icon_uuid, a.is_archived, ao.currency_uuid,
       aa.asset_type, aa.include_in_net_worth,
       ad.counterparty_uuid
  FROM account a
  JOIN account_operating ao
    ON ao.ledger_id = a.ledger_id
   AND ao.uuid      = a.uuid
  LEFT JOIN account_asset aa
    ON aa.ledger_id  = a.ledger_id
   AND aa.uuid       = a.uuid
   AND aa.deleted_at IS NULL
  LEFT JOIN account_debt ad
    ON ad.ledger_id  = a.ledger_id
   AND ad.uuid       = a.uuid
   AND ad.deleted_at IS NULL
 WHERE a.deleted_at IS NULL
   AND ao.deleted_at IS NULL;

-- Балансовые функции: новая колонка в конце RETURNS TABLE.
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
    include_in_net_worth boolean,
    -- debts (000036): контрагент долгового кошелька; NULL — не долговой
    -- (и пустой бакет f_balance_series).
    counterparty_uuid    uuid
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
           vao.include_in_net_worth,
           vao.counterparty_uuid
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
    include_in_net_worth boolean,
    -- debts (000036): контрагент долгового кошелька; NULL — не долговой
    -- (и пустой бакет f_balance_series).
    counterparty_uuid    uuid
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
               vao.include_in_net_worth,
               vao.counterparty_uuid
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
           ab.include_in_net_worth,
           ab.counterparty_uuid
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
    include_in_net_worth boolean,
    -- debts (000036): контрагент долгового кошелька; NULL — не долговой
    -- (и пустой бакет f_balance_series).
    counterparty_uuid    uuid
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
               vao.include_in_net_worth,
               vao.counterparty_uuid
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
           ab.include_in_net_worth,
           ab.counterparty_uuid
      FROM buckets b
      LEFT JOIN acct_bal ab ON ab.idx = b.idx
     ORDER BY b.idx, ab.eq_value DESC NULLS LAST;
$$;

GRANT EXECUTE ON FUNCTION f_balance_series(uuid, date, date, text, uuid) TO wallet_reader;

-- Лента и её итог: сигнатуры не меняются — CREATE OR REPLACE, гранты
-- сохраняются. Ветка 'debt' — после 'revaluation' (у переоценки одна сторона —
-- категория, пересечения нет) и до 'transfer': прямой перевод, обе стороны —
-- живые кошельки, и ровно одна из них — долговой (живая строка account_debt).
-- Перевод между двумя долговыми и проводки «долговой кошелёк ↔ категория»
-- (прощение, проценты, ноги разновалютного перевода через Transfer) сохраняют
-- прежний вид. Одним и тем же текстом в колонке kind и в фильтре p_kind.

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
                WHEN o.acc_from_is_operating AND o.acc_to_is_operating
                 AND EXISTS (SELECT 1 FROM account_debt d
                              WHERE d.ledger_id = p_ledger_id AND d.uuid = o.acc_fr_uuid
                                AND d.deleted_at IS NULL)
                  <> EXISTS (SELECT 1 FROM account_debt d
                              WHERE d.ledger_id = p_ledger_id AND d.uuid = o.acc_to_uuid
                                AND d.deleted_at IS NULL)                THEN 'debt'
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
                    WHEN o.acc_from_is_operating AND o.acc_to_is_operating
                     AND EXISTS (SELECT 1 FROM account_debt d
                                  WHERE d.ledger_id = p_ledger_id AND d.uuid = o.acc_fr_uuid
                                    AND d.deleted_at IS NULL)
                      <> EXISTS (SELECT 1 FROM account_debt d
                                  WHERE d.ledger_id = p_ledger_id AND d.uuid = o.acc_to_uuid
                                    AND d.deleted_at IS NULL)                THEN 'debt'
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
    'Лента операций периода с курсором (date, uuid) и фильтрами (категории, исключённые категории, кошельки, kind, подстрока комментария q или любой из вариантов p_qs) до курсора и LIMIT. kind: revaluation, debt (прямой перевод, ровно одна сторона — долговой кошелёк), transfer, expense, income. Необязательные параметры передаются именованной нотацией, например p_kind => $6; NULL — фильтр не задан. Миграции 000027, 000030, 000032, 000033, 000036.';

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
                    WHEN o.acc_from_is_operating AND o.acc_to_is_operating
                     AND EXISTS (SELECT 1 FROM account_debt d
                                  WHERE d.ledger_id = p_ledger_id AND d.uuid = o.acc_fr_uuid
                                    AND d.deleted_at IS NULL)
                      <> EXISTS (SELECT 1 FROM account_debt d
                                  WHERE d.ledger_id = p_ledger_id AND d.uuid = o.acc_to_uuid
                                    AND d.deleted_at IS NULL)                THEN 'debt'
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
                        WHEN o.acc_from_is_operating AND o.acc_to_is_operating
                         AND EXISTS (SELECT 1 FROM account_debt d
                                      WHERE d.ledger_id = p_ledger_id AND d.uuid = o.acc_fr_uuid
                                        AND d.deleted_at IS NULL)
                          <> EXISTS (SELECT 1 FROM account_debt d
                                      WHERE d.ledger_id = p_ledger_id AND d.uuid = o.acc_to_uuid
                                        AND d.deleted_at IS NULL)                THEN 'debt'
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
    'Итог ленты по тем же фильтрам за весь период: total_eq (с p_kind — сумма, без — сальдо income − expense, переводы, долги и переоценка 0), incomplete (есть операции без курса, в сумму не вошли), matched. Ровно одна строка. Миграции 000027, 000030, 000032, 000033, 000036.';

-- Сводка по долгам (design D7): строка на каждый живой долговой кошелёк
-- (живы account, account_operating, account_debt) — включая нулевой,
-- архивный и кошелёк без единой проводки. Контрагент берётся без фильтра
-- deleted_at: долг на удалённого другим устройством контрагента остаётся
-- виден, пока клиент его не переклеит (design, Risks).
--
-- Границы: balance_from — строго до p_from; inflow/outflow — проводки на/с
-- кошелька за p_from..p_to включительно; balance_to — на p_to включительно,
-- выводится из уже округлённых частей, так что balance_to = balance_from +
-- inflow − outflow держится точно. Эквиваленты — по одному курсу <= p_to
-- (как f_assets_for_period), NULL без курса.
CREATE FUNCTION f_debts_for_period(
    p_ledger_id   uuid,
    p_from        timestamp,
    p_to          timestamp,
    p_eq_currency uuid
) RETURNS TABLE (
    counterparty_uuid     uuid,
    counterparty_name     text,
    counterparty_archived boolean,
    account_uuid          uuid,
    account_name          text,
    account_archived      boolean,
    currency_uuid         uuid,
    symbol                text,
    "precision"           smallint,
    due_date              date,
    comment               text,
    balance_from          numeric,
    inflow                numeric,
    outflow               numeric,
    balance_to            numeric,
    balance_to_eq         numeric,
    inflow_eq             numeric,
    outflow_eq            numeric
)
    LANGUAGE sql
    STABLE
    PARALLEL SAFE
AS $$
    WITH debts AS MATERIALIZED (
        SELECT vao.uuid, vao.name, vao.is_archived, vao.currency_uuid,
               ad.counterparty_uuid, ad.due_date, ad.comment
          FROM v_account_operating vao
          JOIN account_debt ad
            ON ad.ledger_id  = vao.ledger_id
           AND ad.uuid       = vao.uuid
           AND ad.deleted_at IS NULL
         WHERE vao.ledger_id = p_ledger_id
    ),
    moves AS (
        SELECT d.uuid AS account_uuid, o."date", o.amount, true AS is_in
          FROM debts d
          JOIN operation o
            ON o.ledger_id = p_ledger_id
           AND o.deleted_at IS NULL
           AND o.acc_to_uuid = d.uuid
           AND o."date" <= p_to
        UNION ALL
        SELECT d.uuid, o."date", o.amount, false
          FROM debts d
          JOIN operation o
            ON o.ledger_id = p_ledger_id
           AND o.deleted_at IS NULL
           AND o.acc_fr_uuid = d.uuid
           AND o."date" <= p_to
    ),
    sums AS (
        SELECT m.account_uuid,
               sum(CASE WHEN m.is_in THEN m.amount ELSE -m.amount END)
                   FILTER (WHERE m."date" < p_from)                      AS bal_before,
               sum(m.amount) FILTER (WHERE m."date" >= p_from AND m.is_in)     AS inflow,
               sum(m.amount) FILTER (WHERE m."date" >= p_from AND NOT m.is_in) AS outflow
          FROM moves m
         GROUP BY m.account_uuid
    ),
    eqp AS (
        SELECT eq."precision" AS p FROM currency eq WHERE eq.uuid = p_eq_currency
    )
    SELECT cp.uuid,
           cp.name,
           cp.is_archived,
           d.uuid,
           d.name,
           d.is_archived,
           c.uuid,
           c.symbol,
           c."precision",
           d.due_date,
           d.comment,
           v.bf,
           v.inflow,
           v.outflow,
           v.bf + v.inflow - v.outflow,
           round(r.rate * (v.bf + v.inflow - v.outflow), (SELECT p FROM eqp)),
           round(r.rate * v.inflow,                      (SELECT p FROM eqp)),
           round(r.rate * v.outflow,                     (SELECT p FROM eqp))
      FROM debts d
      JOIN counterparty cp
        ON cp.ledger_id = p_ledger_id
       AND cp.uuid      = d.counterparty_uuid
      JOIN currency c
        ON c.uuid = d.currency_uuid
       AND c.deleted_at IS NULL
      LEFT JOIN sums s ON s.account_uuid = d.uuid
      CROSS JOIN LATERAL (
            SELECT round(coalesce(s.bal_before, 0), c."precision") AS bf,
                   round(coalesce(s.inflow, 0),  c."precision") AS inflow,
                   round(coalesce(s.outflow, 0), c."precision") AS outflow
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
     ORDER BY cp.name, d.name, d.uuid;
$$;

COMMENT ON FUNCTION f_debts_for_period(uuid, timestamp, timestamp, uuid) IS
    'Сводка по долгам: строка на каждый живой долговой кошелёк леджера — контрагент, кошелёк, валюта, срок и комментарий займа, баланс строго до p_from, поступления и выбытия за p_from..p_to включительно, баланс на p_to включительно (= balance_from + inflow − outflow); эквиваленты по одному курсу <= p_to, NULL без курса. Знак баланса: «+» — контрагент должен, «−» — леджер должен. Миграция 000036.';

GRANT EXECUTE ON FUNCTION f_debts_for_period(uuid, timestamp, timestamp, uuid) TO wallet_reader;
