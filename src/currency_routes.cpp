#include "currency_routes.hpp"

#include <regex>

#include "currency_routes_repo.hpp"
#include "db.hpp"
#include "invites_repo.hpp"
#include "ledger_write_guard.hpp"
#include "nlohmann/json.hpp"
#include "provisioning.hpp"
#include "session.hpp"
#include "util/log.hpp"

using nlohmann::json;

namespace currency_routes_api {

namespace {

constexpr const char* kJsonContentType = "application/json";

void json_error(httplib::Response& res, int status, const std::string& message) {
    res.status = status;
    res.set_content(json{{"error", message}}.dump(), kJsonContentType);
}

std::string path_param(const httplib::Request& req, const char* name) {
    auto it = req.path_params.find(name);
    return it != req.path_params.end() ? it->second : std::string();
}

// Мусор вместо uuid отсекаем здесь: Postgres ответил бы 22P02 и 500.
bool is_uuid(const std::string& s) {
    static const std::regex kUuid(
        "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$");
    return std::regex_match(s, kUuid);
}

// nullopt — хендлер уже ответил 401 сам.
std::optional<session::User> require_auth(const httplib::Request& req, httplib::Response& res,
                                           AppState& state) {
    auto user = session::current_user(req, *state.jwks);
    if (!user) {
        json_error(res, 401, "unauthenticated");
        return std::nullopt;
    }
    return user;
}

void handle_list_routes(AppState& state, const httplib::Request& req, httplib::Response& res) {
    applog::set_route("GET /api/currency-routes"); // литерал из register_routes ниже
    auto user = require_auth(req, res, state);
    if (!user) return;

    // Как у списка пар: без леджера — пустой список, леджер не создаётся.
    auto membership = invites_repo::find_membership(*state.db_pool->acquire(), user->user_id);
    json routes = membership ? currency_routes_repo::list_routes(*state.db_pool->acquire(), membership->ledger_id)
                             : json::array();
    res.set_content(json{{"routes", routes}}.dump(), kJsonContentType);
}

void handle_create_route(AppState& state, const httplib::Request& req, httplib::Response& res) {
    applog::set_route("POST /api/currency-routes"); // литерал из register_routes ниже
    auto user = require_auth(req, res, state);
    if (!user) return;

    json body;
    try {
        body = json::parse(req.body);
    } catch (const std::exception&) {
        json_error(res, 400, "некорректный JSON в теле запроса");
        return;
    }
    if (!body.is_object() || !body.contains("currency_uuids") || !body["currency_uuids"].is_array()) {
        json_error(res, 400, "currency_uuids обязателен и должен быть массивом");
        return;
    }
    std::vector<std::string> path;
    for (const auto& item : body["currency_uuids"]) {
        if (!item.is_string() || !is_uuid(item.get<std::string>())) {
            json_error(res, 400, "currency_uuids должен содержать uuid валют");
            return;
        }
        path.push_back(item.get<std::string>());
    }

    // Ручка, провизионирующая леджер (как создание пары).
    std::string ledger_id = provisioning::ensure_personal_ledger(*state.db_pool->acquire(), user->user_id, user->email);

    try {
        auto result = currency_routes_repo::create_route(*state.db_pool->acquire(), ledger_id, path);
        switch (result.error) {
            case currency_routes_repo::CreateRouteError::kBadLength:
                json_error(res, 400, "путь маршрута — от 3 до 4 валют");
                return;
            case currency_routes_repo::CreateRouteError::kDuplicateCurrency:
                json_error(res, 400, "валюты в пути маршрута не должны повторяться");
                return;
            case currency_routes_repo::CreateRouteError::kCurrencyNotFound:
                json_error(res, 400, "валюта не найдена: " + result.detail);
                return;
            case currency_routes_repo::CreateRouteError::kNoPairForStep:
                json_error(res, 400, "для шага " + result.detail + " нет валютной пары");
                return;
            case currency_routes_repo::CreateRouteError::kAlreadyExists:
                json_error(res, 409, "маршрут между этими валютами уже есть");
                return;
            case currency_routes_repo::CreateRouteError::kOk:
                res.status = 201;
                res.set_content(result.route.dump(), kJsonContentType);
                return;
        }
    } catch (const db::QueryError& e) {
        // Гонка двух одинаковых POST: второй упёрся в уникальность шага.
        if (e.sqlstate == "23505") {
            json_error(res, 409, "маршрут между этими валютами уже есть");
            return;
        }
        throw;
    }
}

void handle_delete_route(AppState& state, const httplib::Request& req, httplib::Response& res) {
    applog::set_route("DELETE /api/currency-routes/:from/:to"); // литерал из register_routes ниже
    auto user = require_auth(req, res, state);
    if (!user) return;

    // 404 одинаково для «нет леджера», «нет маршрута» и «чужой маршрут».
    auto membership = invites_repo::find_membership(*state.db_pool->acquire(), user->user_id);
    std::string from = path_param(req, "from");
    std::string to = path_param(req, "to");
    if (!membership || !is_uuid(from) || !is_uuid(to) ||
        !currency_routes_repo::delete_route(*state.db_pool->acquire(), membership->ledger_id, from, to)) {
        json_error(res, 404, "маршрут не найден");
        return;
    }
    res.status = 204;
}

} // namespace

// Пишущие маршруты закрыты для читателя леджера (ledger_write_guard.hpp).
void register_routes(httplib::Server& svr, AppState& state) {
    svr.Get("/api/currency-routes", [&state](const httplib::Request& req, httplib::Response& res) {
        handle_list_routes(state, req, res);
    });
    svr.Post("/api/currency-routes", [&state](const httplib::Request& req, httplib::Response& res) {
        if (ledger_write_guard::reject_reader(state, req, res)) return;
        handle_create_route(state, req, res);
    });
    svr.Delete("/api/currency-routes/:from/:to",
               [&state](const httplib::Request& req, httplib::Response& res) {
                   if (ledger_write_guard::reject_reader(state, req, res)) return;
                   handle_delete_route(state, req, res);
               });
}

} // namespace currency_routes_api
