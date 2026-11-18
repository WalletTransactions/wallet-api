-- Операции по категориям (change operations-search-summary-sql, миграция 000042)
-- — по ТЕМ ЖЕ условиям, что f_operations_total (категории, исключённые категории,
-- кошельки, kind, q, варианты q, исключение по вариантам p_exclude_qs), но
-- строка на категорию подходящих операций: matched, total_eq, первая и
-- последняя дата. Нужна wallet-report для блоков summary и other_matches
-- (`/api/reports/operations?summary=true`) и через него — wallet-mcp.
--
-- Категория — как у ленты: сторона проводки, не являющаяся кошельком. У прямых
-- переводов и долгов её нет — одна строка с NULL в category_uuid.
-- Знак total_eq — как у f_operations_total (с p_kind — сумма, без — сальдо),
-- поэтому сумма total_eq и matched по строкам равна его итогу при тех же
-- аргументах. Операции без курса входят в matched и даты, в total_eq — нет.
-- Строки — по убыванию total_eq, затем по имени категории.
--
-- Источник истины — миграция wallet-api/migrations/000042_operations_search_summary.up.sql;
-- этот файл — читаемое зеркало.
CREATE FUNCTION f_operations_by_category(
    p_ledger_id              uuid,
    p_from                   timestamp,
    p_to                     timestamp,
    p_eq_currency            uuid,
    p_category_uuids         uuid[] DEFAULT NULL,
    p_wallet_uuids           uuid[] DEFAULT NULL,
    p_kind                   text   DEFAULT NULL,
    p_q                      text   DEFAULT NULL,
    p_exclude_category_uuids uuid[] DEFAULT NULL,
    p_qs                     text[] DEFAULT NULL,
    p_exclude_qs             text[] DEFAULT NULL
) RETURNS TABLE (
    category_uuid uuid,
    category_name text,
    matched       bigint,
    total_eq      numeric,
    first_date    timestamp,
    last_date     timestamp
)
    LANGUAGE sql
    STABLE
    PARALLEL SAFE
AS $$
    WITH m AS (
        SELECT CASE WHEN EXISTS (SELECT 1 FROM account r
                                 WHERE r.ledger_id = p_ledger_id
                                   AND r.uuid IN (o.acc_fr_uuid, o.acc_to_uuid)
                                   AND r.system_kind = 3)                    THEN 'revaluation'
                    WHEN o.acc_from_is_operating AND o.acc_to_is_operating
                     AND EXISTS (SELECT 1 FROM account_debt d
                                  WHERE d.ledger_id = p_ledger_id AND d.uuid = o.acc_fr_uuid
                                    AND d.deleted_at IS NULL)
                      <> EXISTS (SELECT 1 FROM account_debt d
                                  WHERE d.ledger_id = p_ledger_id AND d.uuid = o.acc_to_uuid
                                    AND d.deleted_at IS NULL)                THEN 'debt'
                    WHEN o.acc_from_is_operating AND o.acc_to_is_operating THEN 'transfer'
                    WHEN o.acc_from_is_operating                           THEN 'expense'
                    ELSE                                                        'income' END AS kind,
               o.amount_eq,
               o."date",
               cat.uuid AS cat_uuid,
               cat.name AS cat_name
          FROM v_operation_eq o
          JOIN currency cur ON cur.uuid = o.currency_uuid
          LEFT JOIN account cat
                 ON cat.ledger_id = o.ledger_id
                AND cat.uuid = CASE WHEN NOT o.acc_from_is_operating THEN o.acc_fr_uuid
                                     WHEN NOT o.acc_to_is_operating  THEN o.acc_to_uuid END
         WHERE o.ledger_id        = p_ledger_id
           AND o.to_currency_uuid = p_eq_currency
           AND o."date" BETWEEN p_from AND p_to
           AND (p_category_uuids IS NULL
                OR (NOT o.acc_from_is_operating AND o.acc_fr_uuid = ANY (p_category_uuids))
                OR (NOT o.acc_to_is_operating   AND o.acc_to_uuid = ANY (p_category_uuids)))
           AND (p_exclude_category_uuids IS NULL
                OR NOT ((NOT o.acc_from_is_operating AND o.acc_fr_uuid = ANY (p_exclude_category_uuids))
                     OR (NOT o.acc_to_is_operating   AND o.acc_to_uuid = ANY (p_exclude_category_uuids))))
           AND (p_wallet_uuids IS NULL
                OR (o.acc_from_is_operating AND o.acc_fr_uuid = ANY (p_wallet_uuids))
                OR (o.acc_to_is_operating   AND o.acc_to_uuid = ANY (p_wallet_uuids)))
           AND (p_kind IS NULL
                OR CASE WHEN EXISTS (SELECT 1 FROM account r
                                     WHERE r.ledger_id = p_ledger_id
                                       AND r.uuid IN (o.acc_fr_uuid, o.acc_to_uuid)
                                       AND r.system_kind = 3)                    THEN 'revaluation'
                        WHEN o.acc_from_is_operating AND o.acc_to_is_operating
                         AND EXISTS (SELECT 1 FROM account_debt d
                                      WHERE d.ledger_id = p_ledger_id AND d.uuid = o.acc_fr_uuid
                                        AND d.deleted_at IS NULL)
                          <> EXISTS (SELECT 1 FROM account_debt d
                                      WHERE d.ledger_id = p_ledger_id AND d.uuid = o.acc_to_uuid
                                        AND d.deleted_at IS NULL)                THEN 'debt'
                        WHEN o.acc_from_is_operating AND o.acc_to_is_operating THEN 'transfer'
                        WHEN o.acc_from_is_operating                           THEN 'expense'
                        ELSE                                                        'income' END = p_kind)
           AND (p_q IS NULL
                OR strpos(lower(translate(o.comment, 'Ёё', 'Ее')), lower(translate(p_q, 'Ёё', 'Ее'))) > 0)
           AND (p_qs IS NULL
                OR EXISTS (SELECT 1 FROM unnest(p_qs) AS v(q)
                            WHERE strpos(lower(translate(o.comment, 'Ёё', 'Ее')), lower(translate(v.q, 'Ёё', 'Ее'))) > 0))
           AND (p_exclude_qs IS NULL
                OR o.comment IS NULL
                OR NOT EXISTS (SELECT 1 FROM unnest(p_exclude_qs) AS v(q)
                                WHERE strpos(lower(translate(o.comment, 'Ёё', 'Ее')), lower(translate(v.q, 'Ёё', 'Ее'))) > 0))
    )
    SELECT m.cat_uuid,
           m.cat_name,
           count(*),
           COALESCE(sum(CASE WHEN p_kind IS NOT NULL THEN m.amount_eq
                             WHEN m.kind = 'income'  THEN m.amount_eq
                             WHEN m.kind = 'expense' THEN -m.amount_eq
                             ELSE 0 END), 0),
           min(m."date"),
           max(m."date")
      FROM m
     GROUP BY m.cat_uuid, m.cat_name
     ORDER BY 4 DESC, m.cat_name;
$$;

COMMENT ON FUNCTION f_operations_by_category(uuid, timestamp, timestamp, uuid, uuid[], uuid[], text, text, uuid[], text[], text[]) IS
    'Те же фильтры, что у f_operations_total, но строка на категорию подходящих операций: matched, total_eq (знак как у f_operations_total), first_date, last_date. Прямые переводы и долги — одна строка с NULL-категорией. Миграция 000042.';
