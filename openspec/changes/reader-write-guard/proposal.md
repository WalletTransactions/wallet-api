## Why

Аудит безопасности 2026-11-23: роль `reader` в общем леджере проверялась только
у токена бота (`expense:write`). Читатель входит на телефоне или в вебе, его
токен несёт `wallet:write`, и `POST /sync/push` с `deleted: true` по всем
строкам или REST валют/пар/курсов/маршрутов удаляли и переписывали чужой
леджер. Отдельно — предел тела запроса: дефолт httplib 100 МБ, тело с действующим
токеном читалось целиком в память и разбиралось как JSON.

## What Changes

- Участник с ролью `reader` получает `403` `{"error":"reader_cannot_write"}`
  на push с непустым `changes` при любом scope и на всех `POST`/`PATCH`/`DELETE`
  `/api/currencies*`, `/api/currency-pairs*`, `/api/currency-routes*`. Push без
  строк проходит.
- Предел тела запроса — 8 МБ, больше — `413`.

## Capabilities

### Modified Capabilities

- `sync-push` — читатель не пишет ни одним токеном.
- `ledger-provisioning` — от роли зависит право записи.
- `api-access-control` — роль проверяется после scope; предел тела.

## Impact

- Код: `src/ledger_write_guard.hpp`, `src/sync.cpp`, `src/currencies.cpp`,
  `src/currency_pairs.cpp`, `src/currency_routes.cpp`, `src/main.cpp`;
  `openapi.yaml` (`403 reader_cannot_write`, `413`), `README.md`.
- wallet-web и wallet-telegram код `reader_cannot_write` уже понимают.
- **android-wallet** роли не знает: у телефона читателя с локальными правками
  push получит `403`, а ошибка push останавливает pull. Нужен read-only режим
  в клиенте — отдельный change в android-wallet; до него читателям с телефоном
  не стоит править данные.
