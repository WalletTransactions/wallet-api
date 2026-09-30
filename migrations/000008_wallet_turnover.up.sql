-- "Кошельки и остатки" (веб-отчёт, servers/wallet-report — по прямому
-- запросу "реализуй Кошельки и остатки из дизайна", Design/.../Отчёты - веб
-- (офлайн).html, вид 'wal') — оборот каждого кошелька леджера за период:
-- сколько пришло и сколько ушло, в СВОЕЙ валюте счёта.
--
-- В отличие от f_income_for_period/f_expanse_for_period — здесь считается
-- ЛЮБОЕ движение по кошельку, а не только обмен со СТАТЬЁЙ (категорией):
-- перевод кошелёк -> кошелёк тоже "пришло"/"ушло" для обеих его сторон.
-- Ровно поэтому нет фильтра acc_from_is_operating/acc_to_is_operating — вся
-- функция построена прямо на operation, а не на v_operation(_eq), тем же
-- приёмом двух LEFT JOIN подзапросов, что и f_balance_to_date.
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
-- Валюты не смешиваются, эквивалент не считается вовсе — отсюда и нет
-- p_eq_currency в параметрах. Остатки на начало/конец периода, УЖЕ в
-- эквиваленте, экран берёт из существующего GET /api/reports/balance
-- (вызывается дважды, на начало и на конец периода, тем же приёмом, что и
-- "Обзор" — см. servers/wallet-web/site/app.js::refreshWalletBalances); эта
-- функция добавляет только "пришло"/"ушло" в своей валюте, которых там нет.
--
-- icon_sha256 — hex content_sha256 иконки кошелька (account.icon_uuid NOT
-- NULL — есть всегда), тот же приём, что и у категорий в
-- f_expanse_by_category_for_period. comment — свободный текст пользователя
-- ("Зарплатная карта", "Наличные" и т.п. — в схеме нет отдельного поля
-- "тип счёта", см. schema/server/table/account.sql).
CREATE FUNCTION f_wallet_turnover_for_period(
    p_ledger_id uuid,
    p_from      timestamp,
    p_to        timestamp
) RETURNS TABLE (
    account_uuid  uuid,
    account_name  text,
    comment       text,
    is_archived   boolean,
    currency_uuid uuid,
    symbol        text,
    "precision"   smallint,
    icon_sha256   text,
    turnover_in   numeric,
    turnover_out  numeric
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
           round(coalesce(opf.amount_fr, 0), c."precision")
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
     WHERE vao.ledger_id = p_ledger_id
     ORDER BY vao.name;
$$;

GRANT EXECUTE ON FUNCTION f_wallet_turnover_for_period(uuid, timestamp, timestamp) TO wallet_reader;
