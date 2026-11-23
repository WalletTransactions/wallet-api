## ADDED Requirements

### Requirement: Хранение валюты эквивалента пользователя
Сервис SHALL хранить для каждого пользователя необязательный ISO-код валюты
эквивалента в таблице `user_settings`, отдельно от данных леджера. Нет строки
и `NULL` означают «не выбрано». Удаление аккаунта SHALL удалять и эту строку.
Роль `wallet_reader` SHALL иметь `SELECT` на таблицу.

#### Scenario: Удаление аккаунта
- **WHEN** пользователь с сохранённой валютой `EUR` удаляет аккаунт
- **THEN** строки `user_settings` этого пользователя нет

### Requirement: Чтение настроек
`GET /api/settings` SHALL отвечать `200 {"eq_currency": "<ISO>"}` или
`{"eq_currency": null}`, если валюта не выбрана. Нужен scope `account`.

#### Scenario: Не выбрано
- **WHEN** пользователь ещё ничего не сохранял
- **THEN** `200 {"eq_currency": null}`

#### Scenario: Токен без account
- **WHEN** запрос с токеном для wallet-api, в `scope` которого нет `account` (например, только `wallet:read`)
- **THEN** `403` с `insufficient_scope`

### Requirement: Запись валюты эквивалента
`PUT /api/settings` с телом `{"eq_currency": "<код>" | null}` SHALL сохранять
код в верхнем регистре, если он есть среди живых валют, видимых леджеру
пользователя, и отвечать `200` с сохранённым значением; `null` сбрасывает
выбор. Неизвестный код — `400 {"error":"unknown_currency"}` без изменений.
Нужен scope `account`; роль в леджере значения не имеет.

#### Scenario: Сохранение
- **WHEN** в справочнике леджера есть `EUR`, `PUT {"eq_currency": "eur"}`
- **THEN** `200 {"eq_currency": "EUR"}`, следующий `GET` возвращает `EUR`

#### Scenario: Неизвестная валюта
- **WHEN** `PUT {"eq_currency": "XYZ"}`, такой валюты в справочнике нет
- **THEN** `400 {"error":"unknown_currency"}`, сохранённое значение прежнее

#### Scenario: Сброс
- **WHEN** сохранено `EUR`, `PUT {"eq_currency": null}`
- **THEN** `200 {"eq_currency": null}`

#### Scenario: Участник с ролью reader
- **WHEN** участник общего леджера с ролью reader сохраняет `EUR`
- **THEN** `200`, значение сохранено
