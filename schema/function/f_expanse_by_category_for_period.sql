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
-- Переводы (000022_transfer_net_in_category_structure): обе ноги
-- кросс-валютного перевода (operation_link.type = 0) исключены из обычной
-- группировки, их net — одной строкой на счёте Transfer, только если он
-- отрицательный.
--
-- op_count (000030_category_month_analytics) — число операций расхода,
-- вошедших в сумму строки: у категории count(*) проводок, у Transfer — число
-- переводов (count(DISTINCT operation_link.main_uuid)).
--
-- Источник истины — реальные миграции
-- wallet-api/migrations/000004_expense_structure.up.sql,
-- 000005_expense_structure_icon.up.sql, 000022 и 000030 (см. ../../README.md
-- про этот принцип); этот файл — читаемое зеркало ИТОГОВОГО состояния.
CREATE FUNCTION f_expanse_by_category_for_period(
    p_ledger_id   uuid,
    p_from        timestamp,
    p_to          timestamp,
    p_eq_currency uuid
) RETURNS TABLE (
    account_uuid  uuid,
    account_name  text,
    amount_eq     numeric,
    icon_sha256   text,
    op_count      bigint
)
    LANGUAGE sql
    STABLE
    PARALLEL SAFE
AS $$
    WITH transfer_net AS (
        -- credit-нога (Transfer -> кошелёк) минус debit-нога (кошелёк -> Transfer) —
        -- обе ноги одного и того же перевода, см. f_expanse_for_period (000015).
        SELECT sum(CASE WHEN ol.link_uuid = o.uuid THEN o.amount_eq ELSE -o.amount_eq END) AS net,
               count(DISTINCT ol.main_uuid) AS n
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
           encode(i.content_sha256, 'hex'),
           count(*)
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
           encode(i.content_sha256, 'hex'),
           tn.n
      FROM transfer_net tn
      JOIN account  a  ON a.ledger_id = p_ledger_id AND a.system_kind = 1 AND a.deleted_at IS NULL
      JOIN icon     i  ON i.uuid = a.icon_uuid
      JOIN currency eq ON eq.uuid = p_eq_currency
     WHERE tn.net < 0

     ORDER BY eq_value DESC NULLS LAST;
$$;
