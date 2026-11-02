# Proposal

## Why

Это серверная часть набора мелких правок интерфейса `currency-ui-tweaks`
(парные changes: `android-wallet`, `wallet-web`, `wallet-report`). Нужно две
вещи.

1. Пикеры «Валюта эквивалента» показывают весь справочник валют, включая
   крипту, локальные валюты и активы, в которых эквивалент не считают.
   Пользователь хочет сам отмечать валюты для эквивалента, но такого
   атрибута у валюты нет.
2. Свои валюты должны править и телефон, и веб. Телефон пишет через синк, а
   у веба записи валют нет совсем: в wallet-api нет ни одного эндпоинта для
   валют.

## What Changes

- У `currency` появляется колонка `show_in_equivalent boolean NOT NULL
  DEFAULT true` (новая миграция с down-файлом). Существующие валюты получают
  `true`, поэтому поведение не меняется, пока флаг не сняли.
- Синк: `currency.show_in_equivalent` приходит в pull и принимается в push.
  Строка push **без** этого ключа (старый клиент) не падает: новая валюта
  получает `true`, у существующей значение сохраняется.
- Новый REST для своих валют леджера по образцу `/api/currency-pairs*`:
  `POST /api/currencies`, `PATCH /api/currencies/{uuid}`, `DELETE
  /api/currencies/{uuid}`. Поля: название, ISO-код, символ, точность,
  иконка, флаг эквивалента. Правила те же, что у формы валюты на телефоне:
  код и название уникальны среди видимых валют, валюта кошелька или пары не
  удаляется. Дополнительно код валюты, входящей в пару, не меняется.
  Общие валюты REST не меняет (`404`).
- Чтение справочника остаётся в wallet-report (`GET
  /api/reports/currencies`), отдельного `GET` здесь нет.

## Capabilities

### New Capabilities
- `currencies-api`: создание, правка и удаление своих валют через REST и
  доставка изменений на устройства синком.

### Modified Capabilities
- `sync-push`: новое требование «Флаг эквивалента у валюты» (отсутствие
  ключа не ошибка; значение по умолчанию или прежнее) и правка «Строка без
  обязательного поля»: исключение для явно необязательных колонок.
- `sync-pull`: в строке валюты явно появляется `show_in_equivalent`.
- `api-access-control`: `/api/currencies*` добавляется в правило scope
  (`wallet:write` на запись).

## Impact

- `migrations/000026_currency_show_in_equivalent.{up,down}.sql`,
  `schema/table/currency.sql` (колонка и `COMMENT`).
- `src/sync_repo.{hpp,cpp}`: `TableSpec::optional_columns`, сборка upsert.
- Новые `src/currencies.cpp` и `src/currencies_repo.{hpp,cpp}`,
  регистрация маршрутов и scope (`/api/currencies*`).
- `openapi.yaml` (тег `currencies`, строка `currency` в `syncPush`/`syncPull`),
  `README.md`.
- wallet-gateway без правок: `/api/*` уже проксируется в wallet-api.
- Клиенты: `android-wallet` (флаг, синк), `wallet-report` (поля
  справочника), `wallet-web` (форма валюты поверх этого REST).
  `wallet-telegram` валюты не пишет.
