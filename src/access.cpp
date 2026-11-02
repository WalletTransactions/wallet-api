#include "access.hpp"

#include "nlohmann/json.hpp"
#include "session.hpp"
#include "util/jwt_claims.hpp"
#include "util/log.hpp"
#include "util/metrics.hpp"

namespace authz {

namespace {

bool starts_with(const std::string& s, const char* prefix) { return s.rfind(prefix, 0) == 0; }

void count(jwt_claims::Result r) {
    metrics::inc_counter("jwt_claims_total", "Проверки iss/aud/scope access-токена по результату.", "result",
                         jwt_claims::to_string(r));
}

void reject(httplib::Response& res, int status, const std::string& error, const std::string& description) {
    res.status = status;
    // RFC 6750, 3: invalid_token — 401, insufficient_scope — 403.
    res.set_header("WWW-Authenticate", "Bearer error=\"" + error + "\", error_description=\"" + description + "\"");
    res.set_content(nlohmann::json{{"error", description}}.dump(), "application/json");
}

} // namespace

std::string required_scope(const std::string& method, const std::string& path) {
    bool read = method == "GET" || method == "HEAD";

    if (path == "/api/account") return "account";                     // DELETE — удаление аккаунта
    if (path == "/sync/push") return "wallet:write";                  // или expense:write, см. alternative_scope
    if (path == "/sync/pull") return "wallet:read";
    if (starts_with(path, "/sync/blobs")) return read ? "wallet:read" : "wallet:write";
    // Общий набор иконок (change server-managed-icons): запись при любом
    // методе, роль admin проверяет уже хендлер (reference_icons.cpp).
    if (path == "/api/admin/icons" || starts_with(path, "/api/admin/icons/")) return "wallet:write";
    if (starts_with(path, "/api/ledger/") || starts_with(path, "/api/invites/") ||
        starts_with(path, "/api/currency-pairs") ||
        // Не покрывается префиксом выше: строки расходятся после «currenc».
        path == "/api/currencies" || starts_with(path, "/api/currencies/")) {
        return read ? "wallet:read" : "wallet:write";
    }
    return {};
}

std::string alternative_scope(const std::string& method, const std::string& path) {
    if (method == "POST" && path == "/sync/push") return "expense:write";
    return {};
}

httplib::Server::HandlerResponse gate(const httplib::Request& req, httplib::Response& res, jwks::Cache& jwks_cache) {
    std::string scope = required_scope(req.method, req.path);
    if (scope.empty()) return httplib::Server::HandlerResponse::Unhandled;

    auto payload = session::verified_payload(req, jwks_cache);
    if (!payload) return httplib::Server::HandlerResponse::Unhandled; // 401 ответит хендлер

    jwt_claims::Result r = jwt_claims::check(*payload, kAudience, scope);
    if (r == jwt_claims::Result::InsufficientScope) {
        std::string alt = alternative_scope(req.method, req.path);
        if (!alt.empty() && jwt_claims::has_scope(*payload, alt)) r = jwt_claims::Result::Ok;
    }
    count(r);
    switch (r) {
    case jwt_claims::Result::Ok:
        return httplib::Server::HandlerResponse::Unhandled;
    case jwt_claims::Result::Legacy:
        // Токен без aud (выпущен до шага 1 TODO_telegram_tokens.md) — шаг 3:
        // больше не пропускаем.
        applog::warn("access token rejected", {{"event", "jwt_rejected"}, {"reason", "legacy"}});
        reject(res, 401, "invalid_token", "токен старого формата — войдите заново");
        return httplib::Server::HandlerResponse::Handled;
    case jwt_claims::Result::WrongIssuer:
    case jwt_claims::Result::WrongAudience:
        applog::warn("access token rejected", {{"event", "jwt_rejected"}, {"reason", jwt_claims::to_string(r)}});
        reject(res, 401, "invalid_token", "токен выпущен не для wallet-api");
        return httplib::Server::HandlerResponse::Handled;
    case jwt_claims::Result::InsufficientScope:
        applog::warn("access token rejected",
                     {{"event", "jwt_rejected"}, {"reason", "insufficient_scope"}, {"required_scope", scope}});
        reject(res, 403, "insufficient_scope", "нужен scope " + scope);
        return httplib::Server::HandlerResponse::Handled;
    }
    return httplib::Server::HandlerResponse::Unhandled;
}

} // namespace authz
