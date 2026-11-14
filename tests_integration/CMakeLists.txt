# Гейт (WALLET_API_BUILD_INTEGRATION_TESTS) — в родительском CMakeLists.txt,
# этот файл им уже защищён и второй раз не проверяет. Отдельный от
# ../tests/ target — нужен живой Postgres (DATABASE_URL, см. README.md
# рядом), поэтому не собирается по умолчанию (в отличие от
# WALLET_API_BUILD_TESTS, ON по умолчанию).
#
# provisioning.cpp/sync_repo.cpp/db.cpp/util/uuid.cpp/util/log.cpp — ровно
# тот код, который здесь реально вызывается (db.cpp сам зовёт applog::info/
# error на каждый запрос, поэтому util/log.cpp обязателен, даже без явного
# вызова applog::init — см. её README про поведение без init). session.cpp/
# util/jwt.cpp/jwks.cpp сюда не нужны — auth здесь не участвует,
# sync_repo::push_batch()/pull_*_stream() вызываются напрямую. sync.cpp
# (HTTP-слой поверх них) тоже не нужен здесь по той же причине — тянет
# httplib::Request/Response, тестам это не нужно, это дело sync_repo
# напрямую. reports_repo.cpp/test_reports.cpp переехали в wallet-report
# вместе с самими отчётами (2026-09-08, см. его tests_integration/).
#
# invites_repo.cpp (Фаза 6, test_invites.cpp) — тем же принципом, что и
# sync_repo.cpp выше: HTTP-слой (invites.cpp) сюда не нужен, только
# testable-логика. util/crypto.cpp/util/hex.cpp — invites_repo сама
# генерирует и хэширует токен приглашения (crypto::random_bytes/sha256,
# hex::encode), без них не собирается.
#
# currency_pairs_repo.cpp (test_currency_pairs.cpp) — тем же принципом:
# HTTP-слой (currency_pairs.cpp) сюда не нужен, только testable-логика; сама
# она использует только db.cpp/provisioning.cpp/util/uuid.cpp, уже собираемые
# для sync_repo.cpp/invites_repo.cpp выше.
#
# currencies_repo.cpp (test_currencies.cpp, change currency-ui-tweaks) — тот
# же принцип: HTTP-слой (currencies.cpp) не нужен; зависимости — db.cpp и
# util/uuid.cpp, уже собираемые выше.
#
# account_deletion_repo.cpp (test_account_deletion.cpp) — тот же принцип:
# HTTP-слой (account_deletion.cpp — session::current_user) сюда не нужен;
# сама она использует только db.cpp (голый DELETE/SELECT), никаких новых
# зависимостей сверх уже собираемых для invites_repo.cpp выше.
#
# reference_icons_repo.cpp (test_reference_icons.cpp, change
# server-managed-icons) — тот же принцип, но здесь впервые и HTTP-слой
# (reference_icons.cpp) со всем путём токена: session.cpp/access.cpp/
# util/jwt*.cpp/jwks.cpp/metrics.cpp — один сквозной тест «админ без
# device_id → 201 без провизионирования» требует настоящей базы. Ключ и JWT —
# ../tests/test_rsa_helper.hpp (Containerfile копирует только его).
#
# sync.cpp (test_tombstone_retention.cpp, change purge-synced-tombstones) —
# HTTP-слой GET /sync/pull тем же путём токена: подтверждение по ledger_id
# запроса, выключатель и падение чистки живут именно в handle_pull.
#
# test_debts_reports.cpp (change debts) — отчётные SQL-функции миграции
# 000036 голым SQL через db.cpp, новых исходников не требует.
#
# test_default_icons.cpp (change default-reference-icons) — миграция 000037:
# набор общих иконок, повтор up/down в откатываемой транзакции; читает файлы
# миграции и манифест набора из /src/migrations (Containerfile их копирует,
# каталог переопределяет WALLET_API_MIGRATIONS_DIR), новых исходников не требует.
# test_default_currencies.cpp (change default-reference-currencies) — миграция 000039:
# общий справочник валют и пар, повтор up/down в откатываемой транзакции; читает
# манифест справочника из /src/migrations, новых исходников не требует.
add_executable(wallet_api_integration_tests
    test_main.cpp
    test_push_batch.cpp
    test_invites.cpp
    test_currency_pairs.cpp
    test_account_deletion.cpp
    test_currencies.cpp
    test_reference_icons.cpp
    test_tombstone_retention.cpp
    test_debts_reports.cpp
    test_default_icons.cpp
    test_default_currencies.cpp
    test_partitioning.cpp
    test_db_reconnect.cpp

    ${CMAKE_SOURCE_DIR}/src/reference_icons_repo.cpp
    ${CMAKE_SOURCE_DIR}/src/reference_icons.cpp
    ${CMAKE_SOURCE_DIR}/src/session.cpp
    ${CMAKE_SOURCE_DIR}/src/access.cpp
    ${WALLET_COMMON_DIR}/util/jwt.cpp
    ${WALLET_COMMON_DIR}/util/jwt_claims.cpp
    ${WALLET_COMMON_DIR}/util/jwks.cpp
    ${WALLET_COMMON_DIR}/util/metrics.cpp
    ${CMAKE_SOURCE_DIR}/src/currencies_repo.cpp
    ${CMAKE_SOURCE_DIR}/src/db.cpp
    ${CMAKE_SOURCE_DIR}/src/provisioning.cpp
    ${CMAKE_SOURCE_DIR}/src/sync_repo.cpp
    ${CMAKE_SOURCE_DIR}/src/sync.cpp
    ${CMAKE_SOURCE_DIR}/src/invites_repo.cpp
    ${CMAKE_SOURCE_DIR}/src/currency_pairs_repo.cpp
    ${CMAKE_SOURCE_DIR}/src/account_deletion_repo.cpp
    ${WALLET_COMMON_DIR}/util/uuid.cpp
    ${WALLET_COMMON_DIR}/util/log.cpp
    ${WALLET_COMMON_DIR}/util/pg_recover.cpp
    ${WALLET_COMMON_DIR}/util/crypto.cpp
    # crypto.cpp (wallet-common) — RsaSigningKey::kid() кодирует base64.
    ${WALLET_COMMON_DIR}/util/base64.cpp
    ${WALLET_COMMON_DIR}/util/hex.cpp
)

target_include_directories(wallet_api_integration_tests PRIVATE
    ${CMAKE_SOURCE_DIR}/src
    ${CMAKE_SOURCE_DIR}/third_party
    ${WALLET_COMMON_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}
)

target_compile_definitions(wallet_api_integration_tests PRIVATE
    $<$<CXX_COMPILER_ID:MSVC>:_CRT_SECURE_NO_WARNINGS>
)
target_compile_options(wallet_api_integration_tests PRIVATE
    $<$<CXX_COMPILER_ID:MSVC>:/utf-8>
)

# OpenSSL::Crypto — новое (Фаза 6): invites_repo.cpp зовёт crypto::random_bytes/
# sha256 (util/crypto.cpp). Сам find_package(OpenSSL REQUIRED) — в
# родительском CMakeLists.txt, здесь только линковка импортированной цели.
target_link_libraries(wallet_api_integration_tests PRIVATE
    Threads::Threads
    PostgreSQL::PostgreSQL
    OpenSSL::Crypto
)

if(WIN32)
    target_link_libraries(wallet_api_integration_tests PRIVATE ws2_32 crypt32)
endif()

# Не add_test()/ctest — ctest не пробрасывает DATABASE_URL и не поднимает
# Postgres сам; запуск исключительно руками/скриптом, см. README.md, "Как
# запустить".
