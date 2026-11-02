#include "reference_icons.hpp"

#include "nlohmann/json.hpp"
#include "reference_icons_repo.hpp"
#include "session.hpp"
#include "util/log.hpp"
#include "util/uuid.hpp"

using nlohmann::json;

namespace reference_icons_api {

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

// false — уже ответили: 401 без сессии, 403 при role != "admin" (claim'а нет
// — session::current_user подставит "user", то есть тоже 403).
bool require_admin(AppState& state, const httplib::Request& req, httplib::Response& res) {
    auto user = session::current_user(req, *state.jwks);
    if (!user) {
        json_error(res, 401, {{"error", "unauthenticated"}});
        return false;
    }
    if (user->role != "admin") {
        applog::warn("reference icons: not an admin", {{"event", "admin_icons_forbidden"}, {"role", user->role}});
        json_error(res, 403, {{"error", "forbidden"}});
        return false;
    }
    return true;
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

bool reject_parse_error(const reference_icons_repo::ParseResult& parsed, httplib::Response& res) {
    if (parsed.error.empty()) return false;
    json body = {{"error", parsed.error}};
    if (!parsed.field.empty()) body["field"] = parsed.field;
    json_error(res, 400, body);
    return true;
}

// Карта WriteError → HTTP для всех трёх ручек (spec reference-icons-admin).
void respond(const reference_icons_repo::WriteResult& result, int ok_status, httplib::Response& res) {
    using reference_icons_repo::WriteError;
    switch (result.error) {
        case WriteError::kOk:
            res.status = ok_status;
            if (ok_status != 204) res.set_content(result.icon.dump(), kJsonContentType);
            return;
        case WriteError::kNotFound:
            json_error(res, 404, {{"error", "общая иконка не найдена"}});
            return;
        case WriteError::kBlobMissing:
            json_error(res, 400,
                       {{"error", "содержимое не загружено — сначала POST /sync/blobs"}, {"field", "content_sha256"}});
            return;
        case WriteError::kDuplicate:
            json_error(res, 409, {{"error", "duplicate"}, {"field", "name"}});
            return;
        case WriteError::kInUse:
            json_error(res, 409, {{"error", "in_use"}, {"in_use", result.in_use}});
            return;
    }
}

void handle_create(AppState& state, const httplib::Request& req, httplib::Response& res) {
    applog::set_route("POST /api/admin/icons"); // литерал из register_routes ниже
    if (!require_admin(state, req, res)) return;
    auto body = parse_body(req, res);
    if (!body) return;
    auto parsed = reference_icons_repo::parse_create(*body);
    if (reject_parse_error(parsed, res)) return;

    auto result = reference_icons_repo::create_icon(*state.db_pool->acquire(), parsed.input);
    if (result.error == reference_icons_repo::WriteError::kOk) {
        applog::info("reference icon created", {{"event", "reference_icon_created"},
                                                {"icon_uuid", result.icon.at("uuid").get<std::string>()}});
    }
    respond(result, 201, res);
}

void handle_update(AppState& state, const httplib::Request& req, httplib::Response& res) {
    applog::set_route("PATCH /api/admin/icons/:uuid"); // литерал из register_routes ниже
    if (!require_admin(state, req, res)) return;
    std::string uuid = path_param(req, "uuid");
    // Не uuid — тот же 404, иначе Postgres ответил бы 22P02, то есть 500.
    if (!uuidgen::looks_valid(uuid)) {
        respond({reference_icons_repo::WriteError::kNotFound, {}, 0}, 200, res);
        return;
    }
    auto body = parse_body(req, res);
    if (!body) return;
    auto parsed = reference_icons_repo::parse_update(*body);
    if (reject_parse_error(parsed, res)) return;

    respond(reference_icons_repo::update_icon(*state.db_pool->acquire(), uuid, parsed.input), 200, res);
}

void handle_delete(AppState& state, const httplib::Request& req, httplib::Response& res) {
    applog::set_route("DELETE /api/admin/icons/:uuid"); // литерал из register_routes ниже
    if (!require_admin(state, req, res)) return;
    std::string uuid = path_param(req, "uuid");
    if (!uuidgen::looks_valid(uuid)) {
        respond({reference_icons_repo::WriteError::kNotFound, {}, 0}, 204, res);
        return;
    }
    auto result = reference_icons_repo::delete_icon(*state.db_pool->acquire(), uuid);
    if (result.error == reference_icons_repo::WriteError::kOk) {
        applog::info("reference icon deleted", {{"event", "reference_icon_deleted"}, {"icon_uuid", uuid}});
    }
    respond(result, 204, res);
}

} // namespace

void register_routes(httplib::Server& svr, AppState& state) {
    svr.Post("/api/admin/icons", [&state](const httplib::Request& req, httplib::Response& res) {
        handle_create(state, req, res);
    });
    svr.Patch("/api/admin/icons/:uuid", [&state](const httplib::Request& req, httplib::Response& res) {
        handle_update(state, req, res);
    });
    svr.Delete("/api/admin/icons/:uuid", [&state](const httplib::Request& req, httplib::Response& res) {
        handle_delete(state, req, res);
    });
}

} // namespace reference_icons_api
