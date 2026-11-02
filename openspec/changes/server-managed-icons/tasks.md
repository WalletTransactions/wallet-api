# Tasks

## 1. Доступ

- [x] 1.1 `src/access.cpp`: `required_scope` для `/api/admin/icons*` — `wallet:write` при любом методе; юнит-тест в `tests/test_access.cpp` (`POST`/`GET` → `wallet:write`, `wallet:read`-токен → `403` «нужен scope wallet:write») — зелёный `ctest`
  Проверено: `access_required_scope_table` (POST/GET/PATCH/DELETE → `wallet:write`, `/api/admin/iconsx` — без scope) и `access_gate_end_to_end` (админ с `wallet:read` → `403` «нужен scope wallet:write», с `wallet:write` — пропуск); `ctest` зелёный (debian:bookworm, `-j3`).

## 2. Репозиторий

- [x] 2.1 `src/reference_icons_repo.{hpp,cpp}`: `create` (проверка blob, `next_seq` потока справочников, `INSERT icon` с `ledger_id = NULL`, `updated_by = NULL`), `update` (только общая живая строка, `name`/`icon_type`), `remove` (подсчёт живых ссылок `account`/`currency` → `in_use`, иначе `deleted_at = now()` + новый `seq`); дубль имени — по `unique_violation` на `uq_icon_name_reference`
  Сделано: `create_icon`/`update_icon`/`delete_icon` (+ `find_icon`); строка блокируется `FOR UPDATE` — это же блокирует параллельную вставку счёта со ссылкой (FK берёт `FOR KEY SHARE`), подсчёт `in_use` не устаревает до commit. Проверено тестами 2.3.
- [x] 2.2 Юнит-тесты валидации входа (trim имени, 1–64 символа, `icon_type ≥ 0`, 64 hex) в `tests/` — зелёный `ctest`
  Проверено: `tests/test_reference_icons.cpp` — 7 тестов разбора (длина в символах UTF-8, `icon_type` 0–32767 и только целое, hex → нижний регистр, `content_sha256` в `PATCH` — 400, пустой `PATCH` — 400); `ctest` зелёный.
- [x] 2.3 Интеграционный `tests_integration/test_reference_icons.cpp`: создание → строка в `GET /sync/pull` раздела `reference`; хеш без blob → `400`; дубль имени → `409`; `PATCH` своей иконки леджера → `404`; `DELETE` используемой (счёт с `icon_uuid`) → `409` `in_use`; `DELETE` неиспользуемой → `204` и tombstone в pull — `tests_integration/run_local.sh` зелёный
  Проверено: 7 тестов репозитория (плюс: ровно один новый `seq`, удалённый счёт не считается ссылкой, имя удалённой снова свободно); `run_local.sh` на wallet-test / `wallet_api_it` — 77/77 зелёные.

## 3. HTTP

- [x] 3.1 `src/reference_icons.{hpp,cpp}`: обработчики `POST /api/admin/icons`, `PATCH`/`DELETE /api/admin/icons/{uuid}` — `401` без сессии, `403 forbidden` при `role != "admin"`, коды из спеки; регистрация в `main.cpp`; интеграционный тест: токен `role=user` → `403`, токен `role=admin` без `device_id` → `201`, устройство не создано
  Проверено: сквозной `reference_icons_http_admin_browser_session_without_device` (гейт + хендлеры + JWT с фейкового JWKS на живой базе): `user` → `403 forbidden`, админ без `wallet:write` → `403` гейта, админ без `device_id` → `201`, под его `sub` нет ни `device`, ни `ledger_member`; затем по HTTP `409`/`400`/`200`/`404`/`409 in_use`/`204`/`404`. Юнит: `user`/`support`/без claim'а → `403` на всех трёх ручках, без токена → `401`.

## 4. Документация и проверка

- [x] 4.1 `openapi.yaml`: тег `admin-icons`, `createReferenceIcon`/`updateReferenceIcon`/`deleteReferenceIcon` со схемами и кодами ответов; `/docs` открывается и показывает тег
  Проверено: YAML разбирается, все `$ref` на месте; собранный `wallet_api` на `wallet_api_it` отдаёт `/docs` `200`, в `/openapi.yaml` — тег и три operationId. Отрисовку Swagger UI в браузере не смотрел.
- [x] 4.2 `README.md`: раздел про управление общими иконками (двухшаговое создание через `/sync/blobs`, admin-only, удаление только неиспользуемой)
  Сделано: раздел «Общие иконки (`/api/admin/icons*`, только администратор)» и строка в «Что реализовано»; таблицы покрытия в `tests/README.md` и `tests_integration/README.md`.
- [ ] 4.3 Живая проверка через гейтвей (`docker compose --env-file infra/db/.env`, wallet-api собирать отдельно): `curl` под админом — загрузить blob, создать иконку, увидеть её в `GET /api/reports/admin/icons` и в `GET /sync/pull` устройства
  Не сделано: нужен выкат образа в контур с гейтвеем (wallet-test или wallet-prod), а в этом заходе контуры трогать нельзя. Остаётся после мержа и выката.
