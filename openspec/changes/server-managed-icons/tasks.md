# Tasks

## 1. Доступ

- [ ] 1.1 `src/access.cpp`: `required_scope` для `/api/admin/icons*` — `wallet:write` при любом методе; юнит-тест в `tests/test_access.cpp` (`POST`/`GET` → `wallet:write`, `wallet:read`-токен → `403` «нужен scope wallet:write») — зелёный `ctest`

## 2. Репозиторий

- [ ] 2.1 `src/reference_icons_repo.{hpp,cpp}`: `create` (проверка blob, `next_seq` потока справочников, `INSERT icon` с `ledger_id = NULL`, `updated_by = NULL`), `update` (только общая живая строка, `name`/`icon_type`), `remove` (подсчёт живых ссылок `account`/`currency` → `in_use`, иначе `deleted_at = now()` + новый `seq`); дубль имени — по `unique_violation` на `uq_icon_name_reference`
- [ ] 2.2 Юнит-тесты валидации входа (trim имени, 1–64 символа, `icon_type ≥ 0`, 64 hex) в `tests/` — зелёный `ctest`
- [ ] 2.3 Интеграционный `tests_integration/test_reference_icons.cpp`: создание → строка в `GET /sync/pull` раздела `reference`; хеш без blob → `400`; дубль имени → `409`; `PATCH` своей иконки леджера → `404`; `DELETE` используемой (счёт с `icon_uuid`) → `409` `in_use`; `DELETE` неиспользуемой → `204` и tombstone в pull — `tests_integration/run_local.sh` зелёный

## 3. HTTP

- [ ] 3.1 `src/reference_icons.{hpp,cpp}`: обработчики `POST /api/admin/icons`, `PATCH`/`DELETE /api/admin/icons/{uuid}` — `401` без сессии, `403 forbidden` при `role != "admin"`, коды из спеки; регистрация в `main.cpp`; интеграционный тест: токен `role=user` → `403`, токен `role=admin` без `device_id` → `201`, устройство не создано

## 4. Документация и проверка

- [ ] 4.1 `openapi.yaml`: тег `admin-icons`, `createReferenceIcon`/`updateReferenceIcon`/`deleteReferenceIcon` со схемами и кодами ответов; `/docs` открывается и показывает тег
- [ ] 4.2 `README.md`: раздел про управление общими иконками (двухшаговое создание через `/sync/blobs`, admin-only, удаление только неиспользуемой)
- [ ] 4.3 Живая проверка через гейтвей (`docker compose --env-file infra/db/.env`, wallet-api собирать отдельно): `curl` под админом — загрузить blob, создать иконку, увидеть её в `GET /api/reports/admin/icons` и в `GET /sync/pull` устройства
