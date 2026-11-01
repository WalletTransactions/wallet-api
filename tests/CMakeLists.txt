# Тесты собираются отдельным исполняемым файлом (wallet_api_tests), а не
# через `#ifdef TESTING` внутри wallet_api.exe — так рантайм-бинарь службы не
# тащит тестовый код и его символ main() ни в каком виде. Тот же приём, что в
# google-auth/tests/CMakeLists.txt.
#
# Тестовому бинарю нужны те же .cpp, что и основному коду, который он реально
# тестирует: session.cpp тянет за собой util/jwt.cpp (а тот — base64/crypto),
# и отдельно util/jwks.cpp (FakeJwksServer в test_session.cpp конструирует
# jwks::Cache напрямую). sync_repo.cpp сюда включён ради test_sync_repo.cpp,
# хотя сам он в тестах не вызывает ничего, что трогает db::Database (см.
# tests/README.md, что именно поэтому не проверено). db.cpp/repo.cpp/
# provisioning.cpp/wallet.cpp/sync.cpp/main.cpp сюда НЕ включены — не нужны
# для того, что реально тестируется, а main.cpp принёс бы второй main().
#
# db.cpp (и PostgreSQL::PostgreSQL ниже) слинкованы, хотя ни один тест не
# трогает db::Database, — sync_repo.cpp ссылается на db::Database::exec/
# Transaction::exec в push_batch()/pull_*_stream(), и это единая единица
# трансляции с push_tables()/pull_tables() (которые и тестируются): без
# db.cpp компоновщик не соберёт даже неиспользуемые тестами символы.
add_executable(wallet_api_tests
    test_main.cpp
    test_session.cpp
    test_sync_repo.cpp
    test_access.cpp
    test_sync.cpp
    test_currencies.cpp

    ${CMAKE_SOURCE_DIR}/src/currencies_repo.cpp
    ${CMAKE_SOURCE_DIR}/src/session.cpp
    ${CMAKE_SOURCE_DIR}/src/sync.cpp
    ${CMAKE_SOURCE_DIR}/src/provisioning.cpp
    ${WALLET_COMMON_DIR}/util/uuid.cpp
    ${CMAKE_SOURCE_DIR}/src/access.cpp
    ${WALLET_COMMON_DIR}/util/jwt_claims.cpp
    ${WALLET_COMMON_DIR}/util/metrics.cpp
    ${CMAKE_SOURCE_DIR}/src/sync_repo.cpp
    ${CMAKE_SOURCE_DIR}/src/db.cpp
    ${WALLET_COMMON_DIR}/util/base64.cpp
    ${WALLET_COMMON_DIR}/util/crypto.cpp
    ${WALLET_COMMON_DIR}/util/jwt.cpp
    ${WALLET_COMMON_DIR}/util/jwks.cpp
    ${WALLET_COMMON_DIR}/util/log.cpp
)

target_include_directories(wallet_api_tests PRIVATE
    ${CMAKE_SOURCE_DIR}/src
    ${CMAKE_SOURCE_DIR}/third_party
    ${WALLET_COMMON_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}
)

target_compile_definitions(wallet_api_tests PRIVATE
    $<$<CXX_COMPILER_ID:MSVC>:_CRT_SECURE_NO_WARNINGS>
)
target_compile_options(wallet_api_tests PRIVATE
    $<$<CXX_COMPILER_ID:MSVC>:/utf-8>
)

target_link_libraries(wallet_api_tests PRIVATE
    OpenSSL::Crypto
    Threads::Threads
    PostgreSQL::PostgreSQL
)

if(WIN32)
    target_link_libraries(wallet_api_tests PRIVATE ws2_32 crypt32)
endif()

add_test(NAME wallet_api_unit_tests COMMAND wallet_api_tests)
