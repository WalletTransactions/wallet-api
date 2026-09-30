-- "Список операций" (веб-отчёт, GET /api/reports/operations) — по прямому
-- запросу ("давай улучшим операции, пагинацию по 1000... если выбираем
-- 20 лет, то нет необходимости доставать всё"): f_operations_for_period
-- раньше отдавала ВЕСЬ период одним запросом (см. её README/комментарий у
-- прежней версии, "ВСЕ операции периода плоским списком, без пагинации") —
-- для активного пользователя за много лет это тысячи строк с джойнами на
-- каждый показ "Обзора"/"Динамики"/"Категорий" (они тоже читают этот же
-- эндпоинт, целиком, для клиентской агрегации) и особенно самого "Списка
-- операций" (там человек чаще всего смотрит первую страницу и не долистывает
-- до конца).
--
-- Курсорная, не OFFSET-пагинация — тот же принцип, что и у sync-протокола
-- (`seq`-курсор, см. servers/README.md/wallet-api): OFFSET N на глубокой
-- странице (скажем, 50-й по 1000 = OFFSET 50000) заставил бы Postgres
-- каждый раз заново пересчитывать и отбрасывать 50000 строк — тот же
-- квадратичный по числу страниц эффект, от которого ушли f_balance_series/
-- f_balance_to_dates (000018/000019). Здесь курсор — последняя увиденная
-- пара (date, uuid) с предыдущей страницы: `(o.date, o.uuid) < (курсор)`
-- в ТОМ ЖЕ порядке ORDER BY date DESC, uuid DESC, что уже был — это условие
-- использует существующий индекс ix_operation_date (ledger_id, date DESC)
-- диапазонным сканом независимо от того, какая по счёту это страница.
--
-- p_limit/p_cursor_date/p_cursor_uuid — ТРЕЙЛИНГ-параметры с DEFAULT: первую
-- страницу вызывающий код зовёт БЕЗ двух последних (просто не передаёт их —
-- Postgres сам подставит DEFAULT NULL), не связываясь с NULL через $6/$7 —
-- db::Database::exec() ещё не умеет посылать настоящий NULL-параметр (все
-- параметры — непустые строки, см. db.hpp), а плодить эту возможность ради
-- одного места было бы лишним: тот же приём "два текста запроса под наличие/
-- отсутствие опционального параметра", что уже применяет resolve_eq_currency
-- к пустому ledger_id (см. её комментарий в reports_repo.hpp). p_limit без
-- DEFAULT технически можно было бы оставить обязательным (сервис его и
-- так всегда передаёт явно), но раз уж трейлинг-параметры с DEFAULT здесь
-- и так нужны для курсора, 1000 по умолчанию — тот же документирующий
-- сигнал, что "по умолчанию 1000" из прямого запроса, даже для гипотетичного
-- прямого вызова функции без обёртки.
--
-- "Подглядывание" на одну строку вперёд лимита (LIMIT p_limit — здесь ровно
-- то, что попросил вызывающий, включая эту лишнюю строку, если он сам решил
-- её попросить) — решение "есть ли ещё" вызывающий код (reports_repo.cpp)
-- принимает СВОИМ p_limit+1, не эта функция: она ничего не знает про has_more,
-- просто отдаёт до p_limit строк курсорным окном — общая формула, которую
-- можно вызвать и без "peek" (p_limit как есть), если когда-нибудь
-- понадобится.
DROP FUNCTION IF EXISTS f_operations_for_period(uuid, timestamp, timestamp, uuid);

CREATE FUNCTION f_operations_for_period(
    p_ledger_id   uuid,
    p_from        timestamp,
    p_to          timestamp,
    p_eq_currency uuid,
    p_limit       integer   DEFAULT 1000,
    p_cursor_date timestamp DEFAULT NULL,
    p_cursor_uuid uuid      DEFAULT NULL
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
       AND (p_cursor_date IS NULL OR (o."date", o.uuid) < (p_cursor_date, p_cursor_uuid))
     ORDER BY o."date" DESC, o.uuid DESC
     LIMIT p_limit;
$$;

GRANT EXECUTE ON FUNCTION f_operations_for_period(uuid, timestamp, timestamp, uuid, integer, timestamp, uuid) TO wallet_reader;
