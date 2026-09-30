-- Откат 000023_device_platform_telegram.up.sql. Строки бота не удаляются
-- (на device ссылаются курсоры и updated_by), а переводятся в 'other' —
-- иначе старый CHECK не встанет.
UPDATE device SET platform = 'other' WHERE platform = 'telegram';
ALTER TABLE device DROP CONSTRAINT device_platform_check;
ALTER TABLE device ADD CONSTRAINT device_platform_check
    CHECK (platform IN ('android', 'ios', 'web', 'other', ''));

COMMENT ON COLUMN device.platform IS
    '''android''/''ios''/''web''/''other'' — из тела запроса мобильного входа (POST /auth/google/mobile); пустая строка — браузерный вход, где устройства как такового нет.';
