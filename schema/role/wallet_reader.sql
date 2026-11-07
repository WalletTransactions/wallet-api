-- Роль только для чтения: под ней работает сервис отчётов (архивный прототип
-- на Python удалён 2026-09-30; переезжает в C++, см.
-- ../../../wallet-infra/README.md) и любой ad-hoc SELECT по живой базе.
--
-- В прототипе эта роль была описана как «SELECT везде и ничего больше» —
-- то есть кандидат на чтение с реплики. Ни одной привилегии записи здесь не
-- выдаётся намеренно: отчёт, который может писать, однажды напишет.
--
-- ФАЙЛ ИДЕМПОТЕНТЕН И ЛЕЧАЩИЙ. Он не только создаёт роль, но и приводит уже
-- существующую к описанному здесь виду: ALTER ROLE ниже перезадаёт атрибуты, а
-- REVOKE снимает права записи, если их кто-то выдал руками. Причина конкретная —
-- роль, созданная с CONNECTION LIMIT 0, отвергает вообще все подключения с
-- «слишком много подключений для роли», и по сообщению это выглядит как
-- исчерпанный пул, а не как атрибут роли. Один раз так и случилось.
--
-- Пароль в репозитории. Это осознанно для локальной разработки: та же строка
-- лежит в server/.env.example, и другого секрета у роли с одним SELECT нет.
-- Для стенда с реальными данными пароль меняется вне этого файла:
--
--   ALTER ROLE wallet_reader PASSWORD '...';
--
-- и DSN сервиса берётся из окружения, а не из репозитория.

-- CREATE ROLE не умеет IF NOT EXISTS, отсюда блок.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'wallet_reader') THEN
        CREATE ROLE wallet_reader;
    END IF;
END
$$;

-- Атрибуты задаются отдельным ALTER, а не в CREATE: так они применяются и к
-- роли, которая уже была в базе. CONNECTION LIMIT 20 — это пул сервиса (10 по
-- умолчанию, packages/db) плюс запас на psql и на второй экземпляр сервиса при
-- перезапуске. Ставить -1 (без ограничения) не стоит: read-only роль не должна
-- иметь возможности съесть max_connections целиком.
ALTER ROLE wallet_reader
    LOGIN
    NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
    CONNECTION LIMIT 20
    PASSWORD 'wallet_reader';

-- Имя базы в DDL не зашито: apply.sql разворачивают и в wallet_dev, и в
-- wallet_test, и в проде. Отсюда format() по current_database().
DO $$
BEGIN
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO wallet_reader', current_database());
END
$$;

GRANT USAGE ON SCHEMA public TO wallet_reader;

-- ALL TABLES в PostgreSQL накрывает и представления: и таблица, и вьюха —
-- отношения. Поэтому отдельного гранта на view/ не нужно, но перечислять их
-- по одному было бы хуже — забытая вьюха обнаружилась бы только в рантайме.
GRANT SELECT ON ALL TABLES IN SCHEMA public TO wallet_reader;

-- account_asset (000033, capital-assets) уже накрыта строкой выше; явный грант
-- документирует зависимость: wallet-report сам делает LEFT JOIN account_asset
-- в /wallet-turnover и /accounts, и право не должно зависеть от того, кем и
-- когда создана таблица.
GRANT SELECT ON account_asset TO wallet_reader;

-- Отчётные функции объявлены SECURITY INVOKER (по умолчанию), то есть внутри
-- работают с правами вызывающего. Права на EXECUTE в PostgreSQL по умолчанию
-- есть у PUBLIC, так что этот блок ничего не открывает — он фиксирует, какие
-- именно функции сервису отчётов нужны (список растёт с каждым новым
-- отчётным экраном, см. wallet-api/schema/function/README.md).
GRANT EXECUTE ON FUNCTION f_balance_to_date(uuid, timestamp, uuid)             TO wallet_reader;
GRANT EXECUTE ON FUNCTION f_income_for_period(uuid, timestamp, timestamp, uuid)  TO wallet_reader;
GRANT EXECUTE ON FUNCTION f_expanse_for_period(uuid, timestamp, timestamp, uuid) TO wallet_reader;
GRANT EXECUTE ON FUNCTION f_expanse_by_category_for_period(uuid, timestamp, timestamp, uuid) TO wallet_reader;
GRANT EXECUTE ON FUNCTION f_expense_by_category_by_month(uuid, timestamp, timestamp, uuid) TO wallet_reader;
GRANT EXECUTE ON FUNCTION f_income_expense_by_month(uuid, timestamp, timestamp, uuid) TO wallet_reader;
GRANT EXECUTE ON FUNCTION f_expense_by_weekday_for_period(uuid, timestamp, timestamp, uuid) TO wallet_reader;
GRANT EXECUTE ON FUNCTION f_operations_for_period(uuid, timestamp, timestamp, uuid, integer, timestamp, uuid, uuid[], uuid[], text, text, uuid[], text[]) TO wallet_reader;
GRANT EXECUTE ON FUNCTION f_operations_total(uuid, timestamp, timestamp, uuid, uuid[], uuid[], text, text, uuid[], text[]) TO wallet_reader;
GRANT EXECUTE ON FUNCTION f_wallet_turnover_for_period(uuid, timestamp, timestamp, uuid) TO wallet_reader;
GRANT EXECUTE ON FUNCTION f_balance_to_dates(uuid, timestamp[], uuid) TO wallet_reader;
GRANT EXECUTE ON FUNCTION f_balance_series(uuid, date, date, text, uuid) TO wallet_reader;
GRANT EXECUTE ON FUNCTION f_assets_for_period(uuid, timestamp, timestamp, uuid) TO wallet_reader;

-- Снятие прав записи, если они у роли откуда-то есть. На свежей роли это
-- no-op; смысл строки — в том, что после прогона apply.sql состояние роли
-- известно, а не «зависит от истории базы».
--
-- Про next_seq() отдельно: EXECUTE на неё у PUBLIC остаётся, и wallet_reader
-- формально может её вызвать. Навредить это не даёт — функция делает UPDATE
-- change_stream, а SELECT-only роль получит отказ по правам на таблицу. Гасить
-- PUBLIC-грант здесь нельзя: следом пришлось бы выдавать EXECUTE будущей роли
-- wallet_api, которой в схеме ещё нет, и сервис синхронизации сломался бы
-- молча в момент появления.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
    ON ALL TABLES IN SCHEMA public FROM wallet_reader;

-- Таблицы, которые появятся позже (миграцией, новым релизом), должны читаться
-- без правки этого файла. Действует только на объекты, создаваемые ролью,
-- которая выполняет apply.sql, — то есть владельцем схемы.
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO wallet_reader;

-- Последовательностей в схеме нет вообще: идентичность строки — uuid, версия —
-- счётчик в change_stream (см. ../function/next_seq.sql). Поэтому гранта на
-- SEQUENCES здесь нет и добавлять его незачем.
