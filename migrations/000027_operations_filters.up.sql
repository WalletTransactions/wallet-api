-- Серверные фильтры и итог ленты операций (change add-operations-filter-functions;
-- потребитель — wallet-report add-operations-filters: /api/reports/operations с
-- фильтрами, MCP-вопросы «сколько ушло на такси»). Фильтровать результат
-- f_operations_for_period снаружи нельзя: функция сама делает LIMIT, и фильтр после
-- лимита сломал бы курсорную пагинацию (страница из 3 строк при has_more: true).
-- Поэтому условия стоят здесь, ДО курсора, ORDER BY и LIMIT.
--
-- f_operations_for_period расширена четырьмя трейлинг-параметрами с DEFAULT NULL
-- (design D1): позиционные вызовы с 5 и 7 аргументами (текущий wallet-report)
-- разрешаются в эту же функцию, колонки результата не меняются. Новые параметры
-- вызывающий передаёт именованной нотацией и только заданные (D2):
--   f_operations_for_period($1, $2, $3, $4, $5, p_kind => $6, p_q => $7)
-- — непереданный параметр получает DEFAULT NULL в самой базе, клиенту слать SQL
-- NULL не нужно (db::Database::exec() его не умеет). Массивы — текстовым литералом
-- '{uuid,uuid}' с приведением $n::uuid[]. NULL = фильтр не задан; '{}' — «ни одного»,
-- то есть пустой результат.
--
-- Условия (D3), каждое — «p_x IS NULL OR …», вся выборка уже ограничена леджером:
-- - категории: неоперационная сторона проводки в списке;
-- - кошельки: операционная сторона в списке — прямой перевод кошелёк → кошелёк
--   подходит по любому из двух кошельков; uuid категории среди кошельков (и
--   наоборот) ни с чем не совпадёт;
-- - kind: то же выражение по флагам, что у колонки kind;
-- - q: подстрока комментария без учёта регистра, «ё» = «е» — та же нормализация,
--   что у uq_account_name (000024). strpos, а не LIKE: % и _ в тексте пользователя
--   ищутся буквально. NULL-комментарий не подходит.
--
-- f_operations_total (D4) — итог по тем же условиям за весь период (без курсора и
-- лимита), ровно одна строка. Условия повторены, а не вынесены во вложенную
-- функцию: инлайнинг вложенной SQL-функции не гарантирован, а лента без него может
-- потерять диапазонный скан ix_operation_date под LIMIT. Согласованность копий
-- страхует тест wallet-report (итог = сумма по всем страницам).
--
-- Обе функции — LANGUAGE sql без BEGIN ATOMIC: v_operation_eq разрешается при
-- вызове, пересоздание вьюхи (partition-operation-by-ledger) их не задевает.
DROP FUNCTION f_operations_for_period(uuid, timestamp, timestamp, uuid, integer, timestamp, uuid);

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
