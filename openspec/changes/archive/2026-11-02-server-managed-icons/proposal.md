# Proposal

## Why

Сейчас общий набор иконок (`icon.ledger_id IS NULL`) на сервере пополнить
нечем: строки заводились в обход API, а единственный путь записи — `POST
/sync/push` с телефона, который заодно заливает на сервер каждую свою иконку
(байты в `POST /sync/blobs`). Этот трафик дорогой и ненадёжный (инцидент
2026-10-11: обрыв на одной из 144 иконок через Tailscale-relay) и при этом
не нужен вебу. Решение: иконки ведёт администратор на вебе, телефон их только
скачивает и свои иконки на сервер больше не отправляет (парные change
`android-wallet: server-managed-icons` и `wallet-web: server-managed-icons`).
Для этого wallet-api нужна ручка записи общего набора.

## What Changes

- Новые admin-only ручки управления общими иконками в wallet-api:
  - `POST /api/admin/icons` — создать общую иконку из уже загруженного через
    `POST /sync/blobs` содержимого (`name`, `icon_type`, `content_sha256`);
  - `PATCH /api/admin/icons/{uuid}` — переименовать / сменить `icon_type`;
  - `DELETE /api/admin/icons/{uuid}` — мягко удалить, если на иконку не
    ссылается ни одна живая строка (`account`, `currency`).
- Каждое изменение — одна транзакция с новым `seq` потока справочников
  (`reference`), поэтому оно приезжает на все телефоны обычным `GET /sync/pull`.
- Проверка роли `admin` из JWT (claim `role`) — впервые в wallet-api; не-админ
  получает `403`.
- Scope для `/api/admin/icons*`: `wallet:write` (для всех методов).
- `POST /sync/push` по-прежнему принимает строки `icon` — старые версии
  приложения продолжают работать; новые просто перестают их слать.
  Требования синка не меняются.

## Capabilities

### New Capabilities
- `reference-icons-admin`: управление администратором общим набором иконок
  (создание, переименование, удаление) с доставкой изменений в поток
  справочников.

### Modified Capabilities
- `api-access-control`: в требовании «Scope по пути и методу» добавляется
  `/api/admin/icons*` — `wallet:write`.

## Impact

- Код: новые `src/reference_icons.{hpp,cpp}` (HTTP) и
  `src/reference_icons_repo.{hpp,cpp}` (SQL), регистрация в `main.cpp`,
  правило scope в `access.cpp`.
- Схема: без миграции — используются существующие `icon`, `blob`,
  `next_seq()` и поток `00000000-0000-0000-0000-000000000001`.
- API: `openapi.yaml` (новый тег `admin-icons`), `README.md`.
- wallet-gateway: правок нет — `/api/admin/*` уходит на wallet-api общим
  правилом `/api/*` (не путать с `/admin/*` → google-auth).
- wallet-report: правок нет — `GET /api/reports/admin/icons` уже показывает
  общий набор.
- Клиенты: android-wallet перестаёт пушить `icon` (свой change); wallet-telegram
  не затронут.
