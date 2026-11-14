# Интеграционные тесты wallet-api

То, что принципиально нельзя проверить в `../tests/` — там `db::Database`
не подменить фейком, она коннектится к Postgres прямо в конструкторе (см.
`../tests/README.md`, "Что сознательно НЕ покрыто здесь"). Здесь — реальные
запросы к живой базе со схемой wallet-api.

Не собираются по умолчанию (в отличие от `../tests/`) и не зарегистрированы
в CTest — им нужен живой Postgres, а не любой такой, вообще: с уже
накаченными миграциями `wallet-api/migrations/`.

## Что покрыто

`test_push_batch.cpp`:

| Тест | Что проверяет |
|---|---|
| `push_batch_returns_promptly_instead_of_deadlocking` | **Главная цель** — регрессия на самозаклин 2026-09-04 (см. `org/docs/TODO_mobile_sync.md`, Фаза 2). Гоняет `push_batch()` в отдельном потоке с таймаутом 10 секунд — `nullopt` при таймауте и есть регрессия, а не "медленный Postgres" (сама операция — пара запросов в одной транзакции) |
| `push_batch_replay_with_same_batch_id_is_idempotent` | Повтор того же `batch_id` возвращает тот же текст ответа и не создаёт дубль строки |
| `push_batch_rejects_duplicate_account_name_with_existing_uuid` | Конфликт `uq_account_name` — 409 с `existing_uuid` выжившей строки, второй батч не применился частично |
| `push_then_pull_round_trips_amount_as_string_not_number` | `amount` возвращается `pull_ledger_stream()` JSON-строкой, а не числом (регрессия на `to_jsonb()`-как-голое-число, см. `TableSpec::numeric_columns`) |
| `push_then_pull_round_trips_icon_content_sha256_as_hex_not_bytea_literal` | Push `icon` (uuid+name+content_sha256+icon_type) против уже загруженного (напрямую SQL) `blob` — `content_sha256` возвращается pull'ом чистым hex, не текстовым представлением bytea Postgres (`\x...`, регрессия на `TableSpec::hex_columns`) |
| `push_rejects_icon_referencing_unknown_blob` | `icon.content_sha256`, ссылающийся на никогда не загруженный blob, — `409 missing_reference`, тем же путём, что и любой другой внешний ключ |
| `push_batch_applies_tables_in_dependency_order_not_alphabetical` | Регрессия 2026-09-05: один батч с `currency`+`account`+`account_operating` (взаимно ссылающимися) обязан пройти целиком — раньше `push_batch` применял таблицы в АЛФАВИТНОМ порядке итерации `nlohmann::json`, `account_operating` уходил раньше `currency` и падал на FK (см. `sync_repo.cpp`, `kApplyOrder`) |
| `currency_pair_rate_from_two_devices_upserts_by_natural_key_not_uuid` | Регрессия 2026-09-05 (реальная находка, лог `POST /sync/push`): два офлайн-устройства с РАЗНЫМИ `uuid` на одну и ту же (`ledger`, пара, дата) — раньше второй push падал `23505` прямо на `uq_currency_pair_rate_ledger`, не доходя до `ON CONFLICT (uuid)`; теперь конфликт резолвится по естественному ключу (`TableSpec::conflict_columns`), второй push побеждает целиком (`rate` и `uuid`) |
| `push_rejects_currency_pair_referencing_unknown_currency_with_structured_reference` | Регрессия/реальный инцидент 2026-09-13 (первый синк с телефона): `currency_pair` без своей `currency` в одном батче — `409 missing_reference` теперь несёт машиночитаемые `table`/`uuid` (REFERENCED таблица, не та, в которую шёл INSERT — см. `sync_repo.cpp`, `parse_missing_reference`), не только текст ошибки Postgres |
| `create_only_push_inserts_new_operation_and_replays_by_batch_id` | `PushMode::CreateOperationsOnly` (токен бота, `expense:write`): новая операция вставляется, повтор того же `batch_id` — сохранённый ответ, а не `403 operation_exists` |
| `create_only_push_rejects_existing_operation_and_rolls_back_batch` | uuid уже существующей операции с новым `batch_id` — `403 operation_exists`, существующая не изменилась, соседняя новая строка того же батча откачена |
| `create_only_push_rejects_other_tables_and_deletes` | `account` в батче — `403 only_operation`, `"deleted": true` — `403 delete_not_allowed` |
| `provisioning_keeps_email_when_token_has_none_and_reports_role` | Провижининг с пустым email (у токена бота его нет) не затирает `app_user.email`; `Identity.role` — `owner` |
| `browser_device_provisions_as_web_and_pushes_operation` | Браузерная сессия с `device_id` (add-ai-expense-text, google-auth выдаёт его на каждый вход): провижининг заводит устройство `platform=web` в леджере пользователя, `push` операции проходит `200`, `operation.updated_by` — это устройство |
| `push_missing_reference_self_heals_when_client_resends_referenced_row` | Тот же инцидент — второй push, довозящий именно названные `table`/`uuid` вместе с исходной `currency_pair` (то, что теперь делает Android `SyncEngine.pushDirty` при получении такого 409), обязан пройти `200` |

