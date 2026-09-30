-- Бот wallet-telegram — ещё одно устройство пользователя
-- (servers/TODO_telegram_bot.md, §1.1): google-auth заводит ему
-- device-сессию с platform = 'telegram', а provisioning.cpp вставляет
-- platform из JWT в device как есть — без этого значения в CHECK первый же
-- /sync/* от бота упал бы 500 на нарушении ограничения.
--
-- Имя device_platform_check — автоматическое (ограничение объявлено прямо
-- на колонке в 000002_ledger_sync без CONSTRAINT <имя>).
ALTER TABLE device DROP CONSTRAINT device_platform_check;
ALTER TABLE device ADD CONSTRAINT device_platform_check
    CHECK (platform IN ('android', 'ios', 'web', 'telegram', 'other', ''));

COMMENT ON COLUMN device.platform IS
    '''android''/''ios''/''web''/''telegram''/''other'' — из тела запроса мобильного входа (POST /auth/google/mobile) или обмена кода связывания Telegram-бота; пустая строка — браузерный вход, где устройства как такового нет.';
