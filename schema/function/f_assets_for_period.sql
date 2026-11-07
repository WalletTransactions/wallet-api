-- Отчёт «Капитал» (wallet-report /api/reports/assets, change capital-assets,
-- миграция 000033): строка на каждый живой актив леджера — кошелёк, у
-- которого живы account, account_operating и account_asset
-- (v_account_operating.asset_type IS NOT NULL). Проданные (оценка 0) и
-- архивные тоже отдаются: is_archived фильтрует клиент.
--
-- Тождество «оценка = вложено + переоценка»:
-- - value — остаток актива по всем проводкам с date <= p_to (граница
--   включительно, как у периодных функций; балансовые берут «строго до»);
-- - revaluation_total — сумма проводок переоценки с date <= p_to: одна из
--   сторон — счёт с system_kind = 3 (тот же предикат, что исключает её из
--   дохода/расхода, без фильтра deleted_at); к активу +, от актива −;
-- - revaluation_period — то же за p_from..p_to включительно;
-- - invested = value − revaluation_total: всё, кроме переоценки, — покупка,
--   ремонт, продажа, ноги разновалютного перевода через Transfer. Выводится
--   вычитанием, а не суммой «переводов»: у разновалютной покупки нога в актив
--   идёт от категории Transfer, а не от кошелька, и перечисление «настоящих
--   вложений» по виду контрагента её бы потеряло;
-- - return_pct = (value / invested − 1) × 100, без округления (форматирует
--   wallet-report); NULL, если invested <= 0.
--
-- Эквиваленты — по ОДНОМУ курсу на p_to (последний <= p_to::date), а не по
-- курсам дат проводок: «вложено в эквиваленте» — сколько вложенное стоит в
-- валюте отчёта сейчас. invested_eq выводится вычитанием округлённых
-- value_eq и revaluation_total_eq, так что тождество держится и после
-- округления; то же для invested в своей валюте. Без курса все *_eq — NULL
-- (без COALESCE, см. f_balance_to_date.sql, пункт 2).
--
-- Порядок — value_eq убыв. (NULLS LAST), затем имя.
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
