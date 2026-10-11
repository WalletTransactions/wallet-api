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
# account_deletion_repo.cpp (test_account_deletion.cpp) — тот же принцип:
# HTTP-слой (account_deletion.cpp — session::current_user) сюда не нужен;
# сама она использует только db.cpp (голый DELETE/SELECT), никаких новых
# зависимостей сверх уже собираемых для invites_repo.cpp выше.
add_executable(wallet_api_integration_tests
    test_main.cpp
    test_push_batch.cpp
    test_invites.cpp
    test_currency_pairs.cpp
    test_account_deletion.cpp

    ${CMAKE_SOURCE_DIR}/src/db.cpp
    ${CMAKE_SOURCE_DIR}/src/provisioning.cpp
    ${CMAKE_SOURCE_DIR}/src/sync_repo.cpp
    ${CMAKE_SOURCE_DIR}/src/invites_repo.cpp
    ${CMAKE_SOURCE_DIR}/src/currency_pairs_repo.cpp
    ${CMAKE_SOURCE_DIR}/src/account_deletion_repo.cpp
    ${WALLET_COMMON_DIR}/util/uuid.cpp
    ${WALLET_COMMON_DIR}/util/log.cpp
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
