-- "Кошельки и остатки"/"Обзор" (веб-отчёт, wallet-report/src/
-- reports_repo.cpp::balances_at_dates) — баланс каждого кошелька леджера
-- сразу на НЕСКОЛЬКО дат, одним запросом к СУБД вместо N вызовов
-- f_balance_to_date подряд (по прямому запросу — "Кошельки и остатки"
-- делали до 14 отдельных GET /api/reports/balance на один показ экрана;
-- "Обзор" — ещё 12 на линию остатка "Расхода по месяцам").
--
-- Та же формула, что и f_balance_to_date (обороты "на счёт" минус "со
-- счёта" СТРОГО ДО даты, курс — последний не позже даты) — но, В ОТЛИЧИЕ
-- от неё, НЕ пересчётом SUM(...) WHERE date < X заново на каждую дату (по
-- прямому запросу, 2026-09-12 — "выяви самые проблемные запросы... баланс
-- за раз, инкрементально": так было раньше, и это O(дат × счетов ×
-- операций до даты) — чем длиннее история счёта, тем дороже КАЖДАЯ
-- следующая дата). Здесь — один проход: каждая операция счёта становится
-- знаковым событием (+amount получателю, -amount отправителю), к ним
-- подмешивается по одной "контрольной точке" с нулевым вкладом НА КАЖДУЮ
-- запрошенную дату (unnest(p_dates) WITH ORDINALITY, idx — та же 1-based
-- позиция, что и раньше), и кумулятивная сумма — ОДНА window-функция на
-- партицию-счёт (events/running ниже) — тут же даёт баланс НА ЛЮБОЙ
-- момент, включая каждую контрольную точку, без пересчёта "с нуля" для
-- каждой из них.
--
-- ДВЕ ТОНКОСТИ (сама формула):
--   1. Порядок при равенстве времени — контрольная точка (is_checkpoint)
--      идёт ПЕРЕД операцией того же момента (ORDER BY event_at,
--      is_checkpoint DESC) — иначе операция, совпавшая по времени секунда
--      в секунду с запрошенной датой, попала бы "внутрь" кумулятива этой
--      точки, хотя формула "date < X" — строгая (см. тест
--      balances_at_dates_excludes_operation_exactly_on_the_requested_date).
--   2. "Было ли движение" — это НЕ "баланс отличен от нуля" (у счёта,
--      где приход и расход случайно сравнялись, баланс 0, но счёт всё
--      равно обязан попасть в отчёт — та же строка, что и с ненулевым
--      балансом). Поэтому кроме кумулятивной суммы (cum) окно считает
--      "сколько РЕАЛЬНЫХ операций предшествует этой точке" (ops_before) —
--      именно по нему, не по cum, отсекаются счета без движения к дате.
--
-- ДОБАВЛЕНО В 000019 (проверка на реальных данных через EXPLAIN ANALYZE
-- сразу после 000018 нашла два регресса, которых сама по себе "кумулятивная
-- сумма одним окном" не решает):
--   1. running — MATERIALIZED. Без него Postgres встраивал CTE как обычный
--      подзапрос и на JOIN running r ON vao.uuid = r.account_uuid выбирал
--      Nested Loop — пересчитывал ВСЮ running (окно по ВСЕМ счетам) заново
--      на КАЖДЫЙ счёт (на 51 счёте — в 51 раз больше работы, чем нужно).
--   2. date_rates — курс считается на пару (дата, ВАЛЮТА), не (дата, счёт):
--      ставка зависит только от валюты, а разных валют среди счетов обычно
--      в разы меньше, чем самих счетов (12 валют на 51 счёт в одном
--      реальном леджере) — раньше курс резолвился на каждую (дата, счёт)
--      пару отдельно.
-- Итог на реальных данных (2.7 года, дневной шаг — тот же приём резолва
-- курса общий с f_balance_series, см. её же комментарий): 9.5-14с -> ~0.7с.
--
-- date_index — 1-based позиция даты во входном массиве (WITH ORDINALITY
-- нумерует с 1) — вызывающий код группирует строки ответа по НЕЙ, а не по
-- тексту даты: Postgres нормализует "2026-01-30" в "2026-01-30 00:00:00"
-- при выводе timestamp, сравнивать строки запроса и ответа посимвольно было
-- бы хрупко.
--
-- Даты БЕЗ единого кошелька в результат ВООБЩЕ не попадают (тот же фильтр
-- "было хоть какое-то движение", что и у f_balance_to_date) — восстановление
-- ПОЛНОГО списка дат (ровно один блок на каждую p_dates[i], включая пустые)
-- лежит на вызывающем коде.
--
-- Отсутствие COALESCE на курсе — та же ловушка, что и в f_balance_to_date
-- (см. её комментарий): NULL здесь означает "пересчитать нельзя".
--
-- Источник истины — реальные миграции
-- wallet-api/migrations/000018_balance_series_incremental.up.sql
-- и 000019_balance_series_materialize.up.sql (см. ../../README.md про этот
-- принцип); этот файл — читаемое зеркало ТЕКУЩЕГО состояния (после
-- 000011_balance_to_dates.up.sql и обеих миграций выше).
CREATE FUNCTION f_balance_to_dates(
    p_ledger_id   uuid,
    p_dates       timestamp[],
    p_eq_currency uuid
) RETURNS TABLE (
    date_index    integer,
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
    WITH dates AS (
        SELECT d.idx::integer AS idx, d.balance_date
          FROM unnest(p_dates) WITH ORDINALITY AS d(balance_date, idx)
    ),
    events AS (
        SELECT vao.uuid AS account_uuid, o."date" AS event_at, o.amount AS delta,
               false AS is_checkpoint, NULL::integer AS idx
          FROM v_account_operating vao
          JOIN operation o
            ON o.ledger_id = p_ledger_id
           AND o.deleted_at IS NULL
           AND o.acc_to_uuid = vao.uuid
         WHERE vao.ledger_id = p_ledger_id
        UNION ALL
        SELECT vao.uuid, o."date", -o.amount, false, NULL::integer
          FROM v_account_operating vao
          JOIN operation o
            ON o.ledger_id = p_ledger_id
           AND o.deleted_at IS NULL
           AND o.acc_fr_uuid = vao.uuid
         WHERE vao.ledger_id = p_ledger_id
        UNION ALL
        SELECT vao.uuid, d.balance_date, 0, true, d.idx
          FROM v_account_operating vao
          CROSS JOIN dates d
         WHERE vao.ledger_id = p_ledger_id
    ),
    -- MATERIALIZED — см. шапку файла, "ДОБАВЛЕНО В 000019" пункт 1.
    running AS MATERIALIZED (
        SELECT account_uuid, is_checkpoint, idx,
               sum(delta) OVER w AS cum,
               count(*) FILTER (WHERE NOT is_checkpoint) OVER w AS ops_before
          FROM events
          WINDOW w AS (
              PARTITION BY account_uuid
              ORDER BY event_at, is_checkpoint DESC
              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
          )
    ),
    -- Курс — на пару (дата, валюта), не (дата, счёт): см. шапку файла,
    -- "ДОБАВЛЕНО В 000019" пункт 2.
    date_rates AS MATERIALIZED (
        SELECT d.idx, c.uuid AS currency_uuid,
               (SELECT rr.rate
                  FROM v_currency_conversion_rate rr
                 WHERE rr.from_currency_uuid = c.uuid
                   AND rr.to_currency_uuid   = p_eq_currency
                   AND rr."date"            <= d.balance_date::date
                   AND (rr.ledger_id IS NULL OR rr.ledger_id = p_ledger_id)
                 ORDER BY rr."date" DESC, (rr.ledger_id IS NULL)
                 LIMIT 1) AS rate
          FROM dates d
          CROSS JOIN (
                SELECT DISTINCT currency_uuid FROM v_account_operating WHERE ledger_id = p_ledger_id
               ) vc
          JOIN currency c ON c.uuid = vc.currency_uuid AND c.deleted_at IS NULL
    ),
    acct_bal AS (
        SELECT r.idx,
               vao.uuid AS account_uuid,
               vao.name AS account_name,
               c.uuid   AS currency_uuid,
               c.symbol,
               c."precision",
               round(r.cum, c."precision") AS balance,
               round(dr.rate * r.cum,
                     (SELECT eq."precision" FROM currency eq WHERE eq.uuid = p_eq_currency)) AS eq_value,
               vao.asset_type,
               vao.include_in_net_worth
          FROM running r
          JOIN v_account_operating vao ON vao.uuid = r.account_uuid
          JOIN currency c
            ON c.uuid = vao.currency_uuid
           AND c.deleted_at IS NULL
          LEFT JOIN date_rates dr ON dr.idx = r.idx AND dr.currency_uuid = c.uuid
         WHERE r.is_checkpoint
           AND r.ops_before > 0
    )
    SELECT ab.idx,
           ab.account_uuid,
           ab.account_name,
           ab.currency_uuid,
           ab.symbol,
           ab."precision",
           ab.balance,
           ab.eq_value,
           ab.asset_type,
           ab.include_in_net_worth
      FROM acct_bal ab
     ORDER BY ab.idx, ab.eq_value DESC NULLS LAST;
$$;
