## MODIFIED Requirements

### Requirement: Читатель не пишет через бота
Участнику с ролью `reader` push с непустым `changes` SHALL отвечать `403`
`{"error":"reader_cannot_write"}` до применения и до проверки повтора, при
любом scope токена (`wallet:write` или `expense:write`). Батч без строк
SHALL проходить: он ничего не меняет.

#### Scenario: Читатель подтвердил трату в боте
- **WHEN** читатель леджера отправляет push токеном `expense:write`
- **THEN** ответ `403`, `error` = `reader_cannot_write`

#### Scenario: Читатель удаляет данные с телефона
- **WHEN** читатель отправляет токеном `wallet:write` push со строкой `deleted: true`
- **THEN** ответ `403`, `error` = `reader_cannot_write`, строка не изменена

#### Scenario: Холостой push читателя
- **WHEN** читатель отправляет push, где все таблицы `changes` пусты
- **THEN** ответ `200`
