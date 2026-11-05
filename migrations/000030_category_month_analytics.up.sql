-- Аналитика по категориям для wallet-mcp (change wallet-report
-- add-category-month-analytics; потребитель — wallet-mcp add-category-analytics):
--
-- 1. f_expense_by_category_by_month — расход «категория × календарный месяц»
--    по правилам «Структуры расходов» (design D1, D2).
-- 2. f_expanse_by_category_for_period — новая колонка op_count (D3).
-- 3. f_operations_for_period / f_operations_total — трейлинг-параметр
--    p_exclude_category_uuids uuid[] DEFAULT NULL (D4).
--
-- Тела взяты из последних миграций, где функции менялись: 000022
-- (f_expanse_by_category_for_period, погашение ног перевода) и 000027
-- (f_operations_for_period, f_operations_total, фильтры). 000028/000029 их не
-- трогали; capital-assets на момент миграции не реализован.
--
-- Везде DROP + CREATE, не CREATE OR REPLACE: у f_expanse_by_category_for_period
-- меняется RETURNS TABLE, у функций операций — список параметров (CREATE OR
-- REPLACE с новым параметром завёл бы перегрузку рядом со старой, и вызов без
-- нового параметра стал бы неоднозначным). DROP снимает привилегии — GRANT
-- повторяется.

-- ---------------------------------------------------------------------------
-- 1. op_count в «Структуре расходов» (D3)
-- ---------------------------------------------------------------------------
-- op_count — число операций расхода, вошедших в сумму строки: у обычной
-- категории count(*) её проводок за период, у Transfer — число переводов
-- (count(DISTINCT operation_link.main_uuid)), чья разница ног вошла в net.
-- Колонка добавлена В КОНЕЦ: вызывающие выбирают колонки по имени, старый
-- wallet-report её просто не читает.
DROP FUNCTION f_expanse_by_category_for_period(uuid, timestamp, timestamp, uuid);

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

GRANT EXECUTE ON FUNCTION f_expanse_by_category_for_period(uuid, timestamp, timestamp, uuid) TO wallet_reader;

-- ---------------------------------------------------------------------------
-- 2. Расход по категориям помесячно (D1, D2)
-- ---------------------------------------------------------------------------
-- Одна строка на НЕПУСТУЮ пару (категория, календарный месяц); месяцы без
-- расхода не возвращаются (их список вызывающий строит сам из p_from/p_to).
-- Месяц — date_trunc('month', o."date"), без перевода часового пояса, как у
-- f_income_expense_by_month.
--
-- Правила группировки — те же, что у f_expanse_by_category_for_period, НЕ у
-- f_income_expense_by_month: ноги кросс-валютного перевода исключены из
-- обычных категорий и сведены в Transfer как net. Поэтому сумма матрицы за
-- период совпадает со «Структурой расходов», а не с «Обзором».
--
-- Transfer: месячная сумма — минус net ног перевода этого месяца; месяц с
-- выигрышем на курсе даёт отрицательную сумму, месяц с net = 0 не
-- возвращается. Сама категория Transfer есть в результате, только если net
-- за ВЕСЬ период отрицателен — то же условие, что у строки Transfer в
-- структуре, поэтому месяцы Transfer в сумме дают её итог.
--
-- Колонки категории и общего итога (D2) — агрегаты в самом запросе, а не
-- сложение у вызывающего:
-- - category_amount_eq — round(sum(amount_eq) за весь период) по категории,
--   ровно amount_eq её строки в f_expanse_by_category_for_period (округление
--   суммы, а не сумма округлённых месяцев);
-- - category_op_count — op_count той же строки;
-- - total_eq — сумма category_amount_eq по всем категориям, как total_eq у
--   /expense-structure (сумма округлённых строк);
-- - incomplete — в клетке есть операции без курса к p_eq_currency
--   (bool_or(amount_eq IS NULL), правило f_income_expense_by_month); в сумму
--   они не вошли.
-- Повторяются в каждой строке месяца категории (total_eq — в каждой строке).
CREATE FUNCTION f_expense_by_category_by_month(
    p_ledger_id   uuid,
    p_from        timestamp,
    p_to          timestamp,
    p_eq_currency uuid
) RETURNS TABLE (
    account_uuid       uuid,
    account_name       text,
    icon_sha256        text,
    month_start        date,
    amount_eq          numeric,
    op_count           bigint,
    incomplete         boolean,
    category_amount_eq numeric,
    category_op_count  bigint,
    total_eq           numeric
)
    LANGUAGE sql
    STABLE
    PARALLEL SAFE
