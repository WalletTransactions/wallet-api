# Tasks

## 1. Запрет записи читателю

- [x] 1.1 `src/ledger_write_guard.hpp`; проверка роли в `/sync/push` (непустой `changes`, любой scope) и в пишущих маршрутах валют, пар, курсов, маршрутов; проверить интеграционным `reader_of_shared_ledger_cannot_write_via_rest_or_push` (`run_local.sh` на test)
- [x] 1.2 `openapi.yaml` (`403 reader_cannot_write`, `413` у push) и `README.md`; проверить, что `GET /openapi.yaml` разбирается

## 2. Предел тела

- [x] 2.1 `svr.set_payload_max_length(8 МБ)` в `main.cpp`; проверить сборку и юнит-тесты (`ctest` 99/99)
- [ ] 2.2 На test: `curl -X POST --data-binary @9MB /sync/push` → `413`

## 3. Выкатка

- [ ] 3.1 На test: читатель из веба — правка валюты `403`, владелец — `200`
- [ ] 3.2 Change в android-wallet: read-only режим для роли `reader` (см. Impact)
- [x] 3.3 `openspec validate reader-write-guard --strict`
- [ ] 3.4 Архивировать change после проверки на test
