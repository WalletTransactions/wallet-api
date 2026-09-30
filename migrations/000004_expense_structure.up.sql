-- "Структура расходов" (servers/Design/.../Отчёты - веб.dc.html, экран
-- "структура") — GET /api/reports/expense-structure (servers/wallet-api,
-- reports_repo.cpp::expense_structure_for_period).
--
-- Новая функция, а не переиспользование f_expanse_for_period: та группирует
-- по (категория, валюта операции) — правильно для плоского списка расхода,
-- но для доли категории в общем расходе валюты нужно СМЕШАТЬ: одна и та же
-- категория, оплаченная в двух валютах кошелька, обязана стать ОДНОЙ строкой
-- в структуре, иначе её доля в целом молча разъедется на две меньшие. Здесь
-- группировка по одной category (acc_to_uuid) — валюты уже сведены через
-- amount_eq, поэтому "своя" сумма (amount в валюте счёта) теряет смысл и не
-- возвращается вовсе, в отличие от f_expanse_for_period/f_income_for_period.
--
-- Не порт клиентского запроса (в отличие от f_balance_to_date/f_income_for_period/
-- f_expanse_for_period, см. schema/server/function/README.md) — это
-- агрегация, которой в Android-клиенте нет вообще, нужна только этому
-- веб-отчёту.
CREATE FUNCTION f_expanse_by_category_for_period(
    p_ledger_id   uuid,
    p_from        timestamp,
    p_to          timestamp,
    p_eq_currency uuid
) RETURNS TABLE (
    account_uuid  uuid,
    account_name  text,
    amount_eq     numeric
)
    LANGUAGE sql
    STABLE
    PARALLEL SAFE
AS $$
    SELECT o.acc_to_uuid,
           o.acc_to_name,
           round(sum(o.amount_eq),
                 (SELECT eq."precision" FROM currency eq WHERE eq.uuid = p_eq_currency))
               AS eq_value
      FROM v_operation_eq o
     WHERE o.ledger_id        = p_ledger_id
       AND o.to_currency_uuid = p_eq_currency
       AND o."date" BETWEEN p_from AND p_to
       AND o.acc_from_is_operating
       AND NOT o.acc_to_is_operating
     GROUP BY o.acc_to_uuid, o.acc_to_name
     ORDER BY eq_value DESC NULLS LAST;
$$;

GRANT EXECUTE ON FUNCTION f_expanse_by_category_for_period(uuid, timestamp, timestamp, uuid) TO wallet_reader;
