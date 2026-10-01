#include "invites.hpp"

#include "invites_repo.hpp"
#include "nlohmann/json.hpp"
#include "session.hpp"
#include "util/log.hpp"

using nlohmann::json;

namespace invitesapi {

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

// Общий пролог владельческих ручек (список участников читают все роли,
// остальное — только owner, см. invites.hpp и org/docs/TODO_mobile_sync.md,
// п. 9.2): аутентификация + резолв РОЛИ ТЕКУЩЕГО пользователя В ЕГО
// ЕДИНСТВЕННОМ леджере. nullopt — хендлер уже ответил сам (401 — не
// аутентифицирован, 404 — у пользователя ещё нет леджера вовсе: этим
// экраном при MVP "один леджер на пользователя" нечего показывать раньше,
// чем леджер появится через /sync/* или provisioning).
struct Caller {
    session::User user;
    invites_repo::Membership membership;
};

std::optional<Caller> require_membership(AppState& state, const httplib::Request& req,
                                          httplib::Response& res) {
    auto user = require_auth(req, res, state);
    if (!user) return std::nullopt;

    auto membership = invites_repo::find_membership(*state.db_pool->acquire(), user->user_id);
    if (!membership) {
        json_error(res, 404, "у вас ещё нет леджера — приглашать/раздавать доступ нечем");
        return std::nullopt;
    }
    return Caller{std::move(*user), std::move(*membership)};
}

// require_membership выше + проверка, что это именно owner — общий пролог
// всех МУТИРУЮЩИХ ручек этого файла (создать/отозвать приглашение, сменить
// роль, удалить участника, передать владение — см. п. 9.2, "мутирующие
// действия — только owner"). Каждая ручка проверяет роль сама, а не
// полагается на то, что фронт спрятал кнопку.
std::optional<Caller> require_owner(AppState& state, const httplib::Request& req,
                                     httplib::Response& res) {
    auto caller = require_membership(state, req, res);
    if (!caller) return std::nullopt;
    if (caller->membership.role != "owner") {
        json_error(res, 403, "только владелец леджера может это сделать");
        return std::nullopt;
    }
    return caller;
}

json member_to_json(const invites_repo::MemberRow& m) {
    return json{{"user_id", m.user_id},
                {"email", m.email},
                {"role", m.role},
                {"joined_at", m.joined_at}};
}

json invite_to_json(const invites_repo::InviteSummary& i) {
    return json{{"id", i.id},
                {"role", i.role},
                {"created_at", i.created_at},
                {"expires_at", i.expires_at}};
}

bool is_assignable_role(const std::string& role) { return role == "member" || role == "reader"; }

constexpr int kAllowedTtlDays[] = {2, 7, 30};

bool is_allowed_ttl(int days) {
    for (int d : kAllowedTtlDays) {
        if (d == days) return true;
    }
    return false;
}

void handle_list_members(AppState& state, const httplib::Request& req, httplib::Response& res) {
    applog::set_route("GET /api/ledger/members"); // литерал из register_routes ниже
    auto caller = require_membership(state, req, res);
    if (!caller) return;

    auto members = invites_repo::list_members(*state.db_pool->acquire(), caller->membership.ledger_id);
    json out = json::array();
    for (const auto& m : members) out.push_back(member_to_json(m));
    res.set_content(json{{"members", out}}.dump(), kJsonContentType);
}

void handle_set_member_role(AppState& state, const httplib::Request& req,
                             httplib::Response& res) {
    applog::set_route("PATCH /api/ledger/members/:user_id"); // литерал из register_routes ниже
    auto caller = require_owner(state, req, res);
    if (!caller) return;

    json body;
    try {
        body = json::parse(req.body);
    } catch (const std::exception&) {
        json_error(res, 400, "некорректный JSON в теле запроса");
        return;
    }
    std::string role = body.value("role", std::string{});
    if (!is_assignable_role(role)) {
        json_error(res, 400, "role обязателен и должен быть 'member' или 'reader'");
        return;
    }

    std::string target = path_param(req, "user_id");
    // Владельца этим путём не тронуть (см. invites_repo::set_member_role) —
    // владелец, пытающийся сменить роль СЕБЕ, тоже получит этот же 404, не
    // отдельную диагностику: тот же приём, что not_found в wallet.cpp,
    // одним кодом на "не участник" и "нельзя трогать".
    if (!invites_repo::set_member_role(*state.db_pool->acquire(), caller->membership.ledger_id, target, role)) {
        json_error(res, 404, "участник не найден в этом леджере (или это владелец)");
        return;
    }
    res.status = 204;
}

void handle_remove_member(AppState& state, const httplib::Request& req, httplib::Response& res) {
    applog::set_route("DELETE /api/ledger/members/:user_id"); // литерал из register_routes ниже
    auto caller = require_owner(state, req, res);
    if (!caller) return;

    std::string target = path_param(req, "user_id");
    if (!invites_repo::remove_member(*state.db_pool->acquire(), caller->membership.ledger_id, target)) {
        json_error(res, 404, "участник не найден в этом леджере (или это владелец)");
        return;
    }
    res.status = 204;
}

void handle_transfer_owner(AppState& state, const httplib::Request& req, httplib::Response& res) {
    applog::set_route("POST /api/ledger/transfer-owner"); // литерал из register_routes ниже
    auto caller = require_owner(state, req, res);
    if (!caller) return;

    json body;
    try {
        body = json::parse(req.body);
    } catch (const std::exception&) {
        json_error(res, 400, "некорректный JSON в теле запроса");
        return;
    }
    std::string target = body.value("user_id", std::string{});
    if (target.empty()) {
        json_error(res, 400, "user_id обязателен");
        return;
    }

    auto status = invites_repo::transfer_owner(*state.db_pool->acquire(), caller->membership.ledger_id,
                                                caller->user.user_id, target);
    switch (status) {
        case invites_repo::TransferStatus::kOk:
            res.status = 204;
            return;
        case invites_repo::TransferStatus::kCallerNotOwner:
            // Гонка: между require_owner выше и этим вызовом кто-то другой
            // уже успел стать owner'ом (например, параллельный
            // transfer-owner). Диагностика честная, не 404/500.
            json_error(res, 403, "вы больше не владелец этого леджера");
            return;
        case invites_repo::TransferStatus::kTargetNotMember:
            json_error(res, 404, "указанный пользователь не участник этого леджера");
            return;
    }
}

void handle_create_invite(AppState& state, const httplib::Request& req, httplib::Response& res) {
    applog::set_route("POST /api/ledger/invites"); // литерал из register_routes ниже
    auto caller = require_owner(state, req, res);
    if (!caller) return;

    json body;
    try {
        body = json::parse(req.body);
    } catch (const std::exception&) {
        json_error(res, 400, "некорректный JSON в теле запроса");
        return;
    }
    std::string role = body.value("role", std::string{});
    if (!is_assignable_role(role)) {
        json_error(res, 400, "role обязателен и должен быть 'member' или 'reader' (не 'owner')");
        return;
    }
    if (!body.contains("ttl_days") || !body["ttl_days"].is_number_integer()) {
        json_error(res, 400, "ttl_days обязателен и должен быть целым числом");
        return;
    }
    int ttl_days = body["ttl_days"].get<int>();
    if (!is_allowed_ttl(ttl_days)) {
        json_error(res, 400, "ttl_days должен быть 2, 7 или 30");
        return;
    }

    auto invite = invites_repo::create_invite(*state.db_pool->acquire(), caller->membership.ledger_id,
                                               caller->user.user_id, role, ttl_days);
    // Сырая ссылка НЕ строится здесь (нет поля "link") — токен отдаётся как
    // есть, а URL join-страницы собирает wallet-web из своего же
    // location.origin (см. org/docs/TODO_mobile_sync.md, п. 9.3/9.5):
    // wallet-api в LAN-only MVP не знает и не должен угадывать, по какому
    // хосту/порту человек фактически открывает wallet-web (тот же принцип,
    // что resolve_redirect_uri в google-auth — сервер не хардкодит чужой
    // публичный адрес).
    res.status = 201;
    res.set_content(json{{"id", invite.id},
                          {"role", invite.role},
                          {"token", invite.token},
                          {"created_at", invite.created_at},
                          {"expires_at", invite.expires_at}}
                         .dump(),
                     kJsonContentType);
}

void handle_list_invites(AppState& state, const httplib::Request& req, httplib::Response& res) {
    applog::set_route("GET /api/ledger/invites"); // литерал из register_routes ниже
    auto caller = require_owner(state, req, res);
    if (!caller) return;

    auto invites = invites_repo::list_active_invites(*state.db_pool->acquire(), caller->membership.ledger_id);
    json out = json::array();
    for (const auto& i : invites) out.push_back(invite_to_json(i));
    res.set_content(json{{"invites", out}}.dump(), kJsonContentType);
}

void handle_revoke_invite(AppState& state, const httplib::Request& req, httplib::Response& res) {
    applog::set_route("DELETE /api/ledger/invites/:id"); // литерал из register_routes ниже
    auto caller = require_owner(state, req, res);
    if (!caller) return;

    std::string invite_id = path_param(req, "id");
    if (!invites_repo::revoke_invite(*state.db_pool->acquire(), caller->membership.ledger_id, invite_id)) {
        json_error(res, 404, "приглашение не найдено или уже не активно");
        return;
    }
    res.status = 204;
}

void handle_accept_invite(AppState& state, const httplib::Request& req, httplib::Response& res) {
    applog::set_route("POST /api/invites/accept"); // литерал из register_routes ниже
    // ТОЛЬКО аутентификация — БЕЗ require_membership: смысл этой ручки
    // именно в том, что у пользователя леджера ЕЩЁ нет (или есть — тогда
    // kAlreadyHasLedger ниже).
    auto user = require_auth(req, res, state);
    if (!user) return;

    json body;
    try {
        body = json::parse(req.body);
    } catch (const std::exception&) {
        json_error(res, 400, "некорректный JSON в теле запроса");
        return;
    }
    std::string token = body.value("token", std::string{});
    if (token.empty()) {
        json_error(res, 400, "token обязателен");
        return;
    }

    auto replace_it = body.find("replace_empty_ledger");
    if (replace_it != body.end() && !replace_it->is_boolean()) {
        json_error(res, 400, "replace_empty_ledger должен быть boolean");
        return;
    }
    bool replace_empty_ledger = replace_it != body.end() && replace_it->get<bool>();

    auto result = invites_repo::accept_invite(*state.db_pool->acquire(), user->user_id, user->email, token,
                                              replace_empty_ledger);
    switch (result.status) {
        case invites_repo::AcceptStatus::kOk:
            res.set_content(
                json{{"ledger_id", result.ledger_id}, {"role", result.role}}.dump(),
                kJsonContentType);
            return;
        case invites_repo::AcceptStatus::kInvalidOrExpired:
            json_error(res, 410, "ссылка недействительна — использована, отозвана или истёк срок");
            return;
        case invites_repo::AcceptStatus::kAlreadyHasLedger:
            // См. org/docs/TODO_mobile_sync.md, п. 9.7 — один леджер на
            // пользователя, приглашение НЕ расходуется. ledger_empty = true —
            // клиент может предложить заменить пустой леджер и повторить
            // запрос с replace_empty_ledger.
            res.status = 409;
            res.set_content(
                json{{"error", "у вас уже есть свой кошелёк — принять это приглашение сейчас нельзя"},
                     {"ledger_empty", result.ledger_empty}}
                    .dump(),
                kJsonContentType);
            return;
    }
}

} // namespace

