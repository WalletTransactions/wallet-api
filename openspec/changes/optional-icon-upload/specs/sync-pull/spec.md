# Spec Delta

## ADDED Requirements

### Requirement: Возможности сервера в ответе
Ответ `GET /sync/pull` SHALL содержать блок `capabilities` с булевым полем
`icon_upload` — текущим значением флага загрузки своих иконок
(`icon-upload-flag`). Блок SHALL присутствовать в каждом ответе, в том числе
со сбросом курсора и без изменений, и не зависеть от `ledger_id`, курсоров и
роли. Клиент без знания блока SHALL продолжать работать: остальные поля ответа
не меняются.

#### Scenario: Флаг выключен
- **WHEN** флаг выключен и клиент делает pull
- **THEN** в ответе `capabilities.icon_upload` равно `false`

#### Scenario: Флаг включён, изменений нет
- **WHEN** флаг включён и клиент делает pull с курсором, равным голове
- **THEN** `changes` пуст, `capabilities.icon_upload` равно `true`
