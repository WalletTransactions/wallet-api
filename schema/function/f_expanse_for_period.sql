-- Расход за период с разбивкой по счёту-получателю, приведённый к валюте
-- эквивалента. Порт android-wallet/schema/select/GetExpanseForPeriod.sql.
--
-- Зеркально f_income_for_period: расходом строка считается, когда деньги идут ИЗ
-- кошелька (acc_from_is_operating = true) В категорию (acc_to_is_operating =
-- false). Сумма и здесь приходит положительной — знак и красный цвет расход
-- получает только на экране.
--
-- Границы периода включительны с обеих сторон.
--
-- Точность округления берётся JOIN'ом на currency, а не коррелированным
-- подзапросом в SELECT-листе, как было раньше (обсуждение 2026-09-08):
-- (SELECT c."precision" FROM currency c WHERE c.uuid = o.currency_uuid)
-- коррелирует с o.currency_uuid — колонкой из GROUP BY, — и потому и раньше
-- выполнялся один раз на выходную (сгруппированную) строку, а не на каждую
-- операцию под капотом; (SELECT eq."precision" ... WHERE eq.uuid =
-- p_eq_currency) коррелирует только с параметром функции, и Postgres превращал
-- его в InitPlan — ровно одно выполнение на весь вызов. То есть проблемы
-- производительности не было, но JOIN читается прямее и не требует от
-- каждого нового читателя заново продумывать эту тонкость. max(...) вокруг
-- "precision" — не агрегация по смыслу, а обход того, что Postgres не видит
-- функциональной зависимости через JOIN (видит только для PK-колонки той же
-- таблицы, что стоит в GROUP BY): значение и так одно на группу.
--
-- Про итог действует ровно та же оговорка, что и у дохода: sum(amount_eq)
-- пропускает строки без курса и занижает результат молча, поэтому итог берётся
-- вместе с признаком неполноты:
--
--   SELECT sum(amount_eq)                                 AS expanse_eq,
--          count(*) FILTER (WHERE amount_eq IS NULL) > 0  AS incomplete
--     FROM f_expanse_for_period(...);
--
-- Кстати о расхождении, известном в клиенте: там в
-- WalletDbLoader.GenerateIncomeReportByAccount и GenerateExpanseReportByAccount
-- строка с dataFilter.getSQLFilter() закомментирована, из-за чего «Доход» и
-- «Расход» в карточке остатков считаются по ВСЕМ счетам даже при выбранном
-- фильтре (android-wallet/docs/TODO.md). Здесь фильтра нет вовсе: отбор счетов — забота
-- вызывающего, и добавлять его надо сразу в оба места, иначе расхождение
-- переедет на сервер.
--
-- Валютный перевод раньше раздувал и «Доход», и «Расход» одновременно (обсуждение
-- 2026-09-09, android-wallet/docs/TODO_transfers.md, п.3): его debit-нога (кошелёк → Transfer)
-- считалась здесь полноценным расходом, а credit-нога (Transfer → кошелёк) —
-- полноценным доходом в f_income_for_period, хотя по факту это одна и та же
-- сумма денег, просто в двух валютах. Обе ноги теперь исключены отсюда
-- (NOT EXISTS по operation_link.type = 0, см. OperationItem.LinkType на
-- клиенте — привязка через связь, а не через system_kind счёта, иначе сюда
-- попал бы и разовый ручной расход/доход, заведённый прямо на категорию
-- «Transfer»: пикер счетов её не прячет), а их net (credit минус debit —
-- обычно это и есть весь спред перевода) добавлен ниже одной строкой на счёте
-- «Transfer», если он отрицательный (перевод обошёлся «в минус»); при
-- положительном net строка уходит в f_income_for_period вместо этой функции.
CREATE FUNCTION f_expanse_for_period(
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
