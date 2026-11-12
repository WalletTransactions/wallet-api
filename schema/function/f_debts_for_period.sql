-- Сводка «Долги» (wallet-report /debts, change debts, миграция 000036): строка
-- на каждый живой долговой кошелёк леджера — кошелёк, у которого живы account,
-- account_operating и account_debt. Нулевые, архивные и кошельки без единой
-- проводки тоже отдаются: фильтрует клиент. Контрагент — без фильтра
-- deleted_at: долг на контрагента, удалённого на другом устройстве, остаётся
-- виден, пока клиент не переклеит его на выжившего (design, Risks).
--
-- Знак баланса — направление: «+» — контрагент должен леджеру, «−» — леджер
-- должен контрагенту. Итоги «мне должны / я должен» считает wallet-report по
-- знаку; отдельной итоговой функции нет.
--
-- Границы и тождество:
-- - balance_from — сумма проводок на/с кошелька строго ДО p_from;
-- - inflow / outflow — суммы проводок на кошелёк / с кошелька за
--   p_from..p_to включительно (как у периодных функций). Прощение и проценты
--   — проводки с категорией, они входят сюда как любое движение;
-- - balance_to = balance_from + inflow − outflow — баланс на p_to
--   включительно; выводится из уже округлённых частей, так что тождество
--   держится точно.
--
-- Эквиваленты — по ОДНОМУ курсу на p_to (последний <= p_to::date), а не по
-- курсам дат проводок, как у f_assets_for_period: тождество сохраняется и в
-- эквиваленте. Без курса все *_eq — NULL (без COALESCE, см.
-- f_balance_to_date.sql, пункт 2).
--
-- Порядок — имя контрагента, имя кошелька, uuid.
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
