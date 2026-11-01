# Spec Delta

## Purpose

Проверка того, кто обращается к wallet-api: сервис сам не логинит и не выдаёт
токены, а принимает только access-токены google-auth, адресованные ему, с
правом на конкретное действие.

## ADDED Requirements

### Requirement: Источник токена
Сервис SHALL брать access-токен из заголовка `Authorization: Bearer <токен>`,
а при его отсутствии — из cookie `session`. Если есть оба, используется
Bearer. Заголовок `Authorization` другой схемы игнорируется, и тогда
используется cookie.

#### Scenario: Мобильный клиент без cookie
- **WHEN** запрос несёт только `Authorization: Bearer` с действительным токеном
- **THEN** запрос аутентифицирован пользователем из claim'а `sub`

#### Scenario: Bearer и cookie одновременно
- **WHEN** запрос несёт и Bearer, и cookie `session` с токенами разных пользователей
- **THEN** запрос аутентифицирован пользователем из Bearer-токена

### Requirement: Проверка подписи по JWKS
Сервис SHALL принимать только токены RS256 с верной подписью ключом из
`{AUTH_SERVICE_URL}/.well-known/jwks.json` по `kid` и с неистёкшим `exp`.
Ключи кешируются в памяти. При неизвестном `kid` JWKS запрашивается
повторно. Общих секретов с google-auth нет.

#### Scenario: Неизвестный kid
- **WHEN** токен подписан ключом, `kid` которого нет в JWKS даже после повторного запроса
- **THEN** запрос не аутентифицирован

#### Scenario: Просроченный токен
- **WHEN** у токена с верной подписью истёк `exp`
- **THEN** запрос не аутентифицирован

### Requirement: Ответ без аутентификации
Эндпоинт API, получивший запрос без токена или с токеном, не прошедшим
проверку подписи и срока, SHALL отвечать `401` с телом
`{"error":"unauthenticated"}`. Причина (нет токена, битая подпись, истёк)
в ответе не различается.

#### Scenario: Запрос без токена
- **WHEN** `GET /api/ledger/members` приходит без Bearer и без cookie
- **THEN** ответ `401`, `error` = `unauthenticated`

### Requirement: Адресат и издатель токена
Для путей API с требуемым scope сервис SHALL до хендлера проверить у токена
с верной подписью: `aud` есть и содержит `wallet-api` (строкой или в
массиве), а `iss` = `google-auth`. Иначе ответ `401` с заголовком
`WWW-Authenticate: Bearer error="invalid_token", …`.

#### Scenario: Токен старого формата
- **WHEN** токен с верной подписью не несёт `aud`
- **THEN** ответ `401`, `error` = «токен старого формата — войдите заново»

#### Scenario: Токен для другого сервиса
- **WHEN** `aud` токена = `wallet-report`
- **THEN** ответ `401`, `error` = «токен выпущен не для wallet-api»

### Requirement: Scope по пути и методу
Сервис SHALL требовать scope по пути: `DELETE /api/account` — `account`;
`POST /sync/push` — `wallet:write` или `expense:write`; `GET /sync/pull` —
`wallet:read`; `/sync/blobs*`, `/api/ledger/*`, `/api/invites/*`,
`/api/currency-pairs*` — `wallet:read` для GET/HEAD и `wallet:write` для
прочих методов. Scope сравнивается целым словом.

#### Scenario: Нет нужного scope
- **WHEN** токен со scope `wallet:read` отправляет `POST /api/ledger/invites`
- **THEN** ответ `403`, `WWW-Authenticate: Bearer error="insufficient_scope", …`, `error` = «нужен scope wallet:write»

#### Scenario: Токен бота на push
- **WHEN** токен со scope `expense:write` без `wallet:write` отправляет `POST /sync/push`
- **THEN** проверка scope пройдена, дальше действуют ограничения режима «только новые операции» (`sync-push`)

#### Scenario: Похожий scope
- **WHEN** scope токена = `wallet:readonly`
- **THEN** для `GET /sync/pull` scope `wallet:read` считается отсутствующим

### Requirement: Служебные пути без токена
`/healthz`, `/version`, `/metrics`, `/openapi.yaml`, `/docs` и
`/vendor/swagger-ui/*` SHALL отвечать без аутентификации и без проверки
scope.

#### Scenario: Проверка живости
- **WHEN** `GET /healthz` приходит без токена
- **THEN** ответ `200`

### Requirement: Учёт проверок токена
Каждую проверку `iss`/`aud`/`scope` сервис SHALL учитывать в метрике
`jwt_claims_total{result}` (`ok`, `legacy`, `wrong_issuer`,
`wrong_audience`, `insufficient_scope`), а каждый отказ записывать в лог
уровня warn с `event` = `jwt_rejected` и причиной.

#### Scenario: Отказ по scope в метрике
- **WHEN** запрос отклонён из-за недостающего scope
- **THEN** `jwt_claims_total{result="insufficient_scope"}` увеличивается на 1, в логе `reason` = `insufficient_scope` и `required_scope`
