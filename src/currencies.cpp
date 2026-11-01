#include "currencies.hpp"

#include "currencies_repo.hpp"
#include "db.hpp"
#include "invites_repo.hpp"
#include "nlohmann/json.hpp"
#include "provisioning.hpp"
#include "session.hpp"
#include "util/log.hpp"

using nlohmann::json;

namespace currencies_api {

namespace {

constexpr const char* kJsonContentType = "application/json";

void json_error(httplib::Response& res, int status, const json& body) {
    res.status = status;
    res.set_content(body.dump(), kJsonContentType);
}

std::string path_param(const httplib::Request& req, const char* name) {
    auto it = req.path_params.find(name);
    return it != req.path_params.end() ? it->second : std::string();
}

std::optional<session::User> require_auth(const httplib::Request& req, httplib::Response& res, AppState& state) {
    auto user = session::current_user(req, *state.jwks);
    if (!user) {
        json_error(res, 401, {{"error", "unauthenticated"}});
        return std::nullopt;
    }
    return user;
}

// PATCH/DELETE: леджер пользователя без провизионирования — нет леджера, нет
// и своих валют (тот же 404, что require_ledger в currency_pairs.cpp).
std::optional<std::string> require_ledger(AppState& state, const httplib::Request& req, httplib::Response& res) {
    auto user = require_auth(req, res, state);
    if (!user) return std::nullopt;
    auto membership = invites_repo::find_membership(*state.db_pool->acquire(), user->user_id);
    if (!membership) {
        json_error(res, 404, {{"error", "валюта не найдена среди своих"}});
        return std::nullopt;
    }
    return membership->ledger_id;
}

// nullopt — уже ответили 400.
std::optional<json> parse_body(const httplib::Request& req, httplib::Response& res) {
    try {
        return json::parse(req.body);
    } catch (const std::exception&) {
        json_error(res, 400, {{"error", "некорректный JSON в теле запроса"}});
        return std::nullopt;
    }
}

bool reject_parse_error(const currencies_repo::ParseResult& parsed, httplib::Response& res) {
    if (parsed.error.empty()) return false;
    json body = {{"error", parsed.error}};
    if (!parsed.field.empty()) body["field"] = parsed.field;
    json_error(res, 400, body);
    return true;
}

// Общая карта WriteError → HTTP для POST/PATCH/DELETE (spec currencies-api).
void respond(const currencies_repo::WriteResult& result, int ok_status, httplib::Response& res) {
    using currencies_repo::WriteError;
    switch (result.error) {
        case WriteError::kOk:
            res.status = ok_status;
            if (ok_status != 204) res.set_content(result.currency.dump(), kJsonContentType);
            return;
        case WriteError::kNotFound:
            json_error(res, 404, {{"error", "валюта не найдена среди своих (общие валюты не меняются)"}});
            return;
        case WriteError::kIconNotFound:
            json_error(res, 400, {{"error", "icon_uuid: иконка не найдена"}, {"field", "icon_uuid"}});
            return;
        case WriteError::kDuplicate:
            json_error(res, 409, {{"error", "duplicate"}, {"field", result.field}});
            return;
        case WriteError::kInPair:
            json_error(res, 409, {{"error", "currency_in_pair"}});
            return;
        case WriteError::kInUse:
            json_error(res, 409, {{"error", "currency_in_use"}});
            return;
    }
}

void handle_create(AppState& state, const httplib::Request& req, httplib::Response& res) {
    applog::set_route("POST /api/currencies"); // литерал из register_routes ниже
    auto user = require_auth(req, res, state);
    if (!user) return;
    auto body = parse_body(req, res);
    if (!body) return;
    auto parsed = currencies_repo::parse_create(*body);
    if (reject_parse_error(parsed, res)) return;

    std::string ledger_id =
        provisioning::ensure_personal_ledger(*state.db_pool->acquire(), user->user_id, user->email);
    respond(currencies_repo::create_currency(*state.db_pool->acquire(), ledger_id, parsed.input), 201, res);
}

void handle_update(AppState& state, const httplib::Request& req, httplib::Response& res) {
    applog::set_route("PATCH /api/currencies/:uuid"); // литерал из register_routes ниже
    auto ledger_id = require_ledger(state, req, res);
    if (!ledger_id) return;
    std::string uuid = path_param(req, "uuid");
    if (!currencies_repo::is_uuid(uuid)) {
        respond({currencies_repo::WriteError::kNotFound, {}, {}}, 200, res);
        return;
    }
    auto body = parse_body(req, res);
    if (!body) return;
    auto parsed = currencies_repo::parse_update(*body);
    if (reject_parse_error(parsed, res)) return;

    respond(currencies_repo::update_currency(*state.db_pool->acquire(), *ledger_id, uuid, parsed.input), 200, res);
}

void handle_delete(AppState& state, const httplib::Request& req, httplib::Response& res) {
    applog::set_route("DELETE /api/currencies/:uuid"); // литерал из register_routes ниже
    auto ledger_id = require_ledger(state, req, res);
    if (!ledger_id) return;
    std::string uuid = path_param(req, "uuid");
    if (!currencies_repo::is_uuid(uuid)) {
        respond({currencies_repo::WriteError::kNotFound, {}, {}}, 204, res);
        return;
    }
    respond(currencies_repo::delete_currency(*state.db_pool->acquire(), *ledger_id, uuid), 204, res);
}

} // namespace

void register_routes(httplib::Server& svr, AppState& state) {
    svr.Post("/api/currencies", [&state](const httplib::Request& req, httplib::Response& res) {
        handle_create(state, req, res);
    });
    svr.Patch("/api/currencies/:uuid", [&state](const httplib::Request& req, httplib::Response& res) {
        handle_update(state, req, res);
    });
    svr.Delete("/api/currencies/:uuid", [&state](const httplib::Request& req, httplib::Response& res) {
        handle_delete(state, req, res);
    });
}

} // namespace currencies_api
