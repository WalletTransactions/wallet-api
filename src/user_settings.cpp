#include "user_settings.hpp"

#include "db.hpp"
#include "invites_repo.hpp"
#include "nlohmann/json.hpp"
#include "session.hpp"
#include "user_settings_repo.hpp"
#include "util/log.hpp"

using nlohmann::json;

namespace user_settings_api {

namespace {

constexpr const char* kJsonContentType = "application/json";

void json_error(httplib::Response& res, int status, const json& body) {
    res.status = status;
    res.set_content(body.dump(), kJsonContentType);
}

json settings_body(const std::optional<std::string>& eq_currency) {
    return json{{"eq_currency", eq_currency ? json(*eq_currency) : json(nullptr)}};
}

void handle_get(AppState& state, const httplib::Request& req, httplib::Response& res) {
    applog::set_route("GET /api/settings"); // литерал из register_routes ниже
    auto user = session::current_user(req, *state.jwks);
    if (!user) {
        json_error(res, 401, {{"error", "unauthenticated"}});
        return;
    }
    auto eq_currency = user_settings_repo::find_eq_currency(*state.db_pool->acquire(), user->user_id);
    res.set_content(settings_body(eq_currency).dump(), kJsonContentType);
}

void handle_put(AppState& state, const httplib::Request& req, httplib::Response& res) {
    applog::set_route("PUT /api/settings"); // литерал из register_routes ниже
    auto user = session::current_user(req, *state.jwks);
    if (!user) {
        json_error(res, 401, {{"error", "unauthenticated"}});
        return;
    }
    json body;
    try {
        body = json::parse(req.body);
    } catch (const std::exception&) {
        json_error(res, 400, {{"error", "некорректный JSON в теле запроса"}});
        return;
    }
    auto parsed = user_settings_repo::parse_put(body);
    if (!parsed.error.empty()) {
        json_error(res, 400, {{"error", parsed.error}, {"field", "eq_currency"}});
        return;
    }

    // Один Lease на весь запрос (см. db.hpp, Pool): find_membership и запись
    // идут друг за другом, вложенного acquire() нет.
    auto lease = state.db_pool->acquire();
    // Без леджера — пустой ledger_id: годятся только общие валюты (design D3).
    auto membership = invites_repo::find_membership(*lease, user->user_id);
    std::string ledger_id = membership ? membership->ledger_id : std::string();
    auto result =
        user_settings_repo::save_eq_currency(*lease, user->user_id, user->email, ledger_id, parsed.eq_currency);
    if (result == user_settings_repo::WriteError::kUnknownCurrency) {
        json_error(res, 400, {{"error", "unknown_currency"}});
        return;
    }
    res.set_content(settings_body(parsed.eq_currency).dump(), kJsonContentType);
}

} // namespace

void register_routes(httplib::Server& svr, AppState& state) {
    svr.Get("/api/settings", [&state](const httplib::Request& req, httplib::Response& res) {
        handle_get(state, req, res);
    });
    svr.Put("/api/settings", [&state](const httplib::Request& req, httplib::Response& res) {
        handle_put(state, req, res);
    });
}

} // namespace user_settings_api
