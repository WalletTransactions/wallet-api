# Юнит-тесты wallet-api

Тот же самодельный харнесс, что в `google-auth/tests` (`TEST`/`CHECK`/
`CHECK_EQ`/`CHECK_THROWS`/`REQUIRE`, файлы `test_framework.hpp`/
`test_main.cpp` — копия, не общая библиотека: сервисы независимы, см.
корневой README, "Минимум внешних зависимостей").

## Сборка и запуск

```bash
cmake -B build
cmake --build build --target wallet_api_tests
./build/wallet_api_tests        # или build/Debug/... на Windows/MSVC
# либо через CTest:
ctest --test-dir build --output-on-failure
```

Если OpenSSL/PostgreSQL не установлены — исключить из сборки:
`cmake -B build -DWALLET_API_BUILD_TESTS=OFF`.

## Что покрыто

| Файл | Что проверяет |
|---|---|
| `test_session.cpp` | `session::current_user()` — Bearer/cookie (и приоритет Bearer над cookie), отказ без токена/с битым токеном/с неизвестным `kid`/с чужой подписью/с истёкшим `exp`, извлечение `device_id`/`platform` (пусто у "браузерного" токена) |
| `test_sync_repo.cpp` | `sync_repo::push_tables()`/`pull_tables()` — нет дублей имён, `pull_tables() == push_tables()` (включая `icon` — метаданные, не содержимое, теперь обычная синхронизируемая таблица), `numeric_columns`/`hex_columns` — подмножества `columns`, именно `operation.amount`/`currency_pair_rate.rate` помечены numeric и только `icon.content_sha256` — hex, правильный `Scope` у каждой таблицы; `conflict_columns` — только у `currency_pair_rate`, равен `(ledger_id, currency_pair_uuid, date)` (см. `org/docs/TODO_mobile_sync.md`, "Открытые вопросы", почему именно у неё) |
| `test_sync.cpp` | HTTP-пролог `/sync/push` и `/sync/pull` (`sync.cpp`, `authenticate_and_provision`) без базы: токен без `device_id` — `403 {"error": "device_required"}` на обоих маршрутах, без токена — `401` |

`test_session.cpp` реально ходит по HTTP — но не наружу: `jwks::Cache`
(util/jwks.cpp) не умеет принимать готовые ключи напрямую, только тянуть их
с `GET /.well-known/jwks.json`, поэтому тест поднимает такой же эндпоинт сам,
на `127.0.0.1` со случайным портом, в этом же процессе (`FakeJwksServer`,
см. сам файл). Это не интеграционный тест — никакой внешней инфраструктуры
не поднимается, это ровно тот же принцип, что petstore-стаб в моках HTTP-
клиентов: процесс говорит сам с собой через loopback.

`test_rsa_helper.hpp` генерирует RSA-ключ и умеет им подписать (RS256),
хотя у самого wallet-api такого кода в проде нет вообще (см.
`util/crypto.hpp` — этот сервис только проверяет чужую подпись) — сборка
тестового токена руками нужна только тестам.

## Явная регрессия: баг с `Authorization: Bearer` (2026-09-04)

`session_current_user_accepts_bearer_header` (и соседние тесты про Bearer)
— это не просто "нормальный случай". До 2026-09-04 `session::current_user`
читал **только** cookie `session`, хотя README и текст ошибки в
`wallet.cpp::require_auth` уже обещали "сначала `Authorization: Bearer`" —
мобильный клиент (нет cookie jar) не смог бы пройти авторизацию здесь
вообще ни на одном эндпоинте. Баг нашёлся не код-ревью и не тестами (их не
было), а первым же реальным запросом с телефона. Эти тесты — чтобы
конкретно эта регрессия больше не проскочила молча.

## Что сознательно НЕ покрыто здесь (нужен живой Postgres)

`db::Database`/`Database::Transaction` бросают исключение уже в
конструкторе/`exec()`, если подключиться не удалось — интерфейса для
подмены фейком нет, и заводить его только ради тестов означало бы вносить
абстракцию в прод-код без другой пользы (тот же принцип, что в
`google-auth/tests/README.md`). Без реальной базы честно не проверить:

- `provisioning::ensure_identity` — весь целиком, Postgres;
- `sync_repo::push_batch`/`pull_ledger_stream`/`pull_reference_stream` —
  сама SQL-логика, транзакции, идемпотентность, конфликт по имени счёта;
- **сам дедлок 2026-09-04** (см. `org/docs/TODO_mobile_sync.md`, Фаза 2,
  "Прогнано вживую... нашёлся и исправлен реальный deadlock") — по своей
  природе это баг взаимодействия `Database::Transaction` с реальным
  соединением, воспроизвести и поймать регрессию можно только на настоящем
  Postgres;
- HTTP-хендлеры `sync.cpp`/`wallet.cpp` — тонкие обвязки поверх
  перечисленного выше.

Это — `../tests_integration/`, не эта директория. См. её README.
