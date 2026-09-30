#include "session.hpp"

#include "nlohmann/json.hpp"
#include "util/jwt.hpp"
#include "util/log.hpp"

using nlohmann::json;

namespace session {

namespace {

constexpr const char* kSessionCookie = "session";

// Та же логика (и буквально тот же код), что extract_bearer в auth.cpp
// google-auth и в wallet-gateway — небольшой самостоятельный дубль в
// каждом сервисе, а не общая библиотека: жизненные циклы и деплой разные,
// тащить ради десятка строк shared-зависимость не стоит.
//
// Раньше этой функции здесь не было вообще — current_user() читал только
// cookie, хотя wallet.cpp::require_auth и README уже обещали "сначала
// Authorization: Bearer" (текст ошибки так и остался — теперь наконец
// верный). Из-за этого мобильный клиент (нет cookie jar, только заголовок,
// см. README google-auth "Мобильный вход") не смог бы пройти авторизацию
// здесь вообще ни на одном эндпоинте — заметно только сейчас, с появлением
// /sync/* (см. sync.hpp), потому что /api/wallets тестировался в основном
// через cookie/браузер.
std::string extract_bearer(const httplib::Request& req) {
    std::string header = req.get_header_value("Authorization");
    static const std::string prefix = "Bearer ";
    if (header.size() > prefix.size() && header.compare(0, prefix.size(), prefix) == 0) {
        return header.substr(prefix.size());
    }
    return {};
}

// cpp-httplib не разбирает куки за нас. Та же логика, что в auth.cpp
// google-auth — небольшой самостоятельный дубль, а не общий код: у
// сервисов разные жизненные циклы и деплой, тащить ради десятка строк
// отдельную shared-библиотеку не стоит.
std::string extract_cookie(const httplib::Request& req, const std::string& name) {
    std::string header = req.get_header_value("Cookie");
    size_t pos = 0;
    while (pos <= header.size()) {
        size_t semi = header.find(';', pos);
        std::string piece =
            header.substr(pos, semi == std::string::npos ? std::string::npos : semi - pos);

        size_t key_start = piece.find_first_not_of(' ');
        if (key_start != std::string::npos) {
            size_t eq = piece.find('=', key_start);
            if (eq != std::string::npos) {
                std::string key = piece.substr(key_start, eq - key_start);
                if (key == name) return piece.substr(eq + 1);
            }
        }

        if (semi == std::string::npos) break;
        pos = semi + 1;
    }
    return {};
}

} // namespace

std::optional<json> verified_payload(const httplib::Request& req, jwks::Cache& jwks_cache) {
    std::string token = extract_bearer(req);
    if (token.empty()) token = extract_cookie(req, kSessionCookie);
    if (token.empty()) return std::nullopt;

    auto kid = jwt::peek_kid(token);
    if (!kid) return std::nullopt;

    auto key = jwks_cache.find(*kid);
    if (!key) return std::nullopt;

    return jwt::verify_rs256(token, key->n, key->e);
}

bool has_scope(const User& user, const std::string& scope) {
    std::size_t pos = 0;
    while (pos <= user.scope.size()) {
        std::size_t end = user.scope.find(' ', pos);
        if (end == std::string::npos) end = user.scope.size();
        if (user.scope.compare(pos, end - pos, scope) == 0 && end - pos == scope.size()) return true;
        pos = end + 1;
    }
    return false;
}

std::optional<User> current_user(const httplib::Request& req, jwks::Cache& jwks_cache) {
    auto payload = verified_payload(req, jwks_cache);
    if (!payload) return std::nullopt;

    try {
        User user;
        user.user_id = payload->at("sub").get<std::string>();
        user.email = payload->value("email", std::string{});
        user.name = payload->value("name", std::string{});
        user.role = payload->value("role", std::string("user"));
        user.device_id = payload->value("device_id", std::string{});
        user.platform = payload->value("platform", std::string{});
        user.scope = payload->value("scope", std::string{});
        // Токен проверен — дальнейшие строки лога этого запроса (route,
        // db query, финальная request_finished) сами унаследуют user_id
        // (см. applog::set_user в log.hpp), без протаскивания параметром.
        applog::set_user(user.user_id);
        return user;
    } catch (const std::exception&) {
        return std::nullopt;
    }
}

} // namespace session
