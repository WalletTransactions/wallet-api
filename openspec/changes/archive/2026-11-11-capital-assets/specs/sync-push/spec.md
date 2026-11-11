# Spec Delta

## MODIFIED Requirements

### Requirement: Состав запроса
Тело push SHALL быть JSON-объектом с непустым `batch_id` и объектом
`changes` вида `{"<таблица>": [строки]}` (схема — `openapi.yaml`,
`syncPush`). Синхронизируемые таблицы: `icon`, `currency`, `currency_pair`,
`currency_pair_rate`, `currency_conversion`, `account`, `account_operating`,
`account_asset`, `operation`, `operation_link`.

#### Scenario: Нет batch_id
- **WHEN** тело push не содержит `batch_id`
- **THEN** ответ `400`, ничего не применено

#### Scenario: Тело не JSON
- **WHEN** тело push не разбирается как JSON
- **THEN** ответ `400` с `error` = `invalid JSON body`

#### Scenario: Батч с признаком актива
- **WHEN** `changes` содержит массив `account_asset`
- **THEN** его строки применяются, а не пропускаются как неизвестная таблица

### Requirement: Порядок применения по зависимостям
Таблицы батча SHALL применяться в порядке `icon`, `currency`,
`currency_pair`, `currency_pair_rate`, `currency_conversion`, `account`,
`account_operating`, `account_asset`, `operation`, `operation_link`,
независимо от порядка ключей в теле, чтобы ссылки внутри одного батча
разрешались.

#### Scenario: Новая валюта и кошелёк в ней одним батчем
- **WHEN** батч несёт новую `currency` и `account_operating`, ссылающуюся на неё
- **THEN** батч применяется без ошибки внешнего ключа

#### Scenario: Новый актив одним батчем
- **WHEN** батч несёт новые `account`, `account_operating` и `account_asset` одного кошелька
- **THEN** батч применяется без ошибки внешнего ключа

### Requirement: Строка без обязательного поля
Строка без `uuid` или без бизнес-колонки своей таблицы, а также с полем
неожиданного типа или значением вне допустимого набора колонки SHALL давать
`400` `{"error":"invalid_row","detail":"<что не так>"}`. Батч откатывается.
Исключение — колонки, которые требования явно называют необязательными
(`currency.show_in_equivalent`): их отсутствие не ошибка, а неверный тип —
ошибка.

#### Scenario: Старый клиент без новой колонки
- **WHEN** строка `account` не несёт `kind`
- **THEN** ответ `400`, `error` = `invalid_row`, `detail` называет поле

#### Scenario: Необязательная колонка неверного типа
- **WHEN** строка `currency` несёт `show_in_equivalent` = `"yes"`
- **THEN** ответ `400`, `error` = `invalid_row`, `detail` называет `show_in_equivalent`, батч не применён

#### Scenario: Значение вне допустимого набора
- **WHEN** строка `account` несёт `system_kind` = `9`
- **THEN** ответ `400`, `error` = `invalid_row`, а не `500`
