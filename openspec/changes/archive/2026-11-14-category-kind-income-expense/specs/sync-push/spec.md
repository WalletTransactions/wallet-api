# Spec Delta

## MODIFIED Requirements

### Requirement: Строка без обязательного поля
Строка без `uuid` или без бизнес-колонки своей таблицы, а также с полем
неожиданного типа или значением вне допустимого набора колонки SHALL давать
`400` `{"error":"invalid_row","detail":"<что не так>"}`. Батч откатывается.
Для `account` бизнес-колонки включают `category_kind` (значения `0`, `1`, `2`,
см. `category-kind`). Исключение — колонки, которые требования явно называют
необязательными (`currency.show_in_equivalent`, `account_debt.due_date`,
`counterparty.icon_uuid`): их отсутствие не ошибка, а неверный тип —
ошибка.

#### Scenario: Старый клиент без новой колонки
- **WHEN** строка `account` не несёт `kind`
- **THEN** ответ `400`, `error` = `invalid_row`, `detail` называет поле

#### Scenario: Счёт без вида категории
- **WHEN** строка `account` не несёт `category_kind`
- **THEN** ответ `400`, `error` = `invalid_row`, `detail` называет `category_kind`, батч не применён

#### Scenario: Вид категории вне набора
- **WHEN** строка `account` несёт `category_kind` = `3`
- **THEN** ответ `400`, `error` = `invalid_row`, а не `500`

#### Scenario: Значение вне допустимого набора
- **WHEN** строка `account` несёт `system_kind` = `9`
- **THEN** ответ `400`, `error` = `invalid_row`, а не `500`

#### Scenario: Необязательная колонка неверного типа
- **WHEN** строка `account_debt` несёт `due_date` = `"завтра"`
- **THEN** ответ `400`, `error` = `invalid_row`, `detail` называет `due_date`, батч не применён

#### Scenario: Долг без срока
- **WHEN** строка `account_debt` не несёт `due_date`
- **THEN** ответ `200`, срок не задан
