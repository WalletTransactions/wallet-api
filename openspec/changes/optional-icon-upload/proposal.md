# Proposal

## Why

Прежние версии приложения заливали свои иконки на сервер, change
`server-managed-icons` (android-wallet, 2026-11-04) эту отправку убрал: самая
тяжёлая и хрупкая часть синка, а набор ведёт администратор. Теперь свои иконки
нужно вернуть как **опцию**: пользователь может положить иконку в свой набор на
сервере, но оператор сервиса должен уметь выключить приём (место, модерация,
инцидент), не ломая синк остального. Клиент должен узнавать о запрете заранее
и после отказа сам отключать у себя отправку (парный change android-wallet
`optional-icon-upload`).

## What Changes

- Серверный флаг `LEDGER_ICON_UPLOAD` (`on`/`off`, по умолчанию `off`):
  разрешена ли загрузка своих иконок леджера обычными пользователями.
- `GET /sync/pull` в ответе получает блок `capabilities` с
  `icon_upload` (bool) — клиент узнаёт о флаге до отправки.
- `POST /sync/blobs` при выключенном флаге — `403 icon_upload_disabled`
  (администратору, грузящему общие иконки, не мешает).
- `POST /sync/push` при выключенном флаге **принимает остальной батч**, а строки
  `icon` отбрасывает и перечисляет в ответе (`icons_rejected`), код
  `icon_upload_disabled`. **BREAKING для старых клиентов — нет:** они иконки не
  шлют (см. `server-managed-icons`); поле ответа новое и необязательное.
- Включённый флаг ничего не меняет в текущем поведении приёма иконок.

## Capabilities

### New Capabilities
- `icon-upload-flag`: серверный флаг приёма своих иконок — значение по
  умолчанию, источник, кому и что запрещено, как о нём узнаёт клиент.

### Modified Capabilities
- `icon-blobs`: загрузка содержимого учитывает флаг (403 для не-админа).
- `sync-push`: строки `icon` при выключенном флаге отбрасываются, ответ
  сообщает об этом, остальной батч применяется.
- `sync-pull`: ответ содержит `capabilities.icon_upload`.

## Impact

- Код wallet-api: `src/main.cpp` (чтение env, `AppState`), `src/app_state.hpp`,
  `src/blob.cpp` (проверка в `handle_upload`), `src/sync_repo.cpp`/`src/sync.cpp`
  (фильтр `icon` в push, блок `capabilities` в pull).
- `openapi.yaml`, `README.md` (переменная окружения), тесты в `tests/` и
  `tests_integration/`. Миграций БД нет.
- wallet-infra: переменная `LEDGER_ICON_UPLOAD` в `test.env`/`prod.env`
  (отдельный PR в infra, выкатка rc-тегом).
- Клиенты: android-wallet — парный change; wallet-telegram иконок не шлёт;
  wallet-report и wallet-web — без правок.