`test_db_reconnect.cpp` (2026-11-13, общий код `util/pg_recover` из
wallet-common) — переподключение `db::Database` после обрыва: backend
убивается из второго соединения через `pg_terminate_backend`.

| Тест | Что проверяет |
|---|---|
| `reconnect_first_query_after_backend_terminated_succeeds` | **Главная цель.** Первый запрос после рестарта БД проходит без ошибки (раньше `PQstatus` оставался `CONNECTION_OK`, а запрос падал «server closed the connection unexpectedly») |
| `reconnect_read_survives_termination_in_the_middle_of_query` | Чтение, оборванное прямо в ходе запроса, повторяется один раз на новом соединении |
| `reconnect_write_is_not_retried_when_connection_dies_mid_query` | Запись в этом случае — ошибка без автоповтора (клиент не знает, выполнил ли её сервер): строка не применена и не продублирована, следующий запрос работает |
| `reconnect_inside_transaction_reports_error_instead_of_silent_reset` | Внутри транзакции `PQreset` не вызывается (потерял бы `BEGIN`) — вызывающий получает ошибку |

Тесты `reports_repo.hpp` (`test_reports.cpp`) переехали вместе с самими
отчётами в [wallet-report](https://github.com/WalletTransactions/wallet-report) (2026-09-08, CQRS-lite) —
см. его `tests_integration/README.md`.

`test_invites.cpp` (Фаза 6, `org/docs/TODO_mobile_sync.md`, п. 9.6) — 14
тестов `invites_repo.hpp` напрямую (без HTTP-слоя `invites.cpp` — та же
логика разделения, что и у `test_push_batch.cpp`/`sync.cpp`, "не-owner
получает 403" сюда сознательно не входит, это однострочная проверка в
HTTP-слое). Самое важное: create→accept — одноразовость (повторный `accept`
тем же токеном, повторный `revoke` уже неактивного — оба `false`, не тихий
"успех"); `accept` при уже существующем леджере у принимающего —
приглашение НЕ расходуется, годится следующему; `transfer_owner` — ровно
один `owner` после (`uq_ledger_member_owner`), `reader` становится `owner`
напрямую, а при отклонённом переносе (не-`owner`-вызывающий или
несуществующий в леджере target) владелец гарантированно НЕ теряет роль.

`test_reference_icons.cpp` (change `server-managed-icons`) —
`reference_icons_repo.hpp` напрямую: создание общей иконки даёт ровно один
новый `seq` потока справочников и строку в `pull_reference_stream`
(`ledger_id`/`updated_by` пусты); хеш без `blob` — `kBlobMissing`, ничего не
создано; дубль имени общей — `kDuplicate` и при создании, и при
переименовании (своя иконка леджера с тем же именем не мешает); правка и
удаление своей иконки леджера — `kNotFound`, строка не тронута; живые
`account`/`currency` со ссылкой — `kInUse` с числом ссылок (удалённый счёт
не считается); удаление неиспользуемой — tombstone в pull, `blob` остаётся,
имя снова свободно. Плюс единственный в этом каталоге сквозной HTTP-тест
(`reference_icons_http_admin_browser_session_without_device`): настоящий
гейт `access.cpp` + хендлеры `reference_icons.cpp` + JWT с фейкового JWKS
(`../tests/test_rsa_helper.hpp`) — `role=user` — `403 forbidden`, админ без
`wallet:write` — `403` гейта, админ без `device_id` — `201`, под его `sub`
не заведено ни устройства, ни членства в леджере; затем коды `409`/`400`/
`200`/`404`/`409 in_use`/`204` по HTTP.

Долги (change `debts`, миграция 000036). В `test_push_batch.cpp`, раздел
«Долги», — синк `counterparty`/`account_debt`: новый долг одним батчем с
операцией (ключи `changes` идут алфавитно — порядок из `kApplyOrder`); долг
на категории и на несуществующего контрагента — `409 missing_reference`; два
займа одному контрагенту в одной валюте и долг на кошельке-активе — `200`;
`due_date`: без ключа — прежнее значение, `null` — снять срок, `"завтра"` —
`400 invalid_row` с именем поля; дубль имени без учёта регистра, «ё»/«е» и
пробелов — `409 duplicate_name` с `existing_uuid`; удаление контрагента с
живым долгом — `409 counterparty_in_use`, батч откачен, а «снять долг и
удалить контрагента», «удалить кошелёк и контрагента» одним батчем — `200`;
удаление кошелька гасит `account_debt` seq'ом батча и доезжает в pull;
pull отдаёт обе таблицы со всеми колонками и tombstone. В
`test_account_deletion.cpp` — леджер с контрагентами и долгами удаляется
целиком. `test_debts_reports.cpp` — отчётные функции на одном наборе
(частичный возврат, остаток до периода, прощение, перевод между долгами,
переплата в минус, валюта без курса, нулевой архивный кошелёк, снятый
признак): `f_debts_for_period`, `counterparty_uuid` в `f_balance_to_date`/
`f_balance_to_dates`/`f_balance_series` (и `NULL` в пустом бакете), `kind =
'debt'` в ленте и `f_operations_total` с `p_kind` и без.

Набор иконок по умолчанию (change `default-reference-icons`, миграция 000037).
`test_default_icons.cpp` читает файлы миграции и `manifest.json` набора из
`/src/migrations` (Containerfile копирует каталог; локально —
`WALLET_API_MIGRATIONS_DIR`) и проверяет на накачанной базе: каждое имя набора
есть среди живых общих иконок, у иконок набора тип как в манифесте, а
`content_sha256` равен `sha256` байт `blob`; набор отдаётся
`pull_reference_stream` с курсором 0 и не отдаётся за курсором на голове.
Повтор `up.sql` и `down.sql` идёт ВНУТРИ транзакции, которая откатывается, —
база остаётся как была: повторный `up` ничего не меняет и не двигает `seq`;
`up` после `down` возвращает те же `uuid` с одним новым `seq`; иконка
администратора с тем же именем в другом регистре не затирается; удалённая
тёзка не мешает; `down` убирает только набор и оставляет `blob`, общий с чужой
иконкой.

## Изоляция

Каждый `TEST` заводит СВОИ `user_id`/`device_id`/`ledger_id` (случайные uuid,
см. `fixture::make_identity`) — тесты не делят состояние. Можно гонять этот
бинарь сколько угодно раз подряд против одной и той же базы: только растёт
число строк, ничего не конфликтует и не требует очистки между запусками.
Для одноразовой/CI-базы это не важно вовсе — обычно проще пересоздать её
целиком (см. ниже).

## Как запустить

### Быстрый путь

```bash
bash run_local.sh
```

Один скрипт вместо ручных шагов ниже: заводит (если ещё нет) отдельную базу
`wallet_api_it` **в том же кластере Postgres**, что уже поднят вашим dev-
стеком (`podman compose ... up -d db`, см. `wallet-infra/README.md`) — не второй
контейнер, а просто ещё одна база рядом, накатывает миграции `wallet`
(идемпотентно), собирает тестовый образ (`Containerfile` рядом) и
прогоняет его. Повторные запуски быстрее — слои и база переиспользуются, а
тесты не требуют очистки между прогонами (см. "Изоляция" выше). Та же база
и тот же приём, что у [wallet-report](https://github.com/WalletTransactions/wallet-report)
(`tests_integration/run_local.sh`) — оба сервиса читают/пишут одну и ту же
`wallet_api_it`, заводить её дважды не нужно.

**Это НЕ изолированный тестовый контур** — тот же Postgres-инстанс (тот же
процесс, тот же контейнер `db`), что и у живого dev-стека, просто ещё одна
база внутри него. Падение/перезапуск/апгрейд `db` задевает тесты и рабочие
данные разом, а тяжёлый прогон тестов делит с dev-стеком CPU/IO того же
процесса. Отдельный, полностью независимый контур (свой контейнер/сеть, не
общая база в общем инстансе) не заведён — см.
`org/docs/TODO_mobile_sync.md`, "Открытые вопросы".

### Вручную (тот же результат другим способом)

Нужен **отдельный, одноразовый** Postgres — не тот, что использует ваш
основной `podman compose` стек (`infra/db/.env` тут вообще не участвует,
секреты реального стека не нужны). Пример через голый `podman run` —
без compose, без сохранения состояния:

```bash
# 1. Поднять одноразовый Postgres на своей сети (пароль — не секрет,
#    контейнер только для тестов и тут же удаляется)
podman network create wallet-api-it-net
podman run -d --name wallet-api-it-db --network wallet-api-it-net \
    -e POSTGRES_PASSWORD=integration-test-only \
    -e POSTGRES_DB=wallet_api_it \
    postgres:16-alpine
# подождать, пока поднимется (несколько секунд) — либо в цикле:
#   podman exec wallet-api-it-db pg_isready -U postgres

# 2. Накатить миграции wallet (той же migrate/migrate, что и в проде)
podman run --rm --network wallet-api-it-net \
    -v "$(pwd)/../../infra/db/migrations/wallet:/migrations:ro" \
    docker.io/migrate/migrate -path=/migrations \
    -database "postgres://postgres:integration-test-only@wallet-api-it-db:5432/wallet_api_it?sslmode=disable" \
    up

# 3. Собрать и прогнать тесты внутри контейнера (тот же build-образ, что и
#    для ../tests/ — debian:bookworm-slim + cmake/libssl-dev/libpq-dev)
#    в контексте wallet-api/, с CMAKE-опцией сборки этой цели:
#    cmake -B build -DWALLET_API_BUILD_INTEGRATION_TESTS=ON \
#      && cmake --build build --target wallet_api_integration_tests
#    DATABASE_URL — см. ниже, тот же хост "wallet-api-it-db" по сети
#    wallet-api-it-net.

# 4. Убрать за собой
podman rm -f wallet-api-it-db
podman network rm wallet-api-it-net
```

`DATABASE_URL` для самого бинарника — обычная строка подключения libpq,
как и у `main.cpp` сервиса:

```
postgres://postgres:integration-test-only@wallet-api-it-db:5432/wallet_api_it?sslmode=disable
```

Если тестовый бинарь собран и запускается вне контейнера (тот же хост, где
поднят Postgres) — замените `wallet-api-it-db` на `localhost` и
опубликуйте порт контейнера (`-p 15432:5432` на шаге 1, тогда `:15432`
вместо `:5432` в `DATABASE_URL`).

## Jenkins

Прогон на каждый билд автоматизирован в отдельном репозитории
**BuildPlatform** (сосед этого репозитория, не его часть — CI-инфраструктура
намеренно отделена от кода проекта) —
`BuildPlatform/jobs/wallet-api-integration-tests/Jenkinsfile`. Job — тонкая
обёртка вокруг `run_local.sh` (см. выше), ничего не переизобретает; итоговая
строка (`N тестов, упало M`) — в описание билда, полный вывод — артефакт
`test_output.log`. Тот же приём, что у
`wallet-report/tests_integration/README.md`.

Сам Jenkins и его настройка — целиком в BuildPlatform, не здесь:
`BuildPlatform/README.md` и `BuildPlatform/jenkins/README.md`.
