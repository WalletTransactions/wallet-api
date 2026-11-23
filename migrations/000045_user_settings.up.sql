-- Личные настройки пользователя (OpenSpec change user-eq-currency).
--
-- user_settings — одна строка на пользователя, не на леджер: предпочтение
-- принадлежит человеку и переносится между леджерами (design D2). Первая
-- настройка — валюта эквивалента: ISO-код, а не uuid валюты, потому что uuid
-- у каждого леджера свой (design D1). Нет строки и NULL значат одно и то же —
-- «не выбрано».
--
-- ON DELETE CASCADE от app_user: удаление аккаунта (account_deletion_repo,
-- DELETE FROM app_user) уносит и строку настроек.
--
-- GRANT SELECT роли wallet_reader — wallet-report отдаёт предпочтение вебу и
-- MCP. ALTER DEFAULT PRIVILEGES из 000002 уже накрывает новую таблицу; явный
-- грант документирует зависимость, как у account_asset (000033).

CREATE TABLE user_settings (
    user_id          uuid        PRIMARY KEY REFERENCES app_user (id) ON DELETE CASCADE,
    eq_currency_iso  text,
    updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_user_settings_updated_at BEFORE UPDATE ON user_settings
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE user_settings IS
    'Личные настройки пользователя (не леджера). Нет строки — всё по умолчанию.';
COMMENT ON COLUMN user_settings.user_id IS '= app_user.id; удаление пользователя каскадом удаляет строку.';
COMMENT ON COLUMN user_settings.eq_currency_iso IS
    'ISO-код валюты эквивалента в верхнем регистре; NULL — не выбрана. При записи код проверяется по живым валютам, видимым леджеру пользователя (PUT /api/settings); валюту могут удалить позже — тогда клиенты берут запасную.';
COMMENT ON COLUMN user_settings.updated_at IS 'Момент последнего изменения строки — только диагностика.';

GRANT SELECT ON user_settings TO wallet_reader;