AS $$
    WITH prec AS (
        SELECT eq."precision" AS p FROM currency eq WHERE eq.uuid = p_eq_currency
    ),
    regular AS (
        SELECT o.acc_to_uuid                          AS account_uuid,
               date_trunc('month', o."date")::date    AS month_start,
               sum(o.amount_eq)                       AS amt,
               count(*)                               AS n,
               bool_or(o.amount_eq IS NULL)           AS inc
          FROM v_operation_eq o
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
         GROUP BY o.acc_to_uuid, date_trunc('month', o."date")
    ),
    transfer_legs AS (
        SELECT date_trunc('month', o."date")::date AS month_start,
               ol.main_uuid,
               CASE WHEN ol.link_uuid = o.uuid THEN o.amount_eq ELSE -o.amount_eq END AS signed_eq,
               o.amount_eq IS NULL AS no_rate
          FROM v_operation_eq o
          JOIN operation_link ol
            ON ol.ledger_id = p_ledger_id
           AND (ol.main_uuid = o.uuid OR ol.link_uuid = o.uuid)
           AND ol.type = 0
           AND ol.deleted_at IS NULL
         WHERE o.ledger_id        = p_ledger_id
           AND o.to_currency_uuid = p_eq_currency
           AND o."date" BETWEEN p_from AND p_to
    ),
    transfer_account AS (
        SELECT a.uuid FROM account a
         WHERE a.ledger_id = p_ledger_id AND a.system_kind = 1 AND a.deleted_at IS NULL
    ),
    cats AS (
        SELECT r.account_uuid, sum(r.amt) AS amt, sum(r.n)::bigint AS n
          FROM regular r
         GROUP BY r.account_uuid
        UNION ALL
        SELECT ta.uuid, -sum(tl.signed_eq), count(DISTINCT tl.main_uuid)
          FROM transfer_legs tl CROSS JOIN transfer_account ta
         GROUP BY ta.uuid
        HAVING sum(tl.signed_eq) < 0
    ),
    cells AS (
        SELECT r.account_uuid, r.month_start, r.amt, r.n, r.inc
          FROM regular r
        UNION ALL
        SELECT ta.uuid, tl.month_start, -sum(tl.signed_eq), count(DISTINCT tl.main_uuid), bool_or(tl.no_rate)
          FROM transfer_legs tl CROSS JOIN transfer_account ta
         GROUP BY ta.uuid, tl.month_start
        HAVING sum(tl.signed_eq) IS DISTINCT FROM 0
    ),
    cats_rounded AS (
        SELECT c.account_uuid, round(c.amt, (SELECT p FROM prec)) AS amt, c.n FROM cats c
    )
    SELECT c.account_uuid,
           a.name,
           encode(i.content_sha256, 'hex'),
           m.month_start,
           round(m.amt, (SELECT p FROM prec)),
           m.n::bigint,
           m.inc,
           c.amt,
           c.n,
           (SELECT COALESCE(sum(cr.amt), 0) FROM cats_rounded cr)
      FROM cats_rounded c
      JOIN cells   m ON m.account_uuid = c.account_uuid
      JOIN account a ON a.ledger_id = p_ledger_id AND a.uuid = c.account_uuid
      JOIN icon    i ON i.uuid = a.icon_uuid
     ORDER BY c.amt DESC NULLS LAST, c.account_uuid, m.month_start;
$$;

