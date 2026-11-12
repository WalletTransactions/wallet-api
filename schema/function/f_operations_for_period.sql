-- "Список операций" (веб-отчёт, wallet-report/src/reports_repo.cpp
-- ::operations_for_period) — курсорная пагинация страницами (по умолчанию
-- 1000, см. p_limit ниже) и серверные фильтры (миграция 000027, change
-- add-operations-filter-functions): категории, кошельки, kind и подстрока
-- комментария q. Фильтры стоят ДО курсора и LIMIT — фильтр снаружи, после
-- лимита, сломал бы пагинацию (страница из 3 строк при has_more: true).
-- Итог по тем же условиям — f_operations_total.sql. Смысл и результаты —
-- спека wallet-report operations-list.
--
-- ФИЛЬТРЫ — трейлинг-параметры с DEFAULT NULL (NULL = фильтр не задан).
-- Позиционные вызовы с 5 и 7 аргументами (wallet-report до фильтров)
-- разрешаются в эту же функцию. Новые параметры передаются ИМЕНОВАННОЙ
-- нотацией и только заданные:
--   f_operations_for_period($1, $2, $3, $4, $5, p_kind => $6, p_q => $7)
-- — непереданный получает DEFAULT NULL в базе, SQL NULL клиенту слать не
-- нужно. Массивы — литералом '{uuid,uuid}' с $n::uuid[]; '{}' — «ни одного»
-- (пустой результат), а не «фильтр не задан».
-- - p_category_uuids — неоперационная сторона проводки в списке;
-- - p_wallet_uuids — операционная сторона в списке: прямой перевод кошелёк →
--   кошелёк подходит по любому из двух кошельков; uuid категории среди
--   кошельков (и наоборот) ни с чем не совпадёт;
-- - p_exclude_category_uuids (000030) — исключение: операции, чья
--   неоперационная сторона в списке, отбрасываются; прямой перевод
--   кошелёк → кошелёк (категории нет) остаётся;
-- - p_kind — то же выражение по флагам, что у колонки kind;
-- - p_q — strpos(lower(translate(comment, 'Ёё', 'Ее')), …) > 0: без учёта
--   регистра, «ё» = «е» (та же нормализация, что uq_account_name), % и _
--   ищутся буквально. Индекса под q нет — просмотр ограничен леджером и
--   периодом по ix_operation_date.
-- - p_qs (000032) — несколько вариантов той же подстроки: комментарий
--   подходит, если содержит ЛЮБОЙ элемент массива (правила как у p_q).
--   Операция, подходящая под два варианта, — одна строка. С p_q вместе —
--   по И (wallet-report их вместе не передаёт).
-- Проверка входных значений (допустимый kind, длина q, число uuid) — дело
-- wallet-report до вызова; функция просто фильтрует.
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
-- 000020_operations_pagination.up.sql, 000027_operations_filters.up.sql,
-- 000030_category_month_analytics.up.sql,
-- 000032_operations_text_variants.up.sql, 000033_capital_assets.up.sql,
-- 000036_debts.up.sql (см.
-- ../../README.md про этот принцип); этот файл — читаемое зеркало ТЕКУЩЕГО
-- состояния (после всех).
--
-- kind = 'revaluation' (000033, capital-assets) — первая ветка CASE: одна из
-- сторон проводки — счёт с system_kind = 3 («Переоценка»), без фильтра
-- deleted_at. Категория — «Переоценка», кошелёк — актив, как у
-- дохода/расхода. См. README.md, «Переоценка».
--
-- kind = 'debt' (000036, debts) — вторая ветка: прямой перевод (обе стороны —
-- живые кошельки), ровно одна сторона которого — долговой кошелёк (живая
-- строка account_debt). Перевод между двумя долговыми и проводки «долговой
-- кошелёк ↔ категория» (прощение, проценты, ноги разновалютного перевода
-- через Transfer) сохраняют прежний вид. Категории и кошелька у 'debt' нет,
-- как у transfer. Подпись «Дал / Взял / Вернул» сервер не хранит — её
-- вычисляет клиент по накопленному балансу. См. README.md, «Долги».
CREATE FUNCTION f_operations_for_period(
    p_ledger_id              uuid,
    p_from                   timestamp,
    p_to                     timestamp,
    p_eq_currency            uuid,
    p_limit                  integer   DEFAULT 1000,
    p_cursor_date            timestamp DEFAULT NULL,
    p_cursor_uuid            uuid      DEFAULT NULL,
    p_category_uuids         uuid[]    DEFAULT NULL,
    p_wallet_uuids           uuid[]    DEFAULT NULL,
    p_kind                   text      DEFAULT NULL,
    p_q                      text      DEFAULT NULL,
    p_exclude_category_uuids uuid[]    DEFAULT NULL,
    p_qs                     text[]    DEFAULT NULL
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
           CASE WHEN EXISTS (SELECT 1 FROM account r
                             WHERE r.ledger_id = p_ledger_id
                               AND r.uuid IN (o.acc_fr_uuid, o.acc_to_uuid)
                               AND r.system_kind = 3)                    THEN 'revaluation'
                WHEN o.acc_from_is_operating AND o.acc_to_is_operating
                 AND EXISTS (SELECT 1 FROM account_debt d
                              WHERE d.ledger_id = p_ledger_id AND d.uuid = o.acc_fr_uuid
                                AND d.deleted_at IS NULL)
                  <> EXISTS (SELECT 1 FROM account_debt d
                              WHERE d.ledger_id = p_ledger_id AND d.uuid = o.acc_to_uuid
                                AND d.deleted_at IS NULL)                THEN 'debt'
                WHEN o.acc_from_is_operating AND o.acc_to_is_operating THEN 'transfer'
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
            OR CASE WHEN EXISTS (SELECT 1 FROM account r
                                 WHERE r.ledger_id = p_ledger_id
                                   AND r.uuid IN (o.acc_fr_uuid, o.acc_to_uuid)
                                   AND r.system_kind = 3)                    THEN 'revaluation'
                    WHEN o.acc_from_is_operating AND o.acc_to_is_operating
                     AND EXISTS (SELECT 1 FROM account_debt d
                                  WHERE d.ledger_id = p_ledger_id AND d.uuid = o.acc_fr_uuid
                                    AND d.deleted_at IS NULL)
                      <> EXISTS (SELECT 1 FROM account_debt d
                                  WHERE d.ledger_id = p_ledger_id AND d.uuid = o.acc_to_uuid
                                    AND d.deleted_at IS NULL)                THEN 'debt'
                    WHEN o.acc_from_is_operating AND o.acc_to_is_operating THEN 'transfer'
                    WHEN o.acc_from_is_operating                           THEN 'expense'
                    ELSE                                                        'income' END = p_kind)
       AND (p_q IS NULL
            OR strpos(lower(translate(o.comment, 'Ёё', 'Ее')), lower(translate(p_q, 'Ёё', 'Ее'))) > 0)
       AND (p_qs IS NULL
            OR EXISTS (SELECT 1 FROM unnest(p_qs) AS v(q)
                        WHERE strpos(lower(translate(o.comment, 'Ёё', 'Ее')), lower(translate(v.q, 'Ёё', 'Ее'))) > 0))
       AND (p_cursor_date IS NULL OR (o."date", o.uuid) < (p_cursor_date, p_cursor_uuid))
     ORDER BY o."date" DESC, o.uuid DESC
     LIMIT p_limit;
$$;

COMMENT ON FUNCTION f_operations_for_period(uuid, timestamp, timestamp, uuid, integer, timestamp, uuid, uuid[], uuid[], text, text, uuid[], text[]) IS
    'Лента операций периода с курсором (date, uuid) и фильтрами (категории, исключённые категории, кошельки, kind, подстрока комментария q или любой из вариантов p_qs) до курсора и LIMIT. kind: revaluation, debt (прямой перевод, ровно одна сторона — долговой кошелёк), transfer, expense, income. Необязательные параметры передаются именованной нотацией, например p_kind => $6; NULL — фильтр не задан. Миграции 000027, 000030, 000032, 000033, 000036.';
