# Spec Delta

## ADDED Requirements

### Requirement: Флаг эквивалента у валюты
Строка `currency` в push SHALL принимать необязательное булево
`show_in_equivalent`. Если ключ присутствует, значение сохраняется. Если
ключа нет, новая валюта получает `true`, а у существующей своей валюты
прежнее значение не меняется.

#### Scenario: Пользователь снял флаг
- **WHEN** push несёт свою `currency` с `show_in_equivalent: false`
- **THEN** у валюты сохранено `false`, строка уходит в поток леджера с новым `seq`

#### Scenario: Старый клиент без ключа, новая валюта
- **WHEN** push несёт новую `currency` без ключа `show_in_equivalent`
- **THEN** ответ `200`, у валюты `show_in_equivalent = true`

#### Scenario: Старый клиент без ключа, существующая валюта
- **WHEN** у своей валюты `show_in_equivalent = false`, и push несёт её правку без ключа `show_in_equivalent`
- **THEN** ответ `200`, остальные колонки обновлены, `show_in_equivalent` остаётся `false`

#### Scenario: Флаг у общей валюты
- **WHEN** push несёт `currency` с `uuid` общей валюты и `show_in_equivalent: false`
- **THEN** общая валюта не изменена (действует «Общие и чужие строки не перезаписываются»), ответ `200`

## MODIFIED Requirements

### Requirement: Строка без обязательного поля
Строка без `uuid` или без бизнес-колонки своей таблицы, а также с полем
неожиданного типа SHALL давать `400`
`{"error":"invalid_row","detail":"<что не так>"}`. Батч откатывается.
Исключение — колонки, которые требования явно называют необязательными
(`currency.show_in_equivalent`): их отсутствие не ошибка, а неверный тип —
ошибка.

#### Scenario: Старый клиент без новой колонки
- **WHEN** строка `account` не несёт `kind`
- **THEN** ответ `400`, `error` = `invalid_row`, `detail` называет поле

#### Scenario: Необязательная колонка неверного типа
- **WHEN** строка `currency` несёт `show_in_equivalent` = `"yes"`
- **THEN** ответ `400`, `error` = `invalid_row`, `detail` называет `show_in_equivalent`, батч не применён
