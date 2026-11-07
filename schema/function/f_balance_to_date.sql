-- Баланс каждого кошелька леджера на дату — в своей валюте и в эквиваленте.
-- Порт android-wallet/schema/select/GetBalanceToDate.sql, где это именованный запрос с
-- подстановкой параметров; здесь параметры настоящие.
--
-- Баланс = обороты «на счёт» минус обороты «со счёта» строго ДО даты
-- (p_date не включается). Экран балансов вызывает функцию дважды — на начало и
-- на конец периода, — поэтому p_date это одна дата, а не граница диапазона.
--
-- Возвращаются только кошельки, по которым было хоть какое-то движение:
-- заведённый, но не использованный счёт в отчёте о балансах не нужен.
-- Архивные кошельки, наоборот, остаются — исключение архивного счёта молча
-- меняло бы итоги за прошлые периоды (см. account.is_archived в ../table/README.md).
--
-- ДВА МЕСТА, ГДЕ ОШИБИТЬСЯ ЛЕГЧЕ ВСЕГО:
--
-- 1. NULLS LAST в сортировке. В SQLite NULL меньше любого значения, поэтому
--    ORDER BY balance_eq DESC сам укладывает кошельки без курса в конец списка.
--    В PostgreSQL NULL при DESC идёт ПЕРВЫМ, и без явного NULLS LAST отчёт
--    начинался бы со строк, у которых эквивалента нет вовсе.
--
-- 2. Отсутствие COALESCE на курсе. Если подставить сюда 1, balance_eq перестанет
--    быть NULL, и кошелёк без курса молча войдёт в итоги по курсу 1:1, завысив
--    их. NULL здесь означает «пересчитать нельзя», и вызывающий обязан пометить
--    такую сумму неполной — см. три состояния эквивалента в android-wallet/docs/ARCHITECTURE.md.
--
-- Отличие от клиента: промежуточные суммы НЕ округляются до двух знаков.
-- Клиент делает round(sum(amount), 2) внутри подзапросов, а внешним round'ом
-- приводит уже к currency.precision — для валюты с точностью больше двух это
-- теряет знаки дважды. Здесь округление одно, в самом конце. Эквивалент
-- округляется по precision валюты эквивалента, а не по зашитой двойке.
--
-- SECURITY INVOKER (по умолчанию): права проверяются по роли вызывающего, то
-- есть wallet_reports с одним лишь SELECT сможет вызвать функцию, но не обойти
-- через неё свои ограничения.
CREATE FUNCTION f_balance_to_date(
    p_ledger_id   uuid,
    p_date        timestamp,
    p_eq_currency uuid
) RETURNS TABLE (
    account_uuid  uuid,
    account_name  text,
    currency_uuid uuid,
    symbol        text,
    "precision"   smallint,
    balance       numeric,
    balance_eq    numeric,
    -- capital-assets (000033): признак актива из v_account_operating; NULL —
    -- ликвидный кошелёк (и пустой бакет f_balance_series).
    asset_type           smallint,
    include_in_net_worth boolean
)
    LANGUAGE sql
    STABLE
    PARALLEL SAFE
AS $$
    SELECT vao.uuid,
           vao.name,
           c.uuid,
           c.symbol,
           c."precision",
           round(coalesce(opt.amount_to, 0) - coalesce(opf.amount_fr, 0), c."precision"),
           round(r.rate * (coalesce(opt.amount_to, 0) - coalesce(opf.amount_fr, 0)),
                 (SELECT eq."precision" FROM currency eq WHERE eq.uuid = p_eq_currency))
               AS eq_value,
           vao.asset_type,
           vao.include_in_net_worth
      FROM v_account_operating vao
      JOIN currency c
        ON c.uuid = vao.currency_uuid
       AND c.deleted_at IS NULL
      LEFT JOIN (
            SELECT o.acc_to_uuid, sum(o.amount) AS amount_to
              FROM operation o
             WHERE o.ledger_id = p_ledger_id
               AND o.deleted_at IS NULL
               AND o."date" < p_date
             GROUP BY o.acc_to_uuid
           ) opt ON opt.acc_to_uuid = vao.uuid
      LEFT JOIN (
            SELECT o.acc_fr_uuid, sum(o.amount) AS amount_fr
              FROM operation o
             WHERE o.ledger_id = p_ledger_id
               AND o.deleted_at IS NULL
               AND o."date" < p_date
             GROUP BY o.acc_fr_uuid
           ) opf ON opf.acc_fr_uuid = vao.uuid
      LEFT JOIN LATERAL (
            SELECT rr.rate
              FROM v_currency_conversion_rate rr
             WHERE rr.from_currency_uuid = c.uuid
               AND rr.to_currency_uuid   = p_eq_currency
               AND rr."date"            <= p_date::date
               AND (rr.ledger_id IS NULL OR rr.ledger_id = p_ledger_id)
             ORDER BY rr."date" DESC, (rr.ledger_id IS NULL)
             LIMIT 1
           ) r ON true
     WHERE vao.ledger_id = p_ledger_id
       AND (opt.acc_to_uuid IS NOT NULL OR opf.acc_fr_uuid IS NOT NULL)
     ORDER BY eq_value DESC NULLS LAST;
$$;
