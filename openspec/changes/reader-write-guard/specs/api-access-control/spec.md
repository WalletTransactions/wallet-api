## ADDED Requirements

### Requirement: Запись только для владельца и участника
После проверки scope пишущие методы (`POST`, `PATCH`, `DELETE`)
`/api/currencies*`, `/api/currency-pairs*` и `/api/currency-routes*` SHALL
отвечать участнику с ролью `reader` `403` `{"error":"reader_cannot_write"}`
до любых изменений. Scope `wallet:write` роль не заменяет.

#### Scenario: Читатель правит валюту
- **WHEN** читатель с токеном `wallet:read wallet:write` вызывает `PATCH /api/currencies/{uuid}`
- **THEN** ответ `403`, `error` = `reader_cannot_write`, валюта не изменена

#### Scenario: Читатель смотрит маршруты
- **WHEN** читатель вызывает `GET /api/currency-routes`
- **THEN** ответ `200`

### Requirement: Предел тела запроса
Сервис SHALL принимать тело запроса не больше 8 МБ: запрос, прошедший
проверку токена, с телом больше — `413` без чтения тела (без токена — `401`,
тело тоже не читается).

#### Scenario: Слишком большое тело
- **WHEN** на `POST /sync/push` с действующим токеном приходит тело 9 МБ
- **THEN** ответ `413`, тело не разбирается
