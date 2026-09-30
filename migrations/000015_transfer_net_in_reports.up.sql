-- Валютный перевод раньше раздувал и «Доход», и «Расход» одновременно (обсуждение
-- 2026-09-09, Android/TODO_transfers.md, п.3): его debit-нога (кошелёк → Transfer)
-- считалась в f_expanse_for_period полноценным расходом, а credit-нога
-- (Transfer → кошелёк) — полноценным доходом в f_income_for_period, хотя по факту
-- это одна и та же сумма денег, просто в двух валютах.
--
-- Обе ноги теперь исключены из своих гросс-сумм (NOT EXISTS по
-- operation_link.type = 0, см. OperationItem.LinkType на клиенте — привязка через
-- связь, а не через system_kind счёта, иначе сюда попал бы и разовый ручной
-- расход/доход, заведённый прямо на категорию «Transfer»: пикер счетов её не
-- прячет), а их net (credit минус debit — обычно это и есть весь спред перевода)
-- добавлен одной строкой на счёте «Transfer» в ту из двух функций, куда указывает
-- его знак: положительный — в f_income_for_period, отрицательный — в
-- f_expanse_for_period.
--
-- Только замена тела функций (тот же приём, что 000009_report_precision_join):
-- сигнатура, RETURNS TABLE не меняются, GRANT из 000002 трогать не нужно.
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
        -- обе ноги одного и того же перевода.
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
