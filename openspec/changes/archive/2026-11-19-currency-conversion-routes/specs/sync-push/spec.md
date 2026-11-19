# Spec Delta

## ADDED Requirements

### Requirement: Шаг маршрута пересчёта
Строка `currency_conversion` — шаг маршрута `from → to` — SHALL нести
`from_currency_uuid`, `to_currency_uuid` (различные), целый `num` от 1 до 3,
`currency_pair_uuid` и булев `is_reverse` и всегда принадлежит леджеру
вызывающего. `num` вне 1…3 или совпадающие `from`/`to` SHALL давать `400`
`invalid_row`; ссылка на отсутствующую валюту или пару — `409`
`missing_reference`.

#### Scenario: Номер шага вне диапазона
- **WHEN** строка `currency_conversion` несёт `num` = 0 или 4
- **THEN** ответ `400`, `error` = `invalid_row`, `detail` называет `num`, батч не применён

#### Scenario: Совпадающие валюты
- **WHEN** `from_currency_uuid` равна `to_currency_uuid`
- **THEN** ответ `400`, `error` = `invalid_row`

#### Scenario: Пара не на сервере
- **WHEN** шаг ссылается на `currency_pair_uuid`, которого нет
- **THEN** ответ `409`, `error` = `missing_reference` с `table` = `currency_pair`; после досылки пары батч проходит

#### Scenario: Пара и шаг одним батчем
- **WHEN** батч несёт новую `currency_pair` и шаг маршрута, использующий её
- **THEN** батч применяется без ошибки внешнего ключа

### Requirement: Уникальность шага и свобода порядка батчей
Второй живой шаг с теми же `from`, `to`, `num` (в любом порядке `from`/`to`)
SHALL давать `409` `duplicate_key`. Целостность цепочки (непрерывность `num`,
стыки, концы) SHALL не проверяться: шаги могут приходить разными батчами,
недостроенная цепочка просто не даёт курса.

#### Scenario: Обратный маршрут
- **WHEN** у леджера есть живой шаг 1 маршрута `BTC → RUB`, и батч создаёт шаг 1 маршрута `RUB → BTC`
- **THEN** ответ `409`, `error` = `duplicate_key`, батч не применён

#### Scenario: Шаги разными батчами
- **WHEN** первый батч несёт шаг 1 маршрута, второй — шаг 2
- **THEN** оба батча применяются; после второго цепочка даёт курс
