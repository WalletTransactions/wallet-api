#include "currency_pairs.hpp"

#include <regex>

#include "currency_pairs_repo.hpp"
#include "db.hpp"
#include "invites_repo.hpp"
#include "nlohmann/json.hpp"
#include "provisioning.hpp"
#include "session.hpp"
#include "util/log.hpp"

using nlohmann::json;

namespace currency_pairs_api {

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

// Общий пролог всех ручек, КРОМЕ создания пары (см. currency_pairs.hpp) —
// тот же приём, что require_membership в invites.cpp: аутентификация +
// резолв ЕДИНСТВЕННОГО леджера пользователя, БЕЗ провизионирования (см.
// invites_repo::find_membership). 404 — не отдельная диагностика "леджера
// нет", а тот же ответ, что получил бы запрос к чужому/несуществующему
// ресурсу — леджера нет, значит и своих пар/курсов нет тоже.
std::optional<std::string> require_ledger(AppState& state, const httplib::Request& req,
                                           httplib::Response& res) {
    auto user = require_auth(req, res, state);
    if (!user) return std::nullopt;

    auto membership = invites_repo::find_membership(*state.db_pool->acquire(), user->user_id);
    if (!membership) {
        json_error(res, 404, "у вас ещё нет леджера — курсов и пар ещё нет");
        return std::nullopt;
    }
    return membership->ledger_id;
}

// "YYYY-MM-DD", ровно 10 символов — тот же формат, что и в протоколе синка
// (wallet-api/schema/table/currency_pair_rate.sql, "date" без времени). Не
// полагаемся на то, что Postgres сам отвергнет мусор: невалидный текст в
// date-параметре кидает голый db::QueryError с sqlstate вроде "22007", не
// стоящий отдельного перевода — дешевле отсечь явно и понятно здесь.
const std::regex kDateRe(R"(^\d{4}-\d{2}-\d{2}$)");
bool is_valid_date(const std::string& s) { return std::regex_match(s, kDateRe); }

// precision — тот же диапазон, что CHECK ("precision" BETWEEN 0 AND 10) в
// wallet-api/schema/table/currency_pair.sql — проверяем ДО похода в БД ради
// понятного 400 вместо 500 на нарушенном CHECK.
bool is_valid_precision(int p) { return p >= 0 && p <= 10; }

// Курс > 0 (CHECK rate > 0, currency_pair_rate.sql) — тот же довод, что и у
// precision выше. Разбор без потери точности не нужен: значение всё равно
// уходит в БД строкой (см. currency_pairs_repo.hpp, "Деньги — numeric"),
// здесь только оценка знака через std::stod, погрешность double тут не
// портит ничего постоянного.
bool is_valid_rate_string(const std::string& s) {
    try {
        return std::stod(s) > 0;
    } catch (const std::exception&) {
        return false;
    }
}

void handle_list_pairs(AppState& state, const httplib::Request& req, httplib::Response& res) {
    applog::set_route("GET /api/currency-pairs"); // литерал из register_routes ниже
    auto user = require_auth(req, res, state);
    if (!user) return;

    // В отличие от require_ledger выше — список деградирует до пустого, а
    // не 404: экран "Курсы валют" открывается и без единого своего курса
    // (то же решение, что list_currencies/find_ledger_for_user в
    // reports_repo — read-путь не должен пугать 404 того, кто просто ещё
    // ничего не заводил).
    auto membership = invites_repo::find_membership(*state.db_pool->acquire(), user->user_id);
    json pairs = membership ? currency_pairs_repo::list_pairs(*state.db_pool->acquire(), membership->ledger_id)
                             : json::array();
    res.set_content(json{{"pairs", pairs}}.dump(), kJsonContentType);
}

void handle_create_pair(AppState& state, const httplib::Request& req, httplib::Response& res) {
    applog::set_route("POST /api/currency-pairs"); // литерал из register_routes ниже
    auto user = require_auth(req, res, state);
    if (!user) return;

    json body;
    try {
        body = json::parse(req.body);
    } catch (const std::exception&) {
        json_error(res, 400, "некорректный JSON в теле запроса");
        return;
    }
    std::string base_uuid = body.value("base_currency_uuid", std::string{});
    std::string quote_uuid = body.value("quote_currency_uuid", std::string{});
    if (base_uuid.empty() || quote_uuid.empty()) {
        json_error(res, 400, "base_currency_uuid и quote_currency_uuid обязательны");
        return;
    }
    int precision = body.value("precision", 5);
    if (!is_valid_precision(precision)) {
        json_error(res, 400, "precision должен быть от 0 до 10");
        return;
    }

    // Единственная ручка этого файла, провизионирующая леджер (см.
    // currency_pairs.hpp) — создание первой пары не должно требовать
    // предварительного похода на мобильный/принятия приглашения только
    // затем, чтобы завести личный леджер.
    std::string ledger_id = provisioning::ensure_personal_ledger(*state.db_pool->acquire(), user->user_id, user->email);

    try {
        auto result = currency_pairs_repo::create_pair(*state.db_pool->acquire(), ledger_id, base_uuid, quote_uuid,
                                                         precision);
        switch (result.error) {
            case currency_pairs_repo::CreatePairError::kSameCurrency:
                json_error(res, 400, "базовая и котируемая валюта должны различаться");
                return;
            case currency_pairs_repo::CreatePairError::kBaseNotFound:
                json_error(res, 400, "базовая валюта не найдена");
                return;
            case currency_pairs_repo::CreatePairError::kQuoteNotFound:
                json_error(res, 400, "котируемая валюта не найдена");
                return;
            case currency_pairs_repo::CreatePairError::kOk:
                res.status = 201;
                res.set_content(result.pair.dump(), kJsonContentType);
                return;
        }
    } catch (const db::QueryError& e) {
        if (e.sqlstate == "23505") {
            json_error(res, 409, "такая пара уже есть — " + std::string(e.what()));
            return;
        }
        throw;
    }
}

void handle_update_pair(AppState& state, const httplib::Request& req, httplib::Response& res) {
    applog::set_route("PATCH /api/currency-pairs/:uuid"); // литерал из register_routes ниже
    auto ledger_id = require_ledger(state, req, res);
    if (!ledger_id) return;

    json body;
    try {
        body = json::parse(req.body);
    } catch (const std::exception&) {
        json_error(res, 400, "некорректный JSON в теле запроса");
        return;
    }
    if (!body.contains("precision") || !body["precision"].is_number_integer()) {
        json_error(res, 400, "precision обязателен и должен быть целым числом");
        return;
    }
    int precision = body["precision"].get<int>();
    if (!is_valid_precision(precision)) {
        json_error(res, 400, "precision должен быть от 0 до 10");
        return;
    }

    std::string pair_uuid = path_param(req, "uuid");
    auto updated = currency_pairs_repo::update_pair_precision(*state.db_pool->acquire(), *ledger_id, pair_uuid,
                                                                precision);
    if (!updated) {
        json_error(res, 404, "пара не найдена среди своих (общие пары для веба read-only)");
        return;
    }
    res.set_content(updated->dump(), kJsonContentType);
}

void handle_delete_pair(AppState& state, const httplib::Request& req, httplib::Response& res) {
    applog::set_route("DELETE /api/currency-pairs/:uuid"); // литерал из register_routes ниже
    auto ledger_id = require_ledger(state, req, res);
    if (!ledger_id) return;

    std::string pair_uuid = path_param(req, "uuid");
    if (!currency_pairs_repo::delete_pair(*state.db_pool->acquire(), *ledger_id, pair_uuid)) {
        json_error(res, 404, "пара не найдена среди своих (общие пары для веба read-only)");
        return;
    }
    res.status = 204;
}

void handle_list_rates(AppState& state, const httplib::Request& req, httplib::Response& res) {
    applog::set_route("GET /api/currency-pairs/:uuid/rates"); // литерал из register_routes ниже
    auto ledger_id = require_ledger(state, req, res);
    if (!ledger_id) return;

    std::string pair_uuid = path_param(req, "uuid");
    std::string from = req.has_param("from") ? req.get_param_value("from") : std::string{};
    std::string to = req.has_param("to") ? req.get_param_value("to") : std::string{};
    if ((!from.empty() && !is_valid_date(from)) || (!to.empty() && !is_valid_date(to))) {
        json_error(res, 400, "from/to должны быть в формате YYYY-MM-DD");
        return;
    }

    auto rates = currency_pairs_repo::list_rates(*state.db_pool->acquire(), *ledger_id, pair_uuid, from, to);
    if (!rates) {
        json_error(res, 404, "пара не найдена");
        return;
    }
    res.set_content(json{{"rates", *rates}}.dump(), kJsonContentType);
}

void handle_upsert_rate(AppState& state, const httplib::Request& req, httplib::Response& res) {
    applog::set_route("POST /api/currency-pairs/:uuid/rates"); // литерал из register_routes ниже
    auto ledger_id = require_ledger(state, req, res);
    if (!ledger_id) return;

    json body;
    try {
        body = json::parse(req.body);
    } catch (const std::exception&) {
        json_error(res, 400, "некорректный JSON в теле запроса");
        return;
    }
    std::string date = body.value("date", std::string{});
    if (!is_valid_date(date)) {
        json_error(res, 400, "date обязателен и должен быть в формате YYYY-MM-DD");
        return;
    }
    // rate — строкой (см. currency_pairs_repo.hpp, "Деньги — numeric"), но
    // тело запроса может законно прислать и JSON-число (человек набирает
    // курс в форме, не копирует протокольную строку) — берём как есть в
    // обоих случаях, dump() числа даёт то же текстовое представление, что
    // потом уйдёт параметром в БД.
    std::string rate;
    if (body.contains("rate") && body["rate"].is_string()) rate = body["rate"].get<std::string>();
    else if (body.contains("rate") && body["rate"].is_number()) rate = body["rate"].dump();
    if (rate.empty() || !is_valid_rate_string(rate)) {
        json_error(res, 400, "rate обязателен и должен быть положительным числом");
        return;
    }

    std::string pair_uuid = path_param(req, "uuid");
    auto result = currency_pairs_repo::upsert_rate(*state.db_pool->acquire(), *ledger_id, pair_uuid, date, rate);
    if (result.error == currency_pairs_repo::RateWriteError::kPairNotFound) {
        json_error(res, 404, "пара не найдена");
        return;
    }
    res.set_content(result.rate.dump(), kJsonContentType);
}

void handle_delete_rate(AppState& state, const httplib::Request& req, httplib::Response& res) {
    applog::set_route("DELETE /api/currency-pairs/:uuid/rates/:date"); // литерал из register_routes ниже
    auto ledger_id = require_ledger(state, req, res);
    if (!ledger_id) return;

    std::string pair_uuid = path_param(req, "uuid");
    std::string date = path_param(req, "date");
    if (!is_valid_date(date)) {
        json_error(res, 400, "дата в пути должна быть в формате YYYY-MM-DD");
        return;
    }

    if (!currency_pairs_repo::delete_rate(*state.db_pool->acquire(), *ledger_id, pair_uuid, date)) {
        json_error(res, 404,
                   "своего курса на эту дату нет (общий курс этим путём не удаляется)");
        return;
    }
    res.status = 204;
}

} // namespace

