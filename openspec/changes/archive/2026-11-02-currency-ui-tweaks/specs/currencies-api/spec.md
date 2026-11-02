# Spec Delta

## Purpose

Веб-управление своими валютами леджера (тег `currencies` в `openapi.yaml`):
создание, правка и удаление, включая флаг «показывать в эквиваленте». Все
изменения доходят до телефонов обычным синком. Чтение справочника остаётся
в wallet-report (`GET /api/reports/currencies`).

## ADDED Requirements

### Requirement: Создание своей валюты
`POST /api/currencies` (`createCurrency`) с обязательными `name`,
`iso_code`, `icon_uuid` и необязательными `symbol`, `precision`,
`show_in_equivalent` SHALL создавать валюту леджера и отвечать `201` с её
строкой. `iso_code` приводится к верхнему регистру, края `name`/`symbol`
обрезаются. Пустой `symbol` = `iso_code`, `precision` по умолчанию 2,
флаг по умолчанию `true`. Леджер при необходимости создаётся.

#### Scenario: Минимальный запрос
- **WHEN** `POST /api/currencies` с `{name: "Тенге", iso_code: "kzt", icon_uuid: <флаг>}`
- **THEN** ответ `201`, валюта `KZT` с `symbol` = `KZT`, `precision` = 2, `show_in_equivalent` = `true`, `is_own` = `true`

#### Scenario: Невалидные поля
- **WHEN** `name` или `iso_code` пусты, `precision` вне 0–8 или не целое, `show_in_equivalent` не boolean
- **THEN** ответ `400` с `error`, называющим поле; ничего не создано

#### Scenario: Невидимая иконка
- **WHEN** `icon_uuid` не общая иконка и не иконка своего леджера
- **THEN** ответ `400`

### Requirement: Правка своей валюты
`PATCH /api/currencies/{uuid}` (`updateCurrency`) SHALL менять любое
подмножество полей `name`, `iso_code`, `symbol`, `precision`, `icon_uuid`,
`show_in_equivalent` у своей живой валюты по тем же правилам проверки и
отвечать `200` с обновлённой строкой. Общая, чужая или удалённая валюта —
`404`.

#### Scenario: Снять флаг эквивалента
- **WHEN** `PATCH` своей валюты с `{show_in_equivalent: false}`
- **THEN** ответ `200`, остальные поля не изменены

#### Scenario: Общая валюта
- **WHEN** `PATCH` или `DELETE` общей валюты (`ledger_id IS NULL`)
- **THEN** ответ `404`, валюта не изменена

### Requirement: Уникальность кода и названия
Создание и правка SHALL отвечать `409` `{"error":"duplicate","field":"iso_code"|"name"}`,
если код (после приведения к верхнему регистру) или название совпадают с
другой живой видимой валютой — своей или общей.

#### Scenario: Код как у общей валюты
- **WHEN** `POST /api/currencies` с `iso_code: "USD"`, а общая `USD` есть
- **THEN** ответ `409`, `error` = `duplicate`, `field` = `iso_code`

### Requirement: Код валюты из пары не меняется
`PATCH` с новым `iso_code` у валюты, которая входит в живую пару леджера
(базой или котируемой), SHALL отвечать `409`
`{"error":"currency_in_pair"}`: символ пары составлен из кодов её валют.
Остальные поля такой валюты правятся.

#### Scenario: Смена кода валюты пары
- **WHEN** своя `XAU` входит в пару `XAUUSD`, и `PATCH` несёт `iso_code: "GLD"`
- **THEN** ответ `409`, `error` = `currency_in_pair`, валюта не изменена

#### Scenario: Тот же код
- **WHEN** `PATCH` валюты пары несёт её текущий `iso_code` и новое `name`
- **THEN** ответ `200`, название изменено

### Requirement: Удаление своей валюты
`DELETE /api/currencies/{uuid}` (`deleteCurrency`) SHALL мягко удалять
свою валюту (`204`). Если на неё ссылается живой кошелёк или живая пара —
`409` `{"error":"currency_in_use"}`, валюта не удалена.

#### Scenario: Валюта кошелька
- **WHEN** удаляется валюта, в которой есть живой кошелёк
- **THEN** ответ `409`, `error` = `currency_in_use`

#### Scenario: Свободная валюта
- **WHEN** удаляется своя валюта без кошельков и пар
- **THEN** ответ `204`, валюта уходит в поток леджера tombstone'ом

### Requirement: Изменения валют едут в синк
Каждое изменение SHALL быть одной транзакцией с одним новым `seq` потока
леджера и приходить на устройства обычным `GET /sync/pull`. `updated_by`
пуст. Роль участника не проверяется.

#### Scenario: Валюта с веба на телефоне
- **WHEN** пользователь изменил название своей валюты в вебе
- **THEN** при следующем pull телефон получает эту строку в `ledger.changes.currency`
