-- "Кошельки и остатки" — по прямому запросу ("правь все пункты по нагрузке"):
-- f_wallet_turnover_for_period (000010) резолвила курс эквивалента через
-- v_operation_eq ДВАЖДЫ — отдельным LEFT JOIN на "пришло" (сгруппировано по
-- acc_to_uuid) и отдельным на "ушло" (по acc_fr_uuid). v_operation_eq — это
-- LATERAL-резолв курса на КАЖДУЮ операцию периода (см. её комментарий) —
-- считать его дважды значило бы дважды резолвить курс для одних и тех же
-- операций, хотя число само по себе (amount_eq) от того, куда его потом
-- отнести (в "пришло" ЭТОГО счёта или в "ушло" ЭТОГО счёта), не зависит.
--
-- Здесь v_operation_eq сканируется ОДИН раз (CTE oe, MATERIALIZED — тот же
-- приём и та же причина, что у running в f_balance_series/f_balance_to_dates,
-- 000019: без явного MATERIALIZED планировщик мог бы решить пересчитать её
-- заново на каждый счёт при джойне ниже, вместо честного одного прохода),
-- а разнесение по "пришло"/"ушло" на каждый счёт — это уже UNION ALL двух
-- ДЁШЕВЫХ SELECT'ов НАД уже посчитанным amount_eq (без нового резолва курса)
-- и один GROUP BY с FILTER вместо двух отдельных LEFT JOIN.
--
-- "Своя" сумма (opt/opf, на operation напрямую, без курса) НЕ трогается —
-- там резолва курса и так нет, дублировать сканирование там вдвое дешевле,
-- чем на v_operation_eq, и трогать не было прямого запроса.
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
    ),
    oe_by_account AS (
        SELECT acc_to_uuid AS acc_uuid, amount_eq, true AS is_in FROM oe
        UNION ALL
        SELECT acc_fr_uuid AS acc_uuid, amount_eq, false AS is_in FROM oe
    ),
    oe_agg AS (
        SELECT acc_uuid,
               sum(amount_eq) FILTER (WHERE is_in)            AS amount_in_eq,
               sum(amount_eq) FILTER (WHERE NOT is_in)         AS amount_out_eq,
               bool_or(amount_eq IS NULL) FILTER (WHERE is_in) AS incomplete_in,
               bool_or(amount_eq IS NULL) FILTER (WHERE NOT is_in) AS incomplete_out
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
             GROUP BY o.acc_to_uuid
           ) opt ON opt.acc_to_uuid = vao.uuid
      LEFT JOIN (
            SELECT o.acc_fr_uuid, sum(o.amount) AS amount_fr
              FROM operation o
             WHERE o.ledger_id = p_ledger_id
               AND o.deleted_at IS NULL
               AND o."date" BETWEEN p_from AND p_to
             GROUP BY o.acc_fr_uuid
           ) opf ON opf.acc_fr_uuid = vao.uuid
      LEFT JOIN oe_agg ON oe_agg.acc_uuid = vao.uuid
     WHERE vao.ledger_id = p_ledger_id
     ORDER BY vao.name;
$$;

-- Сигнатура и RETURNS TABLE не меняются, GRANT из 000010 трогать не нужно.