void register_routes(httplib::Server& svr, AppState& state) {
    svr.Get("/api/currency-pairs", [&state](const httplib::Request& req, httplib::Response& res) {
        handle_list_pairs(state, req, res);
    });
    svr.Post("/api/currency-pairs", [&state](const httplib::Request& req, httplib::Response& res) {
        handle_create_pair(state, req, res);
    });
    svr.Patch("/api/currency-pairs/:uuid",
              [&state](const httplib::Request& req, httplib::Response& res) {
                  handle_update_pair(state, req, res);
              });
    svr.Delete("/api/currency-pairs/:uuid",
               [&state](const httplib::Request& req, httplib::Response& res) {
                   handle_delete_pair(state, req, res);
               });
    svr.Get("/api/currency-pairs/:uuid/rates",
            [&state](const httplib::Request& req, httplib::Response& res) {
                handle_list_rates(state, req, res);
            });
    svr.Post("/api/currency-pairs/:uuid/rates",
             [&state](const httplib::Request& req, httplib::Response& res) {
                 handle_upsert_rate(state, req, res);
             });
    svr.Delete("/api/currency-pairs/:uuid/rates/:date",
               [&state](const httplib::Request& req, httplib::Response& res) {
                   handle_delete_rate(state, req, res);
               });
}

} // namespace currency_pairs_api
