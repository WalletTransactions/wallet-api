-- "Кошельки и остатки" (веб-отчёт, wallet-report/src/reports_repo.cpp
-- ::wallet_turnover_for_period) — оборот каждого кошелька леджера за период,
-- и в его собственной валюте, и в эквиваленте. Не порт клиента — нужна
-- только этому экрану.
--
-- В отличие от f_income_for_period/f_expanse_for_period — здесь считается
-- ЛЮБОЕ движение по кошельку, а не только обмен со СТАТЬЁЙ (категорией):
-- перевод кошелёк -> кошелёк тоже "пришло"/"ушло" для обеих его сторон.
-- Ровно поэтому "своя" сумма (turnover_in/turnover_out) построена прямо на
-- operation (два LEFT JOIN подзапроса, тот же приём, что и у
-- f_balance_to_date), а не на v_operation(_eq) с его фильтром
-- acc_from_is_operating/acc_to_is_operating.
--
-- turnover_in_eq/turnover_out_eq — то же самое движение, но в эквиваленте:
-- здесь v_operation_eq уже нужен (курс на дату каждой отдельной операции),
-- БЕЗ фильтра по operating-признаку — по той же причине, что и выше. Нужны
-- ради сортировки экрана: "своя" сумма разных кошельков в разных валютах
-- несравнима, эквивалент — сравнимая величина.
--
-- ВАЖНО ПРО ИТОГ turnover_in_eq/turnover_out_eq, та же оговорка, что у
-- f_income_for_period: sum(amount_eq) молча пропускает строки без курса и
-- занижает результат. incomplete — OR по обоим направлениям ЭТОГО кошелька;
-- агрегат "хотя бы одна строка ЛЮБОГО кошелька неполна" вызывающий код
-- считает поверх этой функции (bool_or(...) OVER (), тот же приём, что у
-- f_balance_to_date).
--
-- Возвращаются ВСЕ кошельки леджера (v_account_operating — живые, не
-- удалённые), а не только те, что двигались в периоде: экран "Мои кошельки"
-- обязан показать и кошелёк без единой операции за период (turnover_in/out
-- "0.00"), а не молча его спрятать — в отличие от f_balance_to_date, который
-- фильтрует по "было хоть какое-то движение когда-либо" (нужно ТАМ, чтобы не
-- тащить заведённый, но не использованный счёт в баланс; здесь наоборот —
-- список кошельков экрана и есть каталог "что у меня есть").
--
-- Границы периода ВКЛЮЧИТЕЛЬНЫ с обеих сторон — тот же принцип "обороты за
-- отрезок", что у f_income_for_period/f_expanse_for_period.
--
-- icon_sha256 — hex content_sha256 иконки кошелька (account.icon_uuid NOT
-- NULL — есть всегда), тот же приём, что и у категорий в
-- f_expanse_by_category_for_period. comment — свободный текст пользователя
-- ("Зарплатная карта", "Наличные" и т.п. — в схеме нет отдельного поля
-- "тип счёта", см. ../table/account.sql).
--
-- ОДИН скан v_operation_eq, не два (с 000021, по прямому запросу — "правь
-- все пункты по нагрузке"): раньше "пришло"/"ушло" в эквиваленте считались
-- ДВУМЯ отдельными LEFT JOIN на v_operation_eq (по acc_to_uuid и по
-- acc_fr_uuid) — то есть курс каждой операции периода резолвился ДВАЖДЫ
-- (v_operation_eq — LATERAL-резолв курса НА КАЖДУЮ операцию, см. её
-- комментарий), хотя число (amount_eq) от того, в "пришло" или "ушло" какого
-- счёта его отнести, не зависит. Здесь v_operation_eq сканируется в CTE oe
-- ОДИН раз (MATERIALIZED — тот же приём и та же причина, что у running в
-- f_balance_series/f_balance_to_dates, 000019: без него планировщик мог бы
-- пересчитать её заново при джойне ниже), а разнесение по счетам —
-- дешёвый UNION ALL уже посчитанного amount_eq плюс один GROUP BY с FILTER.
-- "Своя" сумма (opt/opf, без курса) не тронута — резолва там и так нет.
--
-- Источник истины — реальные миграции
-- wallet-api/migrations/000008_wallet_turnover.up.sql,
-- 000010_wallet_turnover_eq.up.sql и 000021_wallet_turnover_single_scan.up.sql
-- (см. ../../README.md про этот принцип); этот файл — читаемое зеркало
-- ТЕКУЩЕГО состояния (после всех трёх).
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
    WITH oe AS MATERIALIZED (
        SELECT oe.acc_to_uuid, oe.acc_fr_uuid, oe.amount_eq
          FROM v_operation_eq oe
         WHERE oe.ledger_id        = p_ledger_id
           AND oe.to_currency_uuid = p_eq_currency
           AND oe."date" BETWEEN p_from AND p_to
    ),
    oe_by_account AS (
        SELECT acc_to_uuid AS acc_uuid, amount_eq, true AS is_in FROM oe
        UNION ALL
        SELECT acc_fr_uuid AS acc_uuid, amount_eq, false AS is_in FROM oe
    ),
    oe_agg AS (
        SELECT acc_uuid,
               sum(amount_eq) FILTER (WHERE is_in)                 AS amount_in_eq,
               sum(amount_eq) FILTER (WHERE NOT is_in)              AS amount_out_eq,
               bool_or(amount_eq IS NULL) FILTER (WHERE is_in)      AS incomplete_in,
               bool_or(amount_eq IS NULL) FILTER (WHERE NOT is_in)  AS incomplete_out
          FROM oe_by_account
         GROUP BY acc_uuid
    )
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
           round(coalesce(oe_agg.amount_in_eq, 0),
                 (SELECT eq."precision" FROM currency eq WHERE eq.uuid = p_eq_currency)),
           round(coalesce(oe_agg.amount_out_eq, 0),
                 (SELECT eq."precision" FROM currency eq WHERE eq.uuid = p_eq_currency)),
           coalesce(oe_agg.incomplete_in, false) OR coalesce(oe_agg.incomplete_out, false)
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
      LEFT JOIN oe_agg ON oe_agg.acc_uuid = vao.uuid
     WHERE vao.ledger_id = p_ledger_id
     ORDER BY vao.name;
$$;
