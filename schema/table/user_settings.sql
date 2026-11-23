-- Личные настройки пользователя (change user-eq-currency, миграция 000045).
-- Одна строка на пользователя, не на леджер: предпочтение принадлежит
-- человеку и переносится между леджерами. Нет строки и NULL в колонке
-- значат одно и то же — «не выбрано».
--
-- eq_currency_iso — ISO-код, а не uuid валюты: uuid у каждого леджера свой,
-- код общий. Пишет его только PUT /api/settings (src/user_settings.cpp) —
-- в верхнем регистре и только если такая живая валюта видна леджеру
-- пользователя (общий справочник + свои). Если валюту потом удалили,
-- значение остаётся: клиенты видят, что её нет, и берут запасную.
--
-- Читают: wallet-api (GET /api/settings) и wallet-report (SELECT через
-- wallet_reader, отдаёт предпочтение вебу и MCP). Строка уходит каскадом при
-- удалении app_user (удаление аккаунта, account_deletion_repo).
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
