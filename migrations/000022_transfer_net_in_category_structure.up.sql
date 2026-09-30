-- "Структура расходов" по категориям (f_expanse_by_category_for_period, см.
-- 000004/000005) до этой правки показывала ОБЕ ноги валютного перевода
-- гроссом на категории «Transfer» — ту же раздувающую задвоенность, которую
-- 000015_transfer_net_in_reports уже вылечила для f_income_for_period/
-- f_expanse_for_period (зеркало Android WalletDbLoader.GetTransferNetEq/
-- GenerateExpanseReportByAccount, см. Android/TODO_transfers.md п.3). f_expanse_by_category_for_period
-- туда не входила — она отдельная функция именно под веб-отчёт "Структура"
-- (см. её же комментарий в 000004), поэтому её тогда не тронули.
--
-- Тот же приём здесь: обе ноги перевода (operation_link.type = 0) исключены
-- из обычной группировки по категориям (NOT EXISTS по debit-ноге,
-- симметрично f_expanse_for_period), их net добавлен ОДНОЙ строкой на
-- счёте «Transfer», и только если net ОТРИЦАТЕЛЬНЫЙ — это отчёт по
-- расходам, положительный net (перевод вышел «в плюс») сюда, как и на
-- Android, не попадает; при net = 0 или отсутствии переводов за период
-- строка «Transfer» не появляется вовсе.
--
-- DROP+CREATE, не CREATE OR REPLACE — тот же повод, что в 000005 (список
-- колонок RETURNS TABLE у этой функции не меняется, но Postgres неспособен
-- отличить "не меняется" от "меняется" заранее, а CREATE OR REPLACE упал бы
-- при расхождении); GRANT повторяем, DROP снимает все привилегии.
DROP FUNCTION IF EXISTS f_expanse_by_category_for_period(uuid, timestamp, timestamp, uuid);

CREATE FUNCTION f_expanse_by_category_for_period(
    p_ledger_id   uuid,
    p_from        timestamp,
    p_to          timestamp,
    p_eq_currency uuid
) RETURNS TABLE (
    account_uuid  uuid,
    account_name  text,
    amount_eq     numeric,
    icon_sha256   text
)
    LANGUAGE sql
    STABLE
    PARALLEL SAFE
AS $$
    WITH transfer_net AS (
        -- credit-нога (Transfer -> кошелёк) минус debit-нога (кошелёк -> Transfer) —
        -- обе ноги одного и того же перевода, см. f_expanse_for_period (000015).
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
           round(sum(o.amount_eq),
                 (SELECT eq."precision" FROM currency eq WHERE eq.uuid = p_eq_currency))
               AS eq_value,
           encode(i.content_sha256, 'hex')
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
     GROUP BY o.acc_to_uuid, o.acc_to_name, i.content_sha256

    UNION ALL

    SELECT a.uuid, a.name,
           round(-tn.net, eq."precision"),
           encode(i.content_sha256, 'hex')
      FROM transfer_net tn
      JOIN account  a  ON a.ledger_id = p_ledger_id AND a.system_kind = 1 AND a.deleted_at IS NULL
      JOIN icon     i  ON i.uuid = a.icon_uuid
      JOIN currency eq ON eq.uuid = p_eq_currency
     WHERE tn.net < 0

     ORDER BY eq_value DESC NULLS LAST;
$$;

GRANT EXECUTE ON FUNCTION f_expanse_by_category_for_period(uuid, timestamp, timestamp, uuid) TO wallet_reader;