GRANT EXECUTE ON FUNCTION f_expense_by_category_by_month(uuid, timestamp, timestamp, uuid) TO wallet_reader;

COMMENT ON FUNCTION f_expense_by_category_by_month(uuid, timestamp, timestamp, uuid) IS
    'Расход «категория × календарный месяц» по правилам f_expanse_by_category_for_period (ноги перевода сведены в Transfer): строка на непустую клетку с суммой, числом операций и incomplete; итог и число операций категории за период и общий total_eq — в каждой строке. Миграция 000030.';

-- ---------------------------------------------------------------------------
-- 3. Исключение категорий в ленте и итоге операций (D4)
-- ---------------------------------------------------------------------------
-- p_exclude_category_uuids — операции, чья НЕОПЕРАЦИОННАЯ сторона (категория)
-- в списке, не попадают в результат; та же сторона, что у p_category_uuids.
-- Прямой перевод кошелёк → кошелёк (обе стороны операционные) условию не
-- подпадает и остаётся. Параметр — последний, с DEFAULT NULL: вызовы
-- прежнего вида (позиционные 5/7 аргументов, именованные p_kind => …)
-- разрешаются в ту же функцию и возвращают то же, что до миграции.
DROP FUNCTION f_operations_total(uuid, timestamp, timestamp, uuid, uuid[], uuid[], text, text);
DROP FUNCTION f_operations_for_period(uuid, timestamp, timestamp, uuid, integer, timestamp, uuid, uuid[], uuid[], text, text);

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
    p_exclude_category_uuids uuid[]    DEFAULT NULL
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
       AND (p_exclude_category_uuids IS NULL
            OR NOT ((NOT o.acc_from_is_operating AND o.acc_fr_uuid = ANY (p_exclude_category_uuids))
                 OR (NOT o.acc_to_is_operating   AND o.acc_to_uuid = ANY (p_exclude_category_uuids))))
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

CREATE FUNCTION f_operations_total(
    p_ledger_id              uuid,
    p_from                   timestamp,
    p_to                     timestamp,
    p_eq_currency            uuid,
    p_category_uuids         uuid[] DEFAULT NULL,
    p_wallet_uuids           uuid[] DEFAULT NULL,
    p_kind                   text   DEFAULT NULL,
    p_q                      text   DEFAULT NULL,
    p_exclude_category_uuids uuid[] DEFAULT NULL
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
           AND (p_exclude_category_uuids IS NULL
                OR NOT ((NOT o.acc_from_is_operating AND o.acc_fr_uuid = ANY (p_exclude_category_uuids))
                     OR (NOT o.acc_to_is_operating   AND o.acc_to_uuid = ANY (p_exclude_category_uuids))))
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

GRANT EXECUTE ON FUNCTION f_operations_for_period(uuid, timestamp, timestamp, uuid, integer, timestamp, uuid, uuid[], uuid[], text, text, uuid[]) TO wallet_reader;
GRANT EXECUTE ON FUNCTION f_operations_total(uuid, timestamp, timestamp, uuid, uuid[], uuid[], text, text, uuid[]) TO wallet_reader;

COMMENT ON FUNCTION f_operations_for_period(uuid, timestamp, timestamp, uuid, integer, timestamp, uuid, uuid[], uuid[], text, text, uuid[]) IS
    'Лента операций периода с курсором (date, uuid) и фильтрами (категории, исключённые категории, кошельки, kind, подстрока комментария q) до курсора и LIMIT. Необязательные параметры передаются именованной нотацией, например p_kind => $6; NULL — фильтр не задан. Миграции 000027, 000030.';
COMMENT ON FUNCTION f_operations_total(uuid, timestamp, timestamp, uuid, uuid[], uuid[], text, text, uuid[]) IS
    'Итог ленты по тем же фильтрам за весь период: total_eq (с p_kind — сумма, без — сальдо income − expense, переводы 0), incomplete (есть операции без курса, в сумму не вошли), matched. Ровно одна строка. Миграции 000027, 000030.';
