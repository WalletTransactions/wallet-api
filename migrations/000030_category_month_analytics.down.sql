-- Откат 000030_category_month_analytics.up.sql: удаляется
-- f_expense_by_category_by_month; f_expanse_by_category_for_period возвращается к
-- телу 000022 (без op_count), f_operations_for_period / f_operations_total — к
-- телам 000027 (без p_exclude_category_uuids), дословно, с их GRANT и COMMENT.
-- wallet-report с /expense-by-category-by-month, op_count и
-- exclude_category_uuid откатывается раньше этой миграции: после down новая
-- функция и параметр p_exclude_category_uuids неизвестны.
DROP FUNCTION f_expense_by_category_by_month(uuid, timestamp, timestamp, uuid);

-- f_expanse_by_category_for_period — как в 000022.
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

-- f_operations_for_period / f_operations_total — как в 000027.
DROP FUNCTION f_operations_total(uuid, timestamp, timestamp, uuid, uuid[], uuid[], text, text, uuid[]);
DROP FUNCTION f_operations_for_period(uuid, timestamp, timestamp, uuid, integer, timestamp, uuid, uuid[], uuid[], text, text, uuid[]);

CREATE FUNCTION f_operations_for_period(
    p_ledger_id      uuid,
    p_from           timestamp,
    p_to             timestamp,
    p_eq_currency    uuid,
    p_limit          integer   DEFAULT 1000,
    p_cursor_date    timestamp DEFAULT NULL,
    p_cursor_uuid    uuid      DEFAULT NULL,
    p_category_uuids uuid[]    DEFAULT NULL,
    p_wallet_uuids   uuid[]    DEFAULT NULL,
    p_kind           text      DEFAULT NULL,
    p_q              text      DEFAULT NULL
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
           CASE WHEN o.acc_from_is_operating AND o.acc_to_is_operating THEN 'transfer'
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
       AND (p_wallet_uuids IS NULL
            OR (o.acc_from_is_operating AND o.acc_fr_uuid = ANY (p_wallet_uuids))
            OR (o.acc_to_is_operating   AND o.acc_to_uuid = ANY (p_wallet_uuids)))
       AND (p_kind IS NULL
            OR CASE WHEN o.acc_from_is_operating AND o.acc_to_is_operating THEN 'transfer'
                    WHEN o.acc_from_is_operating                           THEN 'expense'
                    ELSE                                                        'income' END = p_kind)
       AND (p_q IS NULL
            OR strpos(lower(translate(o.comment, 'Ёё', 'Ее')), lower(translate(p_q, 'Ёё', 'Ее'))) > 0)
       AND (p_cursor_date IS NULL OR (o."date", o.uuid) < (p_cursor_date, p_cursor_uuid))
     ORDER BY o."date" DESC, o.uuid DESC
     LIMIT p_limit;
$$;

-- Правило знака total_eq (D4): p_kind задан — сумма amount_eq подходящих операций,
-- неотрицательная; не задан — сальдо Σ income − Σ expense, прямые переводы
-- кошелёк → кошелёк дают 0 (деньги не выходят из кошельков пользователя).
-- Операции без курса к p_eq_currency (amount_eq IS NULL) в сумму не входят и дают
-- incomplete = true. Пустой результат — 0 / false / 0. JOIN currency — тот же, что
-- у ленты: matched обязан совпасть с числом строк по всем её страницам.
CREATE FUNCTION f_operations_total(
    p_ledger_id      uuid,
    p_from           timestamp,
    p_to             timestamp,
    p_eq_currency    uuid,
    p_category_uuids uuid[] DEFAULT NULL,
    p_wallet_uuids   uuid[] DEFAULT NULL,
    p_kind           text   DEFAULT NULL,
    p_q              text   DEFAULT NULL
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
        SELECT CASE WHEN o.acc_from_is_operating AND o.acc_to_is_operating THEN 'transfer'
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
           AND (p_wallet_uuids IS NULL
                OR (o.acc_from_is_operating AND o.acc_fr_uuid = ANY (p_wallet_uuids))
                OR (o.acc_to_is_operating   AND o.acc_to_uuid = ANY (p_wallet_uuids)))
           AND (p_kind IS NULL
                OR CASE WHEN o.acc_from_is_operating AND o.acc_to_is_operating THEN 'transfer'
                        WHEN o.acc_from_is_operating                           THEN 'expense'
                        ELSE                                                        'income' END = p_kind)
           AND (p_q IS NULL
                OR strpos(lower(translate(o.comment, 'Ёё', 'Ее')), lower(translate(p_q, 'Ёё', 'Ее'))) > 0)
    )
    SELECT COALESCE(sum(CASE WHEN p_kind IS NOT NULL THEN m.amount_eq
                             WHEN m.kind = 'income'  THEN m.amount_eq
                             WHEN m.kind = 'expense' THEN -m.amount_eq
                             ELSE 0 END), 0),
           COALESCE(bool_or(m.amount_eq IS NULL), false),
           count(*)
      FROM m;
$$;

GRANT EXECUTE ON FUNCTION f_operations_for_period(uuid, timestamp, timestamp, uuid, integer, timestamp, uuid, uuid[], uuid[], text, text) TO wallet_reader;
GRANT EXECUTE ON FUNCTION f_operations_total(uuid, timestamp, timestamp, uuid, uuid[], uuid[], text, text) TO wallet_reader;

COMMENT ON FUNCTION f_operations_for_period(uuid, timestamp, timestamp, uuid, integer, timestamp, uuid, uuid[], uuid[], text, text) IS
    'Лента операций периода с курсором (date, uuid) и фильтрами (категории, кошельки, kind, подстрока комментария q) до курсора и LIMIT. Необязательные параметры передаются именованной нотацией, например p_kind => $6; NULL — фильтр не задан. Миграция 000027.';
COMMENT ON FUNCTION f_operations_total(uuid, timestamp, timestamp, uuid, uuid[], uuid[], text, text) IS
    'Итог ленты по тем же фильтрам за весь период: total_eq (с p_kind — сумма, без — сальдо income − expense, переводы 0), incomplete (есть операции без курса, в сумму не вошли), matched. Ровно одна строка. Миграция 000027.';
