-- Change operations-search-summary-sql: поиск операций для wallet-mcp.
--
-- 1. f_operations_for_period и f_operations_total получают p_exclude_qs text[]
--    (последним параметром, DEFAULT NULL): операция, чей комментарий содержит
--    ЛЮБОЙ из вариантов (без регистра, ё = е, буквально), не попадает ни в
--    ленту, ни в итог. Пустой комментарий не исключается. Сигнатура меняется,
--    поэтому DROP + CREATE + GRANT (DROP снимает привилегии), как в 000032/000036.
--    Тела — дословно 000036 плюс одно условие.
-- 2. f_operations_by_category — те же фильтры, что у f_operations_total; строка
--    на категорию подходящих операций с числом, суммой и границами дат.
--    NULL-категория — прямые переводы и долги.

DROP FUNCTION f_operations_total(uuid, timestamp, timestamp, uuid, uuid[], uuid[], text, text, uuid[], text[]);
DROP FUNCTION f_operations_for_period(uuid, timestamp, timestamp, uuid, integer, timestamp, uuid, uuid[], uuid[], text, text, uuid[], text[]);

CREATE FUNCTION f_operations_for_period(
    p_ledger_id              uuid,
    p_from                   timestamp,
    p_to                     timestamp,
    p_eq_currency            uuid,
    p_limit                  integer   DEFAULT 1000,
    p_cursor_date            timestamp DEFAULT NULL,
    p_cursor_uuid            uuid      DEFAULT NULL,
    p_category_uuids         uuid[]    DEFAULT NULL,
    p_wallet_uuids           uuid[]    DEFAULT NULL,
    p_kind                   text      DEFAULT NULL,
    p_q                      text      DEFAULT NULL,
    p_exclude_category_uuids uuid[]    DEFAULT NULL,
    p_qs                     text[]    DEFAULT NULL,
    p_exclude_qs             text[]    DEFAULT NULL
) RETURNS TABLE (
    operation_uuid uuid,
    "date"         timestamp,
    kind           text,
    amount         numeric,
    currency_uuid  uuid,
    symbol         text,
    "precision"    smallint,
    amount_eq      numeric,
    comment        text,
    category_uuid  uuid,
    category_name  text,
    icon_sha256    text,
    wallet_uuid    uuid,
    wallet_name    text,
    from_uuid      uuid,
    from_name      text,
    to_uuid        uuid,
    to_name        text
)
    LANGUAGE sql
    STABLE
    PARALLEL SAFE
AS $$
    SELECT o.uuid,
           o."date",
           CASE WHEN EXISTS (SELECT 1 FROM account r
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
                ELSE                                                        'income' END,
           round(o.amount, cur."precision"),
           o.currency_uuid,
           cur.symbol,
           cur."precision",
           o.amount_eq,
           o.comment,
           cat.uuid,
           cat.name,
           encode(ic.content_sha256, 'hex'),
           wal.uuid,
           wal.name,
           o.acc_fr_uuid,
           o.acc_fr_name,
           o.acc_to_uuid,
           o.acc_to_name
      FROM v_operation_eq o
      JOIN currency cur ON cur.uuid = o.currency_uuid
      LEFT JOIN account cat
             ON cat.ledger_id = o.ledger_id
            AND cat.uuid = CASE WHEN NOT o.acc_from_is_operating THEN o.acc_fr_uuid
                                 WHEN NOT o.acc_to_is_operating  THEN o.acc_to_uuid END
      LEFT JOIN icon ic ON ic.uuid = cat.icon_uuid
      LEFT JOIN account wal
             ON wal.ledger_id = o.ledger_id
            AND wal.uuid = CASE WHEN     o.acc_from_is_operating AND NOT o.acc_to_is_operating THEN o.acc_fr_uuid
                                 WHEN NOT o.acc_from_is_operating AND     o.acc_to_is_operating THEN o.acc_to_uuid END
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
       AND (p_cursor_date IS NULL OR (o."date", o.uuid) < (p_cursor_date, p_cursor_uuid))
     ORDER BY o."date" DESC, o.uuid DESC
     LIMIT p_limit;
$$;

GRANT EXECUTE ON FUNCTION f_operations_for_period(uuid, timestamp, timestamp, uuid, integer, timestamp, uuid, uuid[], uuid[], text, text, uuid[], text[], text[]) TO wallet_reader;

COMMENT ON FUNCTION f_operations_for_period(uuid, timestamp, timestamp, uuid, integer, timestamp, uuid, uuid[], uuid[], text, text, uuid[], text[], text[]) IS
    'Лента операций периода с курсором (date, uuid) и фильтрами (категории, исключённые категории, кошельки, kind, подстрока комментария q или любой из вариантов p_qs, исключение по любому из вариантов p_exclude_qs) до курсора и LIMIT. kind: revaluation, debt (прямой перевод, ровно одна сторона — долговой кошелёк), transfer, expense, income. Необязательные параметры передаются именованной нотацией, например p_kind => $6; NULL — фильтр не задан. Миграции 000027, 000030, 000032, 000033, 000036, 000042.';

CREATE FUNCTION f_operations_total(
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
    total_eq   numeric,
    incomplete boolean,
    matched    bigint
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
               o.amount_eq
          FROM v_operation_eq o
          JOIN currency cur ON cur.uuid = o.currency_uuid
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
    SELECT COALESCE(sum(CASE WHEN p_kind IS NOT NULL THEN m.amount_eq
                             WHEN m.kind = 'income'  THEN m.amount_eq
                             WHEN m.kind = 'expense' THEN -m.amount_eq
                             ELSE 0 END), 0),
           COALESCE(bool_or(m.amount_eq IS NULL), false),
           count(*)
      FROM m;
$$;

GRANT EXECUTE ON FUNCTION f_operations_total(uuid, timestamp, timestamp, uuid, uuid[], uuid[], text, text, uuid[], text[], text[]) TO wallet_reader;

COMMENT ON FUNCTION f_operations_total(uuid, timestamp, timestamp, uuid, uuid[], uuid[], text, text, uuid[], text[], text[]) IS
    'Итог ленты по тем же фильтрам за весь период: total_eq (с p_kind — сумма, без — сальдо income − expense, переводы, долги и переоценка 0), incomplete (есть операции без курса, в сумму не вошли), matched. Ровно одна строка. Миграции 000027, 000030, 000032, 000033, 000036, 000042.';

-- Те же фильтры, строка на категорию. Категория — как в ленте: сторона проводки,
-- не являющаяся кошельком; у прямых переводов и долгов её нет (одна строка с NULL).
-- Знак total_eq — как у f_operations_total, поэтому сумма по строкам равна его итогу.
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

GRANT EXECUTE ON FUNCTION f_operations_by_category(uuid, timestamp, timestamp, uuid, uuid[], uuid[], text, text, uuid[], text[], text[]) TO wallet_reader;

COMMENT ON FUNCTION f_operations_by_category(uuid, timestamp, timestamp, uuid, uuid[], uuid[], text, text, uuid[], text[], text[]) IS
    'Те же фильтры, что у f_operations_total, но строка на категорию подходящих операций: matched, total_eq (знак как у f_operations_total), first_date, last_date. Прямые переводы и долги — одна строка с NULL-категорией. Миграция 000042.';
