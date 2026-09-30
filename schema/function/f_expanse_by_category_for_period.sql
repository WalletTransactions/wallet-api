-- "Структура расходов" (веб-отчёт, wallet-api/src/reports_repo.cpp
-- ::expense_structure_for_period) — доля КАЖДОЙ категории в расходе за
-- период. Отдельная функция, а не переиспользование f_expanse_for_period:
-- та группирует по (категория, валюта операции) — правильно для плоского
-- списка расхода, но для доли категории в общем расходе валюты нужно
-- СМЕШАТЬ: одна и та же категория, оплаченная в двух валютах кошелька,
-- обязана стать ОДНОЙ строкой в структуре, иначе её доля молча разъедется
-- на две меньшие. Группировка здесь — только по category (acc_to_uuid);
-- валюты уже сведены через amount_eq, поэтому "своя" сумма (amount в валюте
-- счёта) теряет смысл и не возвращается вовсе, в отличие от
-- f_expanse_for_period/f_income_for_period.
--
-- Не порт клиентского запроса (в отличие от остальных функций в этой папке,
-- см. README.md) — эта агрегация нужна только веб-отчёту, в Android-клиенте
-- её нет.
--
-- icon_sha256 — добавлено 000005_expense_structure_icon.up.sql (иконка
-- категории на веб-экране "Структура расходов"): account.icon_uuid NOT NULL
-- REFERENCES icon(uuid), значит у каждой категории иконка есть гарантированно;
-- сама картинка — в blob.sha256 (icon.content_sha256, WEBP 256x256, см.
-- table/blob.sql), которую веб-клиент скачивает как есть через уже
-- существующий GET /sync/blobs/:sha256 — сессионной куки достаточно, device_id
-- не нужен (см. blob.hpp). encode(...,'hex') — тот же приём, что hex_columns
-- в протоколе синка (sync_repo.cpp), только прямо в SQL: это одна функция,
-- не общий механизм.
--
-- Источник истины — реальные миграции
-- wallet-api/migrations/000004_expense_structure.up.sql +
-- 000005_expense_structure_icon.up.sql (см. ../../README.md про этот
-- принцип); этот файл — читаемое зеркало ИТОГОВОГО состояния после обеих.
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
     GROUP BY o.acc_to_uuid, o.acc_to_name, i.content_sha256
     ORDER BY eq_value DESC NULLS LAST;
$$;
