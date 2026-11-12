-- "Обзор"/"Динамика" (веб-отчёт, wallet-report/src/
-- reports_repo.cpp::balance_series) — по прямому запросу (2026-09-11,
-- "новое API, которое просит с/по и шагом, а не вызов с миллионом
-- параметров в GET"): раньше линия остатка на этих экранах строилась через
-- f_balance_to_dates(p_dates timestamp[]) — клиент сам считал ГРАНИЦЫ
-- бакетов (день/неделя/месяц) и слал их СПИСКОМ в query-параметре, что при
-- широком периоде с группировкой по дням/неделям разрастается до сотен дат
-- и упирается в лимит длины URI на wallet-gateway (см. историю чата,
-- CPPHTTPLIB_REQUEST_URI_MAX_LENGTH = 8192 байт, "Failed to fetch").
--
-- Здесь сервер сам генерирует границы бакетов из p_from/p_to/p_step —
-- запрос всегда фиксированного размера, независимо от длины периода.
--
-- Бакеты выровнены по календарю той же логикой, что и клиентские
-- bucketStart/nextBucketStart (wallet-web/site/app.js) — день:
-- сам p_from; неделя: понедельник ISO-недели, содержащей p_from; месяц:
-- 1-е число месяца p_from; год: 1 января года p_from. Каждый следующий
-- бакет — предыдущий + шаг (interval), последний обрезан по p_to (может
-- быть неполным, как и первый, если p_from не совпал с границей).
--
-- Формула баланса — ТА ЖЕ, что и у f_balance_to_date/f_balance_to_dates
-- (обороты "на счёт" минус "со счёта" СТРОГО ДО даты, курс — последний не
-- позже даты): для бакета это "день ПОСЛЕ его конца" — тот же приём "день
-- после конца периода", что уже применяют и клиент, и wallet_turnover.
--
-- В ОТЛИЧИЕ от первой версии (000017) — НЕ пересчитывает SUM(...) WHERE
-- date < bucket_end+1 заново на каждый бакет (по прямому запросу,
-- 2026-09-12 — "выяви самые проблемные запросы... баланс за раз,
-- инкрементально": так было раньше, и это O(бакетов × счетов × операций до
-- бакета) — при периоде в годы и шаге день/неделя это сотни бакетов, и чем
-- длиннее история счёта, тем дороже КАЖДЫЙ следующий). Здесь — тот же
-- приём "события + контрольные точки + кумулятивная сумма ОДНИМ окном",
-- что и в f_balance_to_dates (см. её комментарий про две тонкости — порядок
-- при равенстве времени и "было ли движение" отдельно от "баланс <> 0", они
-- те же самые здесь): контрольная точка на каждый бакет — это его
-- "день после конца" (bucket_end + 1), а не произвольная дата из массива.
--
-- ДОБАВЛЕНО В 000019 (проверка на реальных данных через EXPLAIN ANALYZE
-- сразу после 000018 нашла два регресса, которых сама по себе "кумулятивная
-- сумма одним окном" не решает — см. подробности в f_balance_to_dates.sql,
-- тот же приём здесь):
--   1. running — MATERIALIZED, иначе Postgres пересчитывал бы её заново на
--      каждый счёт при джойне ниже (на 51 счёте — в 51 раз больше работы).
--   2. bucket_rates — курс на пару (бакет, ВАЛЮТА), не (бакет, счёт): в
--      одном реальном леджере — 12 валют на 51 счёт, курс резолвился на
--      каждую (бакет, счёт) пару отдельно, хотя ставка от счёта не зависит.
-- Итог на реальных данных (2.7 года, дневной шаг — 986 бакетов, 51 счёт):
-- 9.5-14с -> ~0.7с.
--
-- LEFT JOIN buckets -> acct_bal (а не WHERE-фильтр прямо в основном
-- запросе, как у f_balance_to_date) — бакет БЕЗ единого кошелька с
-- движением (например, самые ранние бакеты леджера, до первой операции)
-- всё равно обязан попасть в результат ОДНОЙ строкой (все account-поля
-- NULL) — иначе вызывающий код не смог бы отличить "бакет есть, но пуст"
-- от "бакета вообще нет" без отдельного похода за списком границ.
--
-- Отсутствие COALESCE на курсе — та же ловушка, что и в f_balance_to_date/
-- f_balance_to_dates (см. их комментарии).
--
-- Источник истины — реальные миграции
-- wallet-api/migrations/000018_balance_series_incremental.up.sql
-- и 000019_balance_series_materialize.up.sql (см. ../../README.md про этот
-- принцип); этот файл — читаемое зеркало ТЕКУЩЕГО состояния (после
-- 000017_balance_series.up.sql и обеих миграций выше).
CREATE FUNCTION f_balance_series(
    p_ledger_id   uuid,
    p_from        date,
    p_to          date,
    p_step        text,
    p_eq_currency uuid
) RETURNS TABLE (
    date_index    integer,
    bucket_start  date,
    bucket_end    date,
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
    include_in_net_worth boolean,
    -- debts (000036): контрагент долгового кошелька; NULL — не долговой
    -- (и пустой бакет f_balance_series).
    counterparty_uuid    uuid
)
    LANGUAGE sql
    STABLE
    PARALLEL SAFE
