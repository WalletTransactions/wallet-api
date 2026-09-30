-- "Список операций" (веб-отчёт, wallet-report/src/reports_repo.cpp
-- ::operations_for_period) — курсорная пагинация страницами (по умолчанию
-- 1000, см. p_limit ниже), поиск/фильтр по типу/категории/кошельку и
-- группировку по дню сервис делает уже на своей стороне над каждой такой
-- страницей (см. reports_repo.hpp) — тем же приёмом, что дизайн-прототип
-- держит всю ленту в памяти и фильтрует её без похода в сеть, просто теперь
-- "лента" загружается по частям, а не целиком одним запросом.
--
-- ПАГИНАЦИЯ — по прямому запросу (2026-09-12, "давай улучшим операции...
-- если выбираем 20 лет, то нет необходимости доставать всё"): раньше
-- функция отдавала ВЕСЬ период одним запросом — для активного пользователя
-- за много лет это тысячи строк с джойнами на каждый показ "Обзора"/
-- "Динамики"/"Категорий" (они читают этот же эндпоинт целиком для
-- клиентской агрегации) и особенно самого "Списка операций" (там чаще
-- всего смотрят только первую страницу).
--
-- Курсорная, не OFFSET: OFFSET N на глубокой странице заставил бы Postgres
-- каждый раз заново пересчитывать и отбрасывать N строк — тот же
-- квадратичный по числу страниц эффект, от которого ушли f_balance_series/
-- f_balance_to_dates (000018/000019). Курсор — последняя увиденная пара
-- (date, uuid) с предыдущей страницы: `(o.date, o.uuid) < (курсор)` в ТОМ
-- ЖЕ порядке, что и ORDER BY date DESC, uuid DESC — использует
-- ix_operation_date (ledger_id, date DESC) диапазонным сканом независимо от
-- номера страницы.
--
-- p_limit/p_cursor_date/p_cursor_uuid — трейлинг-параметры с DEFAULT:
-- первую страницу вызывающий код зовёт БЕЗ двух последних (Postgres сам
-- подставит DEFAULT NULL) — тот же приём "два текста запроса под наличие/
-- отсутствие опционального параметра", что уже применяет resolve_eq_currency
-- к пустому ledger_id (db::Database::exec() не умеет посылать настоящий
-- NULL-параметр, см. reports_repo.cpp::operations_for_period).
-- "Подглядывание" на одну строку вперёд лимита (чтобы узнать has_more, не
-- соврав на ровно последней странице) — забота вызывающего кода (передаёт
-- p_limit+1), не этой функции: она просто отдаёт до p_limit строк курсорным
-- окном.
--
-- kind вычисляется тем же признаком, что и везде в отчётах
-- (acc_from_is_operating/acc_to_is_operating), и НЕ требует отдельного
-- разбора operation_link: разновалютный перевод между кошельками — это ДВЕ
-- строки через системную категорию Transfer (expense от одного кошелька,
-- income в другой), они и так корректно попадают сюда как обычный
-- расход/доход по категории "Transfer" — ровно то же, что уже делают
-- f_expanse_by_category_for_period и весь остальной отчёт (см. память
-- проекта: переводы считаются расходом в отчётах). "Настоящий" перевод
-- (kind = 'transfer') — только прямая проводка кошелёк -> кошелёк, у неё
-- обе стороны operating, категории нет вовсе.
--
-- category/wallet — NULL для transfer (у перевода кошелёк-кошелёк нет
-- категории и нет ОДНОГО кошелька, участвуют оба — они в from/to). Для
-- expense/income выбирается ТА сторона проводки, что operating (wallet) /
-- не operating (category) соответственно.
--
-- amount (своя сумма) округляется по precision СВОЕЙ валюты (cur, а не
-- эквивалента) — тем же приёмом, что f_expanse_for_period/f_income_for_period:
-- operation.amount хранится как numeric(20,8), без округления клиент увидел
-- бы "40.00000000" вместо "40.00". amount_eq округлять здесь не нужно — он
-- уже округлён по precision эквивалента внутри v_operation_eq.
--
-- Источник истины — реальные миграции
-- wallet-api/migrations/000007_operations.up.sql и
-- 000020_operations_pagination.up.sql (см. ../../README.md про этот
-- принцип); этот файл — читаемое зеркало ТЕКУЩЕГО состояния (после обеих).
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
