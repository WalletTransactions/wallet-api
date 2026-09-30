-- Пользователь, вошедший через Google. Пароля нет и не предполагается:
-- google-auth проверяет Google ID-токен и выдаёт свой JWT (см. ../../../google-auth/README.md).
--
-- id — НЕ gen_random_uuid(), это claim "sub" уже проверенного access-JWT
-- (внутренний UserRecord.id google-auth), а не идентичность, порождаемая
-- этой базой. Раньше здесь предполагался ещё один, третий слой идентичности
-- (отдельно от google_sub и от UserRecord.id google-auth) — по факту
-- реализации (2026-09-04) это оказалось лишним: wallet-api и так уже
-- доверяет `sub` из токена как непрозрачному идентификатору (тот же приём,
-- что раньше и демо-таблица wallets.owner_id) и не заводит свой собственный
-- id поверх него.
--
-- email — кэш claim "email" из JWT, только для показа и отчётов, не участвует
-- ни в одном решении о доступе.
--
-- disabled_at — мягкая блокировка входа, зарезервировано; сейчас ничего его
-- не выставляет (сама блокировка входа — дело google-auth, users.disabled_at
-- там пока тоже нет).
CREATE TABLE app_user (
    id          uuid PRIMARY KEY,
    email       text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    disabled_at timestamptz
);

COMMENT ON TABLE app_user IS
    'Пользователь wallet-api. Не отдельная идентичность — id это claim "sub" уже проверенного access-JWT (внутренний UserRecord.id google-auth), вся аутентификация и выпуск токенов централизованы в google-auth.';
COMMENT ON COLUMN app_user.id IS
    '= claim "sub" access-JWT, НЕ DEFAULT gen_random_uuid() — значение приходит извне, из уже проверенного токена, а не порождается этой базой.';
COMMENT ON COLUMN app_user.email IS
    'Кэш claim "email" из JWT — только для показа и отчётов, не участвует ни в одном решении о доступе; легитимно устаревает между обновлениями токена.';
COMMENT ON COLUMN app_user.created_at IS
    'Момент первого появления пользователя в этой базе (первый вызов provisioning::ensure_identity).';
COMMENT ON COLUMN app_user.disabled_at IS
    'Мягкая блокировка входа — зарезервировано, сейчас ничего его не выставляет (саму блокировку входа делает google-auth).';