AS $$
    WITH step AS (
        SELECT CASE p_step
                   WHEN 'day'   THEN interval '1 day'
                   WHEN 'week'  THEN interval '7 days'
                   WHEN 'month' THEN interval '1 month'
                   WHEN 'year'  THEN interval '1 year'
               END AS unit,
               CASE p_step
                   WHEN 'day'   THEN p_from
                   WHEN 'week'  THEN p_from - (extract(isodow FROM p_from)::int - 1)
                   WHEN 'month' THEN date_trunc('month', p_from)::date
                   WHEN 'year'  THEN date_trunc('year', p_from)::date
               END AS first_start
    ),
    buckets AS (
        SELECT gs.bucket_start::date AS bucket_start,
               LEAST((gs.bucket_start + step.unit - interval '1 day')::date, p_to) AS bucket_end,
               row_number() OVER (ORDER BY gs.bucket_start)::integer AS idx
          FROM step
          CROSS JOIN LATERAL generate_series(step.first_start, p_to, step.unit) AS gs(bucket_start)
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
        SELECT vao.uuid, (b.bucket_end + 1)::timestamp, 0, true, b.idx
          FROM v_account_operating vao
          CROSS JOIN buckets b
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
    -- Курс — на пару (бакет, валюта), не (бакет, счёт): см. шапку файла,
    -- "ДОБАВЛЕНО В 000019" пункт 2.
    bucket_rates AS MATERIALIZED (
        SELECT bk.idx, c.uuid AS currency_uuid,
               (SELECT rr.rate
                  FROM v_currency_conversion_rate rr
                 WHERE rr.from_currency_uuid = c.uuid
                   AND rr.to_currency_uuid   = p_eq_currency
                   AND rr."date"            <= bk.bucket_end
                   AND (rr.ledger_id IS NULL OR rr.ledger_id = p_ledger_id)
                 ORDER BY rr."date" DESC, (rr.ledger_id IS NULL)
                 LIMIT 1) AS rate
          FROM buckets bk
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
               round(br.rate * r.cum,
                     (SELECT eq."precision" FROM currency eq WHERE eq.uuid = p_eq_currency)) AS eq_value,
               vao.asset_type,
               vao.include_in_net_worth,
               vao.counterparty_uuid
          FROM running r
          JOIN v_account_operating vao ON vao.uuid = r.account_uuid
          JOIN currency c
            ON c.uuid = vao.currency_uuid
           AND c.deleted_at IS NULL
          JOIN buckets bk ON bk.idx = r.idx
          LEFT JOIN bucket_rates br ON br.idx = bk.idx AND br.currency_uuid = c.uuid
         WHERE r.is_checkpoint
           AND r.ops_before > 0
    )
    SELECT b.idx,
           b.bucket_start,
           b.bucket_end,
           ab.account_uuid,
           ab.account_name,
           ab.currency_uuid,
           ab.symbol,
           ab."precision",
           ab.balance,
           ab.eq_value,
           ab.asset_type,
           ab.include_in_net_worth,
           ab.counterparty_uuid
      FROM buckets b
      LEFT JOIN acct_bal ab ON ab.idx = b.idx
     ORDER BY b.idx, ab.eq_value DESC NULLS LAST;
$$;
