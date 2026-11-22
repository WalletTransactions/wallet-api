# Tasks

## 1. Конфигурация флага

- [x] 1.1 `src/app_state.hpp`: поле `bool ledger_icon_upload = false`
- [x] 1.2 `src/main.cpp`: читать `LEDGER_ICON_UPLOAD` (`on/true/1`), лог `ledger_icon_upload_config`
- [x] 1.3 `README.md`: описание переменной рядом с `SYNC_TOMBSTONE_PURGE`

## 2. Загрузка blob

- [x] 2.1 `src/blob.cpp::handle_upload`: `403 icon_upload_disabled` при выключенном флаге и роли не `admin`, после аутентификации и до проверки размера
- [x] 2.2 Юнит-тест в `tests/`: выбор решения (флаг × роль) вынесен в чистую функцию
- [x] 2.3 Интеграционный тест в `tests_integration/`: пользователь — 403 и blob не создан; админ — 200; без токена — 401; флаг включён — 200 _`tests_integration/test_icon_upload.cpp`; 2026-11-22 `run_local.sh` на кластере test — 229/229._

## 3. Push

- [x] 3.1 При выключенном флаге убрать строки `icon` из батча до применения, собрать их `uuid` _(фильтр в `src/sync.cpp::handle_push`, где есть флаг и роль; чистая функция — `src/icon_upload.hpp::take_icon_rows`)_
- [x] 3.2 Добавить `icons_rejected {error, uuids}` в ответ `200` и в `response_text` для `sync_push_batch`; без отброшенных строк поля нет
- [x] 3.3 Юнит-тест фильтра (батч с `icon` и операцией, батч без `icon`)
- [x] 3.4 Интеграционные тесты: иконка + операция → 200, операция применена, иконки нет; свой счёт со ссылкой на отброшенную иконку → 409 `missing_reference`; повтор `batch_id` → тот же ответ; флаг включён → иконка создана _`tests_integration/test_icon_upload.cpp`; 2026-11-22 `run_local.sh` на кластере test — 229/229._

## 4. Pull

- [x] 4.1 `src/sync.cpp`: блок `capabilities.icon_upload` в каждом ответе pull (в том числе при сбросе и без изменений)
- [x] 4.2 Тесты: флаг off/on, pull с курсором на голове _`tests_integration/test_icon_upload.cpp`; 2026-11-22 `run_local.sh` на кластере test — 229/229._

## 5. Документация и инфраструктура

- [x] 5.1 `openapi.yaml`: `403 icon_upload_disabled` у `uploadBlob`, `icons_rejected` в ответе push, `capabilities` в ответе pull
- [x] 5.2 wallet-infra: `LEDGER_ICON_UPLOAD` в `test.env`/`prod.env` (off), PR + rc-тег; включение на test отдельным шагом _wallet-infra#96, v0.5.2-rc.2 на test: `LEDGER_ICON_UPLOAD=on` (проверка Android 4.2 на Huawei 2026-11-22), prod — off._
- [x] 5.3 Сверить `org/docs/TODO_mobile_sync.md` и при необходимости дописать про опциональные иконки
