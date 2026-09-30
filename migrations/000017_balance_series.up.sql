-- "Обзор"/"Динамика" (веб-отчёт, servers/wallet-report/src/
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
-- bucketStart/nextBucketStart (servers/wallet-web/site/app.js) — день:
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
-- LEFT JOIN buckets -> acct_bal (а не WHERE-фильтр прямо в основном
-- запросе, как у f_balance_to_date) — бакет БЕЗ единого кошелька с
-- движением (например, самые ранние бакеты леджера, до первой операции)
-- всё равно обязан попасть в результат ОДНОЙ строкой (все account-поля
-- NULL) — иначе вызывающий код не смог бы отличить "бакет есть, но пуст"
-- от "бакета вообще нет" без отдельного похода за списком границ.
--
-- Те же две ловушки, что и в f_balance_to_date/f_balance_to_dates (см. их
-- комментарии) — NULLS LAST в сортировке и отсутствие COALESCE на курсе.
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
    balance_eq    numeric
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
    acct_bal AS (
        SELECT b.idx,
               vao.uuid AS account_uuid,
               vao.name AS account_name,
               c.uuid   AS currency_uuid,
               c.symbol,
               c."precision",
               round(coalesce(opt.amount_to, 0) - coalesce(opf.amount_fr, 0), c."precision") AS balance,
               round(r.rate * (coalesce(opt.amount_to, 0) - coalesce(opf.amount_fr, 0)),
                     (SELECT eq."precision" FROM currency eq WHERE eq.uuid = p_eq_currency)) AS eq_value
          FROM buckets b
          CROSS JOIN v_account_operating vao
          JOIN currency c
            ON c.uuid = vao.currency_uuid
           AND c.deleted_at IS NULL
          LEFT JOIN LATERAL (
                SELECT sum(o.amount) AS amount_to
                  FROM operation o
                 WHERE o.ledger_id = p_ledger_id
                   AND o.deleted_at IS NULL
                   AND o.acc_to_uuid = vao.uuid
                   AND o."date" < (b.bucket_end + 1)::timestamp
               ) opt ON true
          LEFT JOIN LATERAL (
                SELECT sum(o.amount) AS amount_fr
                  FROM operation o
                 WHERE o.ledger_id = p_ledger_id
                   AND o.deleted_at IS NULL
                   AND o.acc_fr_uuid = vao.uuid
                   AND o."date" < (b.bucket_end + 1)::timestamp
               ) opf ON true
          LEFT JOIN LATERAL (
                SELECT rr.rate
                  FROM v_currency_conversion_rate rr
                 WHERE rr.from_currency_uuid = c.uuid
                   AND rr.to_currency_uuid   = p_eq_currency
                   AND rr."date"            <= b.bucket_end
                   AND (rr.ledger_id IS NULL OR rr.ledger_id = p_ledger_id)
                 ORDER BY rr."date" DESC, (rr.ledger_id IS NULL)
                 LIMIT 1
               ) r ON true
         WHERE vao.ledger_id = p_ledger_id
           AND (opt.amount_to IS NOT NULL OR opf.amount_fr IS NOT NULL)
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
           ab.eq_value
      FROM buckets b
      LEFT JOIN acct_bal ab ON ab.idx = b.idx
     ORDER BY b.idx, ab.eq_value DESC NULLS LAST;
$$;

GRANT EXECUTE ON FUNCTION f_balance_series(uuid, date, date, text, uuid) TO wallet_reader;
