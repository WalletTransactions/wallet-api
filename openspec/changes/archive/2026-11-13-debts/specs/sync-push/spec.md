# Spec Delta

## MODIFIED Requirements

### Requirement: Состав запроса
Тело push SHALL быть JSON-объектом с непустым `batch_id` и объектом
`changes` вида `{"<таблица>": [строки]}` (схема — `openapi.yaml`,
`syncPush`). Синхронизируемые таблицы: `icon`, `currency`, `currency_pair`,
`currency_pair_rate`, `currency_conversion`, `account`, `account_operating`,
`account_asset`, `counterparty`, `account_debt`, `operation`,
`operation_link`.

#### Scenario: Нет batch_id
- **WHEN** тело push не содержит `batch_id`
- **THEN** ответ `400`, ничего не применено

#### Scenario: Тело не JSON
- **WHEN** тело push не разбирается как JSON
- **THEN** ответ `400` с `error` = `invalid JSON body`

#### Scenario: Батч с признаком актива
- **WHEN** `changes` содержит массив `account_asset`
- **THEN** его строки применяются, а не пропускаются как неизвестная таблица

#### Scenario: Батч с контрагентами и долгами
- **WHEN** `changes` содержит массивы `counterparty` и `account_debt`
- **THEN** их строки применяются, а не пропускаются как неизвестные таблицы

### Requirement: Порядок применения по зависимостям
Таблицы батча SHALL применяться в порядке `icon`, `currency`,
`currency_pair`, `currency_pair_rate`, `currency_conversion`, `account`,
`account_operating`, `account_asset`, `counterparty`, `account_debt`,
`operation`, `operation_link`, независимо от порядка ключей в теле, чтобы
ссылки внутри одного батча разрешались.

#### Scenario: Новая валюта и кошелёк в ней одним батчем
- **WHEN** батч несёт новую `currency` и `account_operating`, ссылающуюся на неё
- **THEN** батч применяется без ошибки внешнего ключа

#### Scenario: Новый актив одним батчем
- **WHEN** батч несёт новые `account`, `account_operating` и `account_asset` одного кошелька
- **THEN** батч применяется без ошибки внешнего ключа

#### Scenario: Новый долг одним батчем
- **WHEN** батч несёт новые `counterparty`, `account`, `account_operating`, `account_debt` и `operation` на этот кошелёк
- **THEN** батч применяется без ошибки внешнего ключа

### Requirement: Строка без обязательного поля
Строка без `uuid` или без бизнес-колонки своей таблицы, а также с полем
неожиданного типа или значением вне допустимого набора колонки SHALL давать
`400` `{"error":"invalid_row","detail":"<что не так>"}`. Батч откатывается.
Исключение — колонки, которые требования явно называют необязательными
(`currency.show_in_equivalent`, `account_debt.due_date`,
`counterparty.icon_uuid`): их отсутствие не ошибка, а неверный тип —
ошибка.

#### Scenario: Старый клиент без новой колонки
- **WHEN** строка `account` не несёт `kind`
- **THEN** ответ `400`, `error` = `invalid_row`, `detail` называет поле

#### Scenario: Значение вне допустимого набора
- **WHEN** строка `account` несёт `system_kind` = `9`
- **THEN** ответ `400`, `error` = `invalid_row`, а не `500`

#### Scenario: Необязательная колонка неверного типа
- **WHEN** строка `account_debt` несёт `due_date` = `"завтра"`
- **THEN** ответ `400`, `error` = `invalid_row`, `detail` называет `due_date`, батч не применён

#### Scenario: Долг без срока
- **WHEN** строка `account_debt` не несёт `due_date`
- **THEN** ответ `200`, срок не задан
