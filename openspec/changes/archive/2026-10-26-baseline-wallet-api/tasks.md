# Tasks

Изменение не меняет код: задачи — только сверка спецификаций с кодом и
тестами. Несоответствие исправляется в спецификации, если неточна она, или
записывается в «Наблюдения» `design.md`, если расходится документ или код
ведёт себя неожиданно. Код, `openapi.yaml` и README в рамках этого изменения
не правятся, новые тесты не пишутся: пробелы покрытия фиксируются для
отдельного change.

## 1. Исходное состояние

- [x] 1.1 Убедиться, что сверка идёт на коммите из `design.md` (`8d31ffc`), или записать в Context новый коммит и что изменилось в `src/`, `migrations/`, `third_party/wallet-common/`; проверка — `git log -1` совпадает с записанным
- [x] 1.2 Собрать и прогнать юнит-тесты (`cmake -B build -DWALLET_API_BUILD_TESTS=ON && cmake --build build && ctest --test-dir build --output-on-failure`, сборка одним сервисом, без параллельных сборок соседей); проверка — все тесты зелёные, число тестов записано в «Покрытие» `design.md`
- [x] 1.3 Прогнать интеграционные тесты против базы с миграциями (`ENGINE=docker bash tests_integration/run_local.sh`, нужен поднятый `db` dev-стека); проверка — результат записан в «Покрытие», а если прогон невозможен, причина записана там же

## 2. Сверка по capability

Для каждой спецификации: каждый сценарий сопоставить с тестом
(`tests/*.cpp`, `tests_integration/*.cpp`) или местом в коде. Сценарии без
теста перечислить в разделе «Покрытие» `design.md`.

- [x] 2.1 `api-access-control` сверена с `access.cpp`, `session.cpp`, `wallet-common/util/{jwt_claims,jwks}.cpp`, `test_access.cpp`, `test_session.cpp`; проверка — у каждого сценария есть ссылка на тест или пометка «нет теста», таблица scope совпадает с `required_scope`
- [x] 2.2 `ledger-provisioning` сверена с `provisioning.cpp`, `sync.cpp::authenticate_and_provision`, `invites_repo::find_membership`, `test_sync.cpp`, `test_push_batch.cpp` (provisioning-тесты); проверка — как в 2.1, список ручек, которые провизионируют, совпадает с вызовами `ensure_*`
- [x] 2.3 `sync-push` сверена с `sync.cpp::handle_push`, `sync_repo.cpp::push_batch/upsert_row`, `test_sync_repo.cpp`, `test_push_batch.cpp`; проверка — как в 2.1, коды и тела ошибок совпадают с `openapi.yaml` (`syncPush`)
- [x] 2.4 `sync-pull` сверена с `sync.cpp::handle_pull`, `sync_repo.cpp::pull_*_stream`, `test_push_batch.cpp` (pull-тесты); проверка — как в 2.1, поля ответа совпадают с `openapi.yaml` (`syncPull`)
- [x] 2.5 `icon-blobs` сверена с `blob.cpp`, `schema/table/blob.sql`, `test_push_batch.cpp`; проверка — как в 2.1
- [x] 2.6 `ledger-sharing` сверена с `invites.cpp`, `invites_repo.cpp`, `test_invites.cpp`; проверка — как в 2.1, коды ответов совпадают с `openapi.yaml` (тег `ledger`)
- [x] 2.7 `currency-pairs-api` сверена с `currency_pairs.cpp`, `currency_pairs_repo.cpp`, `test_currency_pairs.cpp`; проверка — как в 2.1, коды ответов совпадают с `openapi.yaml` (тег `currency-pairs`)
- [x] 2.8 `account-deletion` сверена с `account_deletion*.cpp`, миграцией `000025`, `test_account_deletion.cpp`; проверка — как в 2.1
- [x] 2.9 `wallet-schema-ownership` сверена с `db.cpp::verify_schema`, `migrations/` (пары up/down, гранты `wallet_reader`), `schema/README.md`, `Containerfile`, `wallet-infra/infra/env/migrate.sh`; проверка — как в 2.1, у каждой `*.up.sql` есть `*.down.sql`
- [x] 2.10 `service-operations` сверена с `main.cpp`, `docs.cpp`, `db.cpp` (пул, переподключение, логи SQL), `wallet-common/util/{log,metrics}.cpp`, `.env.example`, блоком `wallet-api` в `wallet-infra/compose.yaml`; проверка — как в 2.1, список переменных окружения совпадает с `main.cpp` и `log.cpp`

## 3. Итоговая проверка

- [x] 3.1 Прогнать `openspec validate baseline-wallet-api --strict`; проверка — change валиден
- [x] 3.2 Перечитать «Наблюдения» `design.md` после сверки: новые расхождения добавлены, ошибочные убраны; проверка — каждое Р-наблюдение ссылается на конкретный файл

## Workflow follow-up

- Заархивировать change (`/opsx:archive`) после ревью: спецификации переедут в `openspec/specs/`.
- После архивации пересмотреть `purge-synced-tombstones`: сброс курсора (`reset_reason`) оформить как MODIFIED к `sync-pull` («Сброс курсора, ушедшего дальше головы»), подтверждение через pull — ADDED. В `Modified Capabilities` его proposal указать `sync-pull`.
- После архивации сверить `partition-operation-by-ledger` с `wallet-schema-ownership` (права `wallet_reader` на новые таблицы, миграции с down).
- Решить, какие из Р1–Р18 оформлять отдельными changes.
