-- Доход за период с разбивкой по счёту-источнику, приведённый к валюте
-- эквивалента. Порт android-wallet/schema/select/GetIncomeForPeriod.sql.
--
-- Доход от расхода отличает НАПРАВЛЕНИЕ, а не знак суммы: строка считается
-- доходом, когда деньги идут ИЗ категории (acc_from_is_operating = false)
-- В кошелёк (acc_to_is_operating = true). amount в operation всегда
-- положительный — знак и цвет появляются только при выводе.
--
-- Границы периода включительны с обеих сторон, в отличие от f_balance_to_date,
-- где дата исключается. Это не небрежность, а разная семантика: там «состояние
-- на момент», здесь «обороты за отрезок».
--
-- Клиент отдаёт из этого запроса одно число для ячейки «Доход» на главном
-- экране, а разбивку по счетам строит отдельным запросом
-- (GenerateIncomeReportByAccount). Здесь возвращается сразу разбивка: общая
-- сумма получается из неё одним sum(), а обратно — никак.
--
-- ВАЖНО ПРО ИТОГ. sum(amount_eq) молча пропускает строки с NULL, то есть те, для
-- которых курса не нашлось: сумма окажется заниженной на неизвестную величину.
-- Вызывающий обязан проверять наличие таких строк и помечать итог неполным
-- (знак «~» против «≈» — см. android-wallet/docs/ARCHITECTURE.md, три состояния эквивалента):
--
--   SELECT sum(amount_eq)                        AS income_eq,
--          count(*) FILTER (WHERE amount_eq IS NULL) > 0 AS incomplete
--     FROM f_income_for_period(...);
--
-- Точность округления берётся JOIN'ом на currency, а не коррелированным
-- подзапросом в SELECT-листе, как было раньше (обсуждение 2026-09-08, см.
-- ту же правку в f_expanse_for_period.sql): (SELECT c."precision" FROM
-- currency c WHERE c.uuid = o.currency_uuid) коррелирует с o.currency_uuid —
-- колонкой из GROUP BY, — и потому и раньше выполнялся один раз на выходную
-- (сгруппированную) строку, а не на каждую операцию под капотом; второй
-- подзапрос (по p_eq_currency) коррелировал только с параметром функции, и
-- Postgres превращал его в InitPlan — одно выполнение на весь вызов.
-- Проблемы производительности не было, но JOIN читается прямее. max(...)
-- вокруг "precision" — не агрегация по смыслу, а обход того, что Postgres не
-- видит функциональной зависимости через JOIN (только для PK-колонки той же
-- таблицы, что стоит в GROUP BY): значение и так одно на группу.
--
-- Валютный перевод раньше раздувал и «Доход», и «Расход» одновременно (обсуждение
-- 2026-09-09, Android/TODO_transfers.md, п.3) — см. подробный разбор в
-- f_expanse_for_period.sql. Здесь исключена credit-нога (Transfer → кошелёк,
-- NOT EXISTS по operation_link.type = 0), а net (credit минус debit) добавлен
-- одной строкой на счёте «Transfer», если он положительный; при отрицательном
-- net строка уходит в f_expanse_for_period вместо этой функции.
CREATE FUNCTION f_income_for_period(
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