void register_routes(httplib::Server& svr, AppState& state) {
    svr.Get("/api/ledger/members", [&state](const httplib::Request& req, httplib::Response& res) {
        handle_list_members(state, req, res);
    });
    svr.Patch("/api/ledger/members/:user_id",
              [&state](const httplib::Request& req, httplib::Response& res) {
                  handle_set_member_role(state, req, res);
              });
    svr.Delete("/api/ledger/members/:user_id",
               [&state](const httplib::Request& req, httplib::Response& res) {
                   handle_remove_member(state, req, res);
               });
    svr.Post("/api/ledger/transfer-owner",
             [&state](const httplib::Request& req, httplib::Response& res) {
                 handle_transfer_owner(state, req, res);
             });
    svr.Post("/api/ledger/invites", [&state](const httplib::Request& req, httplib::Response& res) {
        handle_create_invite(state, req, res);
    });
    svr.Get("/api/ledger/invites", [&state](const httplib::Request& req, httplib::Response& res) {
        handle_list_invites(state, req, res);
    });
    svr.Delete("/api/ledger/invites/:id",
               [&state](const httplib::Request& req, httplib::Response& res) {
                   handle_revoke_invite(state, req, res);
               });
    svr.Post("/api/invites/accept", [&state](const httplib::Request& req, httplib::Response& res) {
        handle_accept_invite(state, req, res);
    });
}

} // namespace invitesapi
