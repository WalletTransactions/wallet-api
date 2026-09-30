// Урезанная копия util/jwt.hpp из google-auth: этот сервис только
// ПРОВЕРЯЕТ access-токен (RS256, по публичному ключу с JWKS auth-сервиса —
// см. util/jwks.hpp) — не подписывает свои и не хранит секретов/ключей.
#pragma once

#include <optional>
#include <string>
#include <vector>

#include "nlohmann/json.hpp"

namespace jwt {

// Проверяет подпись RS256 по сырым модулю/экспоненте RSA-ключа (как их
// отдаёт JWKS) и срок действия (exp, если есть). Возвращает payload при
// успехе, иначе nullopt.
std::optional<nlohmann::json> verify_rs256(const std::string& token,
                                            const std::vector<unsigned char>& n,
                                            const std::vector<unsigned char>& e);

// Читает `kid` из заголовка БЕЗ проверки подписи — нужен, чтобы понять,
// каким из ключей JWKS проверять токен дальше (см. jwks::Cache::find).
std::optional<std::string> peek_kid(const std::string& token);

} // namespace jwt
