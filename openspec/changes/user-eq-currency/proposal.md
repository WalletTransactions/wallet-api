# Proposal

## Why

Issue [.github-private#19](https://github.com/WalletTransactions/.github-private/issues/19). Каждый клиент сейчас выбирает валюту
эквивалента по-своему: Android хранит её в настройках устройства, веб — в
`localStorage` браузера, а MCP берёт валюту первого кошелька по алфавиту.
На test чат ответил про расходы в албанских леках, потому что первым по
имени идёт кошелёк «Albanian». Пользователь выбрал EUR в вебе, но сервер об
этом не знает.

Решение владельца: явная валюта эквивалента в настройках пользователя на
сервере, в этом заходе её пишет веб и читает MCP (через wallet-report).
Android переводится позже.

## What Changes

- Таблица `user_settings` (личная, не леджера): `user_id` → `eq_currency_iso`.
- `GET /api/settings` — `{"eq_currency": "EUR" | null}`.
- `PUT /api/settings` с `{"eq_currency": "EUR" | null}` — сохранить или
  сбросить. Код должен быть в справочнике валют леджера пользователя.
- Обе ручки требуют scope `account` (сессии веба и Android); у токенов бота и
  MCP его нет.
- `wallet_reader` получает `SELECT` на таблицу: wallet-report отдаёт
  предпочтение MCP и вебу.
- Удаление аккаунта удаляет и строку настроек.

## Capabilities

### New Capabilities

- `user-settings-api`: хранение и ручки личных настроек пользователя.

### Modified Capabilities

Нет.

## Impact

- Код: миграция, `schema/table/user_settings.sql`, новый
  `src/user_settings.{hpp,cpp}` + репозиторий, `src/access.cpp` (scope),
  `openapi.yaml`, тесты.
- Пары: wallet-report `user-eq-currency` (отдаёт `preferred_eq_currency`),
  wallet-web `user-eq-currency` (пишет), wallet-mcp `user-eq-currency`
  (читает).
- Совместимость: новая таблица и новые ручки, старое не меняется.
