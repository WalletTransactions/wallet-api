// Проверка уже выданного access-токена. В отличие от auth.cpp в
// google-auth, здесь нет ни логина, ни выпуска токенов — весь этот флоу
// целиком на auth-сервисе; этот файл только читает cookie "session",
// которую тот выставил, и проверяет её подпись публичным ключом
// auth-сервиса (см. util/jwks.hpp) — без общего секрета в конфиге. Тот же
// приём (и буквально тот же код), что в wallet-gateway; раньше — и в
// wallet-bff, до того как SPA его упразднила (см. README wallet-web,
// "Куда делся wallet-bff").
#pragma once

#include <optional>
#include <string>

#include "httplib.h"
#include "nlohmann/json.hpp"
#include "util/jwks.hpp"

namespace session {

struct User {
    std::string user_id;
    std::string email;
    std::string name;
    // "user"/"support"/"admin" — как есть в claim'е JWT, см.
    // auth::issue_access_token в google-auth.
    std::string role;
    // Пусто у токена браузерного входа (там устройства нет вообще) — см.
    // DeviceInfo и claim "device_id"/"platform" в auth::issue_access_token,
    // google-auth. Заполнено только у токена, выпущенного через
    // POST /auth/google/mobile — то есть ровно тогда, когда имеет смысл
    // звать /sync/* (см. sync.hpp).
    std::string device_id;
    std::string platform;
    // Claim "scope" как есть, через пробел (TODO_telegram_tokens.md,
    // «Скоупы»). Токены без aud/scope (Legacy, см. util/jwt_claims.hpp)
    // отклоняет гейт в access.cpp, до хендлеров они не доходят.
    std::string scope;
};

// Есть ли scope целым словом в строке User::scope.
bool has_scope(const User& user, const std::string& scope);

// nullopt — токена нет вовсе (ни Bearer, ни cookie), kid неизвестен (даже
// после повторного похода за JWKS), токен просрочен или подпись не
// совпала. Вызывающий код не различает эти случаи — во всех отвечает 401.
std::optional<User> current_user(const httplib::Request& req, jwks::Cache& jwks_cache);

// Payload токена запроса после проверки подписи и exp — без разбора в User.
// Нужен проверке iss/aud/scope до хендлеров (см. access.hpp). nullopt — те
// же случаи, что у current_user.
std::optional<nlohmann::json> verified_payload(const httplib::Request& req, jwks::Cache& jwks_cache);

} // namespace session
