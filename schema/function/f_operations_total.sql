-- Итог ленты операций (wallet-report /api/reports/operations с фильтрами,
-- change add-operations-filter-functions) — по ТЕМ ЖЕ условиям, что
-- f_operations_for_period (категории, исключённые категории — 000030, кошельки, kind, q; см. её шапку), но за
-- весь период: курсор и лимит итог не учитывает. Смысл и результаты — спека
-- wallet-report operations-list.
--
-- Ровно одна строка (агрегат без GROUP BY): для пустого результата
-- total_eq = 0, incomplete = false, matched = 0.
--
-- Правило знака total_eq:
-- - p_kind задан — сумма amount_eq подходящих операций, неотрицательная
--   («сколько ушло на такси»: p_kind => 'expense');
-- - p_kind не задан — сальдо Σ income − Σ expense; прямые переводы кошелёк →
--   кошелёк дают 0 (деньги не выходят из кошельков пользователя).
--   Разновалютный перевод через категорию Transfer — пара expense + income,
--   его ноги взаимно погашаются, как в /expense-structure.
-- incomplete = bool_or(amount_eq IS NULL): у части подходящих операций нет
-- курса к p_eq_currency, в сумму они не вошли. matched — число подходящих
-- операций (совпадает с числом строк по всем страницам ленты — отсюда тот же
-- JOIN currency, что у неё).
--
-- Условия повторены, а не вынесены во вложенную функцию: инлайнинг вложенной
-- SQL-функции не гарантирован, а лента без него может потерять диапазонный
-- скан ix_operation_date под LIMIT. Две копии страхует тест согласованности
-- wallet-report (итог = сумма по всем страницам).
--
-- Источник истины — миграции wallet-api/migrations/000027_operations_filters.up.sql
-- и 000030_category_month_analytics.up.sql; этот файл — их читаемое зеркало.
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

COMMENT ON FUNCTION f_operations_total(uuid, timestamp, timestamp, uuid, uuid[], uuid[], text, text, uuid[]) IS
    'Итог ленты по тем же фильтрам за весь период: total_eq (с p_kind — сумма, без — сальдо income − expense, переводы 0), incomplete (есть операции без курса, в сумму не вошли), matched. Ровно одна строка. Миграции 000027, 000030.';
