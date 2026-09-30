-- "Кошельки и остатки" (по прямому запросу — "сортировка по На конец/Начало/
-- Пришло/Ушло должна быть в эквиваленте, а не валюте кошелька") — добавляет
-- p_eq_currency и turnover_in_eq/turnover_out_eq/incomplete к
-- f_wallet_turnover_for_period (000008_wallet_turnover): сортировать
-- "Пришло"/"Ушло" по "своей" сумме бессмысленно, когда у кошельков разные
-- валюты — сравнимая величина только эквивалент. "Своя" сумма
-- (turnover_in/turnover_out) остаётся как есть, ей по-прежнему подписана
-- каждая строка таблицы.
--
-- Сигнатура функции меняется (добавился параметр) — DROP + CREATE, не
-- CREATE OR REPLACE (Postgres и так не даёт поменять список RETURNS TABLE
-- через REPLACE).
DROP FUNCTION IF EXISTS f_wallet_turnover_for_period(uuid, timestamp, timestamp);

-- turnover_in_eq/turnover_out_eq считаются НЕ по operation напрямую (там нет
-- курса), а по v_operation_eq — тому же представлению, что и
-- f_income_for_period/f_expanse_for_period, только БЕЗ фильтра
-- acc_from_is_operating/acc_to_is_operating (см. комментарий turnover_in/out
-- ниже, почему — тот же принцип, что и у своей суммы).
--
-- ВАЖНО ПРО ИТОГ, та же оговорка, что у f_income_for_period: sum(amount_eq)
-- молча пропускает строки без курса и занижает результат. incomplete здесь —
-- OR по обоим направлениям (пришло/ушло) этого кошелька; агрегат "хотя бы
-- одна строка ЛЮБОГО кошелька неполна" вызывающий код считает поверх этой
-- функции (см. servers/wallet-report/src/reports_repo.cpp), тем же приёмом
-- bool_or(...) OVER (), что и у f_balance_to_date.
CREATE FUNCTION f_wallet_turnover_for_period(
    p_ledger_id   uuid,
    p_from        timestamp,
    p_to          timestamp,
    p_eq_currency uuid
) RETURNS TABLE (
    account_uuid    uuid,
    account_name    text,
    comment         text,
    is_archived     boolean,
    currency_uuid   uuid,
    symbol          text,
    "precision"     smallint,
    icon_sha256     text,
    turnover_in     numeric,
    turnover_out    numeric,
    turnover_in_eq  numeric,
    turnover_out_eq numeric,
    incomplete      boolean
)
    LANGUAGE sql
    STABLE
    PARALLEL SAFE
AS $$
    SELECT vao.uuid,
           vao.name,
           vao.comment,
           vao.is_archived,
           c.uuid,
           c.symbol,
           c."precision",
           encode(ic.content_sha256, 'hex'),
           round(coalesce(opt.amount_to, 0), c."precision"),
           round(coalesce(opf.amount_fr, 0), c."precision"),
           round(coalesce(oe_in.amount_eq, 0),
                 (SELECT eq."precision" FROM currency eq WHERE eq.uuid = p_eq_currency)),
           round(coalesce(oe_out.amount_eq, 0),
                 (SELECT eq."precision" FROM currency eq WHERE eq.uuid = p_eq_currency)),
           coalesce(oe_in.incomplete, false) OR coalesce(oe_out.incomplete, false)
      FROM v_account_operating vao
      JOIN currency c
        ON c.uuid = vao.currency_uuid
       AND c.deleted_at IS NULL
      JOIN icon ic ON ic.uuid = vao.icon_uuid
      LEFT JOIN (
            SELECT o.acc_to_uuid, sum(o.amount) AS amount_to
              FROM operation o
             WHERE o.ledger_id = p_ledger_id
               AND o.deleted_at IS NULL
               AND o."date" BETWEEN p_from AND p_to
             GROUP BY o.acc_to_uuid
           ) opt ON opt.acc_to_uuid = vao.uuid
      LEFT JOIN (
            SELECT o.acc_fr_uuid, sum(o.amount) AS amount_fr
              FROM operation o
             WHERE o.ledger_id = p_ledger_id
               AND o.deleted_at IS NULL
               AND o."date" BETWEEN p_from AND p_to
             GROUP BY o.acc_fr_uuid
           ) opf ON opf.acc_fr_uuid = vao.uuid
      LEFT JOIN (
            SELECT oe.acc_to_uuid,
                   sum(oe.amount_eq)       AS amount_eq,
                   bool_or(oe.amount_eq IS NULL) AS incomplete
              FROM v_operation_eq oe
             WHERE oe.ledger_id        = p_ledger_id
               AND oe.to_currency_uuid = p_eq_currency
               AND oe."date" BETWEEN p_from AND p_to
             GROUP BY oe.acc_to_uuid
           ) oe_in ON oe_in.acc_to_uuid = vao.uuid
      LEFT JOIN (
            SELECT oe.acc_fr_uuid,
                   sum(oe.amount_eq)       AS amount_eq,
                   bool_or(oe.amount_eq IS NULL) AS incomplete
              FROM v_operation_eq oe
             WHERE oe.ledger_id        = p_ledger_id
               AND oe.to_currency_uuid = p_eq_currency
               AND oe."date" BETWEEN p_from AND p_to
             GROUP BY oe.acc_fr_uuid
           ) oe_out ON oe_out.acc_fr_uuid = vao.uuid
     WHERE vao.ledger_id = p_ledger_id
     ORDER BY vao.name;
$$;

GRANT EXECUTE ON FUNCTION f_wallet_turnover_for_period(uuid, timestamp, timestamp, uuid) TO wallet_reader;
