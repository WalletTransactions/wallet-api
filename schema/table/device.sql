-- Устройство пользователя — книга устройств для курсоров синка и
-- диагностики ("какое устройство последним писало", last_ack_seq и т.п.),
-- НЕ точка выдачи/ротации refresh-токенов. Раньше здесь предполагалась
-- полная модель ротации (refresh_hash/refresh_family/refresh_prev_hash/...)
-- — по факту реализации (2026-09-04) вся выдача, ротация и отзыв токенов
-- централизована в google-auth (Redis, см. его README "Детали устройства"),
-- wallet-api токены не выпускает и не ротирует вообще, только проверяет уже
-- готовый JWT по JWKS. Заводить здесь параллельную инфраструктуру ротации,
-- которой ничто не пользуется, было бы декорацией.
--
-- id — claim "device_id" уже проверенного access-JWT (генерирует Android
-- при первой установке, см. AppSettings.getOrCreateDeviceId в клиенте), а
-- не порождается этой базой — тот же приём, что и у app_user.id.
--
-- name/platform — из тела запроса мобильного входа (google-auth,
-- POST /auth/google/mobile) или обмена кода связывания Telegram-бота
-- (platform = 'telegram', см. org/docs/TODO_telegram_bot.md), только для
-- показа человеку; platform заодно
-- долетает как claim токена. last_ack_seq — справочная копия курсора
-- клиента для диагностики и «сбросить синхронизацию на этом устройстве»;
-- авторитетный курсор всё равно на клиенте — сервер не знает, доехала ли до
-- него последняя страница.
CREATE TABLE device (
    id           uuid PRIMARY KEY,
    user_id      uuid NOT NULL REFERENCES app_user (id) ON DELETE CASCADE,
    ledger_id    uuid NOT NULL REFERENCES ledger (id)   ON DELETE CASCADE,
    platform     text NOT NULL DEFAULT '' CHECK (platform IN ('android', 'ios', 'web', 'telegram', 'other', '')),
    name         text NOT NULL DEFAULT '',

    last_seen_at timestamptz,
    last_ack_seq bigint,
    created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ix_device_user   ON device (user_id);
CREATE INDEX ix_device_ledger ON device (ledger_id);

COMMENT ON TABLE device IS
    'Устройство пользователя — книга устройств для курсоров синка и диагностики ("какое устройство последним писало"), НЕ точка выдачи/ротации refresh-токенов (это целиком делает google-auth).';
COMMENT ON COLUMN device.id IS
    '= claim "device_id" уже проверенного access-JWT (генерирует Android при первой установке, см. AppSettings.getOrCreateDeviceId), не порождается этой базой.';
COMMENT ON COLUMN device.user_id IS 'Владелец устройства.';
COMMENT ON COLUMN device.ledger_id IS 'Леджер, с которым это устройство синхронизируется.';
COMMENT ON COLUMN device.platform IS
    '''android''/''ios''/''web''/''telegram''/''other'' — из тела запроса мобильного входа (POST /auth/google/mobile) или обмена кода связывания Telegram-бота; пустая строка — браузерный вход, где устройства как такового нет.';
COMMENT ON COLUMN device.name IS
    'Человекочитаемое имя устройства (модель телефона и т.п.), только для показа человеку — см. README google-auth, "Детали устройства".';
COMMENT ON COLUMN device.last_seen_at IS 'Момент последнего успешного обращения устройства к /sync/*.';
COMMENT ON COLUMN device.last_ack_seq IS
    'Справочная копия курсора клиента — только для диагностики и "сбросить синхронизацию на этом устройстве". Авторитетный курсор всё равно хранится на клиенте — сервер не знает, доехала ли до него последняя страница.';
COMMENT ON COLUMN device.created_at IS 'Момент первой регистрации устройства.';
