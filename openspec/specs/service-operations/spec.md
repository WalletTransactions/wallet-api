# service-operations Specification

## Purpose
Эксплуатационная сторона wallet-api: служебные HTTP-ручки, конфигурация,
логи, метрики, трассировка, поведение при непойманных ошибках и
развёртывание в контуре.

## Requirements

### Requirement: Проверка живости
`GET /healthz` SHALL отвечать `200` `{"status":"ok"}`, пока процесс
обслуживает HTTP, и не проверять Postgres и google-auth, чтобы сбой
зависимости не перезапускал сервис.

#### Scenario: База недоступна
- **WHEN** Postgres недоступен, процесс жив
- **THEN** `GET /healthz` отвечает `200`

### Requirement: Версия билда
`GET /version` SHALL отвечать `{"service":"wallet-api","version":…,"build":…,"git_commit":…,"started_at":…}`:
версия из файла `VERSION`; `build` — тег образа из `APP_BUILD`, без него
`<VERSION>-dev`; короткий хеш коммита на момент сборки или `unknown`;
`started_at` — время запуска процесса, ISO-8601 UTC. `service`, `version`,
`build` и `git_commit` есть в `build_info` метрик и в строке лога при старте.
`/metrics` дополнительно отдаёт `process_start_time_seconds`.

#### Scenario: Сборка без git
- **WHEN** образ собран без `GIT_COMMIT`, и git недоступен
- **THEN** `git_commit` = `unknown`

#### Scenario: Сборка без тега
- **WHEN** образ собран без `APP_BUILD`
- **THEN** `build` = `<VERSION>-dev`

#### Scenario: Время запуска
- **WHEN** `/version` вызван дважды без перезапуска, а затем после перезапуска контейнера
- **THEN** первые два `started_at` равны, третий — время нового запуска

### Requirement: Метрики
`GET /metrics` SHALL отдавать метрики в текстовом формате Prometheus:
`build_info`, `http_requests_total{method,route,status}`,
`http_request_duration_seconds{method,route}` и `jwt_claims_total`.
Маршрут — шаблон, а не путь. Без маршрута — `(unset)`.

#### Scenario: Запрос с параметром пути
- **WHEN** обработан `DELETE /api/ledger/invites/123`
- **THEN** метрика учитывает его с маршрутом `DELETE /api/ledger/invites/:id`, а не с конкретным id

### Requirement: Документация API
`GET /openapi.yaml` SHALL отдавать файл спецификации из рабочего каталога как
`application/yaml`, `GET /docs` — Swagger UI поверх него из вендоренного
бандла `/vendor/swagger-ui/*`, без CDN. Нет файла — `500` с текстом о
сборке.

#### Scenario: Открыть документацию
- **WHEN** пользователь открывает `/docs` в браузере без интернета
- **THEN** Swagger UI загружается целиком с самого сервиса

### Requirement: Обязательная конфигурация
Сервис SHALL требовать `AUTH_SERVICE_URL` и `DATABASE_URL`. Без них —
ошибка в лог и выход с кодом 1. Необязательные: `HOST` (`127.0.0.1`), `PORT`
(`8082`), `DATABASE_POOL_SIZE` (`8`, < 1 — выход с кодом 1), `LOG_DIR`,
`LOG_LEVEL` (по умолчанию `debug`), `LOG_SQL_PARAMS`, `LOG_SQL_MASK_PARAMS`.
Переменные читаются и из `.env`.

#### Scenario: Нет DATABASE_URL
- **WHEN** сервис запущен без `DATABASE_URL`
- **THEN** в логе ошибка с подсказкой, процесс завершается с кодом 1

#### Scenario: Пул нулевого размера
- **WHEN** `DATABASE_POOL_SIZE=0`
- **THEN** процесс завершается с кодом 1

### Requirement: Старт при недоступном google-auth
Недоступность google-auth при старте SHALL не быть фатальной: ошибка
загрузки JWKS пишется в лог, а ключи подгружаются при первом запросе с
токеном.

#### Scenario: google-auth поднимается позже
- **WHEN** wallet-api стартует раньше google-auth
- **THEN** сервис слушает порт; запросы с токенами начинают проходить, когда google-auth доступен

### Requirement: Структурные логи
Сервис SHALL писать JSON-строки (`ts` в UTC, `level`, `service`,
`trace_id`, `msg`) в stdout или в дневные файлы `LOG_DIR`. Каждый запрос —
строка `event` = `request_finished` с `duration_ms` и `user_id`. Тела —
отдельной debug-строкой, до 1024 байт. Каждый SQL — debug-строка
`db_query` с `duration_ms` и `rows`, сбой SQL — error.

#### Scenario: Большое тело запроса
- **WHEN** загружается blob размером 500 КиБ
- **THEN** debug-строка содержит первые 1024 байта тела и пометку об обрезке с полным размером

### Requirement: Тише для проб
Запросы `/healthz` и `/metrics` SHALL учитываться в метриках, но не писать
строк `request_finished` и тел.

#### Scenario: Скрейп Prometheus
- **WHEN** Prometheus опрашивает `/metrics` каждые 15 с
- **THEN** в логе нет строк про эти запросы

### Requirement: Параметры SQL в логах
Значения параметров SQL SHALL попадать в лог только при
`LOG_SQL_PARAMS=true` (или `1`). Именованный параметр со встроенным
чувствительным именем (`password`, `token`, `secret`, …) или с именем из
`LOG_SQL_MASK_PARAMS` маскируется `***`.

#### Scenario: Отладка без параметров
- **WHEN** `LOG_SQL_PARAMS` не задан
- **THEN** строки SQL в логе содержат текст запроса без значений параметров

### Requirement: Сквозной trace_id
Сервис SHALL брать `trace_id` из заголовка `X-Trace-Id`, возвращать тот же
заголовок в ответе и ставить его во все строки лога запроса. Сам новый
`trace_id` не порождает.

#### Scenario: Запрос мимо гейтвея
- **WHEN** запрос пришёл без `X-Trace-Id`
- **THEN** в ответе нет `X-Trace-Id`, в логах запроса нет `trace_id`

### Requirement: Непойманная ошибка
Исключение, не обработанное хендлером, SHALL давать `500`
`{"error":"internal server error"}` и строку error «unhandled exception:
<метод> <путь> -> <текст>». Соединение не обрывается.

#### Scenario: Сбой базы посреди запроса
- **WHEN** запрос к Postgres падает с неожиданной ошибкой
- **THEN** клиент получает `500` с JSON-телом, в логе строка с путём и причиной

### Requirement: Соединения с базой
Сервис SHALL держать пул из `DATABASE_POOL_SIZE` соединений. Запрос ждёт
свободное соединение без таймаута. Разорванное соединение переоткрывается
при следующем использовании, а не ломает свой слот навсегда.

#### Scenario: Соединение оборвалось
- **WHEN** одно соединение пула разорвано сетью
- **THEN** следующий запрос на этом слоте переподключается и выполняется

### Requirement: Развёртывание
В контуре SHALL работать один контейнер с лимитом памяти 128 МБ, `HOST` =
`0.0.0.0`, `PORT` = `8082`, healthcheck `curl -f /healthz` каждые 10 с.
Старт — после healthy google-auth и базы. Внешний трафик идёт через
wallet-gateway (`/api/*`, `/sync/*`).

#### Scenario: Зависимость не готова
- **WHEN** база ещё не прошла healthcheck
- **THEN** контейнер wallet-api не запускается до её готовности
