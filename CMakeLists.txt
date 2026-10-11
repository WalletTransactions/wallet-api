cmake_minimum_required(VERSION 3.16)
project(wallet_api CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Общий код сервисов (util/: jwt, jwks, crypto, log, metrics, ...) — копия
# репозитория wallet-common, обновляется его scripts/vendor.sh; руками не править.
set(WALLET_COMMON_DIR ${CMAKE_SOURCE_DIR}/third_party/wallet-common)

# OpenSSL — только для RSA-SHA256-verify (проверка подписи access-токена по
# публичному ключу с JWKS auth-сервиса, см. src/util/crypto.cpp — никакого
# приватного ключа/секрета тут нет, ровно как в wallet-gateway). PostgreSQL —
# СВОЯ база (см. README, "Своя БД"), отдельная от базы auth-сервиса, пулом
# соединений (см. src/db.hpp::Pool). ZLIB — то же gzip-сжатие ответов, что и
# у wallet-report (см. её CMakeLists.txt, тот же комментарий целиком: cpp-httplib
# сжимает сам, автоматически, только нужен этот макрос при сборке — иначе
# соответствующий код в httplib.h не компилируется вовсе).
find_package(OpenSSL REQUIRED)
find_package(Threads REQUIRED)
find_package(PostgreSQL REQUIRED)
find_package(ZLIB REQUIRED)

# Версия приложения — проставляется на билде, не хардкодится в исходниках
# (см. GET /version, src/docs.cpp, и build_info в GET /metrics, src/util/
# metrics.cpp). Единственный источник самого номера — файл VERSION рядом с
# этим CMakeLists.txt (semver, правится руками при релизе); он же копируется
# в Containerfile (COPY VERSION ./), поэтому одинаково читается что при
# нативной сборке (cmake -B build), что при сборке образа.
#
# Git-хэш — ДОПОЛНИТЕЛЬНО к VERSION, не вместо: отличает два билда с одним и
# тем же номером версии между релизами. У сборки ВНУТРИ контейнера своего
# .git нет (Containerfile копирует только исходники, не весь репозиторий) —
# поэтому сначала смотрим на кэш-переменную GIT_COMMIT: её передаёт
# Containerfile (-DGIT_COMMIT=${GIT_COMMIT}, а туда — ARG GIT_COMMIT,
# который в свою очередь снаружи передаёт `podman build --build-arg
# GIT_COMMIT=$(git rev-parse --short HEAD)`, см. compose.yaml). Нативная
# сборка на рабочей машине эту переменную не задаёт — тогда спрашиваем git
# напрямую, репозиторий уже на месте. Не нашли ни то, ни другое — не падаем,
# версия из VERSION всё равно есть, просто без хэша ("unknown").
file(STRINGS ${CMAKE_SOURCE_DIR}/VERSION APP_VERSION_LINES LIMIT_COUNT 1)
list(GET APP_VERSION_LINES 0 APP_VERSION)
string(STRIP "${APP_VERSION}" APP_VERSION)

if(NOT DEFINED GIT_COMMIT OR "${GIT_COMMIT}" STREQUAL "")
    find_program(GIT_EXECUTABLE git)
    set(GIT_COMMIT "unknown")
    if(GIT_EXECUTABLE)
        execute_process(
            COMMAND ${GIT_EXECUTABLE} describe --tags --always --dirty --abbrev=8
            WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
            OUTPUT_VARIABLE GIT_COMMIT
            OUTPUT_STRIP_TRAILING_WHITESPACE
            RESULT_VARIABLE GIT_DESCRIBE_RESULT
            ERROR_QUIET
        )
        if(NOT GIT_DESCRIBE_RESULT EQUAL 0 OR "${GIT_COMMIT}" STREQUAL "")
            set(GIT_COMMIT "unknown")
        endif()
    endif()
endif()
message(STATUS "wallet_api version: ${APP_VERSION} (${GIT_COMMIT})")

configure_file(
    ${CMAKE_SOURCE_DIR}/src/version.hpp.in
    ${CMAKE_BINARY_DIR}/generated/version.hpp
    @ONLY
)

add_executable(wallet_api
    src/main.cpp
    src/session.cpp
    src/access.cpp
    src/db.cpp
    src/provisioning.cpp
    src/sync_repo.cpp
    src/sync.cpp
    src/blob.cpp
    src/invites_repo.cpp
    src/invites.cpp
    src/currency_pairs_repo.cpp
    src/currency_pairs.cpp
    src/account_deletion_repo.cpp
    src/account_deletion.cpp
    src/docs.cpp
    ${WALLET_COMMON_DIR}/util/base64.cpp
    ${WALLET_COMMON_DIR}/util/crypto.cpp
    ${WALLET_COMMON_DIR}/util/hex.cpp
    ${WALLET_COMMON_DIR}/util/jwt.cpp
    ${WALLET_COMMON_DIR}/util/jwt_claims.cpp
    ${WALLET_COMMON_DIR}/util/jwks.cpp
    ${WALLET_COMMON_DIR}/util/uuid.cpp
    ${WALLET_COMMON_DIR}/util/dotenv.cpp
    ${WALLET_COMMON_DIR}/util/log.cpp
    ${WALLET_COMMON_DIR}/util/metrics.cpp
)

target_include_directories(wallet_api PRIVATE
    ${CMAKE_SOURCE_DIR}/src
    ${CMAKE_SOURCE_DIR}/third_party
    ${WALLET_COMMON_DIR}
    ${CMAKE_BINARY_DIR}/generated
)

target_compile_definitions(wallet_api PRIVATE
    CPPHTTPLIB_ZLIB_SUPPORT
    $<$<CXX_COMPILER_ID:MSVC>:_CRT_SECURE_NO_WARNINGS>
)
target_compile_options(wallet_api PRIVATE
    $<$<CXX_COMPILER_ID:MSVC>:/utf-8>
)

target_link_libraries(wallet_api PRIVATE
    OpenSSL::Crypto
    Threads::Threads
    PostgreSQL::PostgreSQL
    ZLIB::ZLIB
)

if(WIN32)
    target_link_libraries(wallet_api PRIVATE ws2_32 crypt32)

    add_custom_command(TARGET wallet_api POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_directory
                ${CMAKE_SOURCE_DIR}/scripts/windows
                $<TARGET_FILE_DIR:wallet_api>
        COMMENT "Копирую scripts/windows/*.bat рядом с wallet_api.exe"
    )

    # openapi.yaml + вендоренный Swagger UI — рядом с .exe (та же рабочая
    # директория, что у .env, см. run-console.bat), сервис читает их с диска
    # по относительному пути (src/docs.cpp) при каждом GET /openapi.yaml,
    # /docs — без пересборки, только копия свежая после следующей сборки.
    add_custom_command(TARGET wallet_api POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
                ${CMAKE_SOURCE_DIR}/openapi.yaml
                $<TARGET_FILE_DIR:wallet_api>/openapi.yaml
        COMMENT "Копирую openapi.yaml рядом с wallet_api.exe (GET /openapi.yaml, /docs)"
    )
    add_custom_command(TARGET wallet_api POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_directory
                ${CMAKE_SOURCE_DIR}/third_party/swagger-ui
                $<TARGET_FILE_DIR:wallet_api>/vendor/swagger-ui
        COMMENT "Копирую вендоренный Swagger UI рядом с wallet_api.exe (GET /docs)"
    )

    # libpq — динамическая библиотека (libpq.dll). Без её копии рядом с .exe
    # (и её собственных зависимостей — SSL/i18n) сервис не запустится:
    # "libpq.dll: cannot open shared object file". Список завязан на layout
    # официального установщика PostgreSQL для Windows; если файла нет —
    # просто пропускаем (EXISTS-проверка), не падаем. Тот же приём, что в
    # CMakeLists.txt google-auth.
    get_filename_component(POSTGRESQL_ROOT_DIR "${PostgreSQL_INCLUDE_DIR}" DIRECTORY)
    set(POSTGRESQL_BIN_DIR "${POSTGRESQL_ROOT_DIR}/bin")
    foreach(_pg_dll libpq.dll libssl-3-x64.dll libcrypto-3-x64.dll libintl-9.dll libiconv-2.dll libwinpthread-1.dll)
        if(EXISTS "${POSTGRESQL_BIN_DIR}/${_pg_dll}")
            add_custom_command(TARGET wallet_api POST_BUILD
                COMMAND ${CMAKE_COMMAND} -E copy_if_different
                        "${POSTGRESQL_BIN_DIR}/${_pg_dll}"
                        $<TARGET_FILE_DIR:wallet_api>
                COMMENT "Копирую ${_pg_dll} рядом с wallet_api.exe"
            )
        endif()
    endforeach()
else()
    add_custom_command(TARGET wallet_api POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_directory
                ${CMAKE_SOURCE_DIR}/scripts/linux
                $<TARGET_FILE_DIR:wallet_api>
        COMMENT "Копирую scripts/linux/*.sh рядом с wallet_api"
    )
    add_custom_command(TARGET wallet_api POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
                ${CMAKE_SOURCE_DIR}/openapi.yaml
                $<TARGET_FILE_DIR:wallet_api>/openapi.yaml
        COMMENT "Копирую openapi.yaml рядом с wallet_api (GET /openapi.yaml, /docs)"
    )
    add_custom_command(TARGET wallet_api POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_directory
                ${CMAKE_SOURCE_DIR}/third_party/swagger-ui
                $<TARGET_FILE_DIR:wallet_api>/vendor/swagger-ui
        COMMENT "Копирую вендоренный Swagger UI рядом с wallet_api (GET /docs)"
    )
endif()

# Юнит-тесты (wallet_api_tests) — см. tests/README.md, что именно
# покрыто/не покрыто и почему. Тот же приём, что в google-auth/CMakeLists.txt:
# отдельный исполняемый файл, никаких новых внешних зависимостей.
option(WALLET_API_BUILD_TESTS "Собирать юнит-тесты wallet_api_tests" ON)
if(WALLET_API_BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()

# Интеграционные тесты (wallet_api_integration_tests) — OFF по умолчанию, в
# отличие от WALLET_API_BUILD_TESTS выше: нужен живой Postgres со схемой
# wallet-api (DATABASE_URL), не то, что можно требовать при каждой обычной
# сборке. См. tests_integration/README.md.
option(WALLET_API_BUILD_INTEGRATION_TESTS
       "Собирать интеграционные тесты wallet_api_integration_tests (нужен живой Postgres)" OFF)
if(WALLET_API_BUILD_INTEGRATION_TESTS)
    add_subdirectory(tests_integration)
endif()
