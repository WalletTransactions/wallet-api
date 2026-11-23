## 1. Хранение

- [x] 1.1 Миграция `user_settings` (`user_id` PK → `app_user` ON DELETE CASCADE, `eq_currency_iso text NULL`, `updated_at`), `schema/table/user_settings.sql` с комментариями, `GRANT SELECT ... TO wallet_reader`. Проверка: миграция вверх/вниз на чистой базе; удаление `app_user` удаляет строку

## 2. Ручки

- [x] 2.1 `GET`/`PUT /api/settings` (`src/user_settings.{hpp,cpp}` + репозиторий), проверка кода по валютам, видимым леджеру (D3), scope `account` в `src/access.cpp`. Проверка: интеграционные тесты по сценариям спеки (не выбрано, сохранение в нижнем регистре, неизвестная валюта, сброс, reader, токен wallet-api без `account` → 403); `ctest` зелёный
- [x] 2.2 `openapi.yaml` и README: ручки и схема `UserSettings`. Проверка: `openapi.yaml` проходит линт, как в CI

## 3. Выкат

- [x] 3.1 rc на test раньше wallet-report и wallet-web. Проверка: `PUT` с токеном веб-сессии сохраняет `EUR`, в базе test строка есть
