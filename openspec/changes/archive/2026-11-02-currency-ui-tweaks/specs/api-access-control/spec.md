# Spec Delta

## MODIFIED Requirements

### Requirement: Scope по пути и методу
Сервис SHALL требовать scope по пути: `DELETE /api/account` — `account`;
`POST /sync/push` — `wallet:write` или `expense:write`; `GET /sync/pull` —
`wallet:read`; `/sync/blobs*`, `/api/ledger/*`, `/api/invites/*`,
`/api/currency-pairs*`, `/api/currencies*` — `wallet:read` для GET/HEAD и
`wallet:write` для прочих методов; `/api/admin/icons*` — `wallet:write` для всех методов.
Scope сравнивается целым словом.

#### Scenario: Нет нужного scope
- **WHEN** токен со scope `wallet:read` отправляет `POST /api/ledger/invites`
- **THEN** ответ `403`, `WWW-Authenticate: Bearer error="insufficient_scope", …`, `error` = «нужен scope wallet:write»

#### Scenario: Токен бота на push
- **WHEN** токен со scope `expense:write` без `wallet:write` отправляет `POST /sync/push`
- **THEN** проверка scope пройдена, дальше действуют ограничения режима «только новые операции» (`sync-push`)

#### Scenario: Похожий scope
- **WHEN** scope токена = `wallet:readonly`
- **THEN** для `GET /sync/pull` scope `wallet:read` считается отсутствующим

#### Scenario: Админская ручка иконок без wallet:write
- **WHEN** токен администратора со scope `wallet:read` отправляет `POST /api/admin/icons`
- **THEN** ответ `403` с `error` = «нужен scope wallet:write», проверка роли не выполняется

#### Scenario: Правка валюты без записи
- **WHEN** токен со scope `wallet:read` отправляет `PATCH /api/currencies/{uuid}`
- **THEN** ответ `403`, `error` = «нужен scope wallet:write»
