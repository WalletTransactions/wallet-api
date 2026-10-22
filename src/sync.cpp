#include "sync.hpp"

#include <optional>

#include "nlohmann/json.hpp"
#include "provisioning.hpp"
#include "session.hpp"
#include "sync_repo.hpp"
#include "util/log.hpp"

using nlohmann::json;

namespace syncapi {

namespace {

constexpr const char* kJsonContentType = "application/json";

void json_error(httplib::Response& res, int status, const std::string& message) {
    res.status = status;
    res.set_content(json{{"error", message}}.dump(), kJsonContentType);
}

// Общий пролог push/pull: аутентификация + ленивое провижининг (см.
// provisioning.hpp). nullopt — хендлер уже ответил сам (401/403),
// вызывающий код должен просто вернуться.
struct Context {
    std::string ledger_id;
    std::string device_id;
    std::string role; // роль в леджере: owner | member | reader
    // Токен с expense:write без wallet:write — Telegram-бот
    // (TODO_telegram_tokens.md, «Скоупы»): push только новых операций.
    bool expense_only = false;
};

std::optional<Context> authenticate_and_provision(AppState& state, const httplib::Request& req,
                                                   httplib::Response& res) {
    auto user = session::current_user(req, *state.jwks);
    if (!user) {
        json_error(res, 401, "unauthenticated");
        return std::nullopt;
    }
    // Браузерный вход не даёт device_id вообще (см. DeviceInfo, google-auth) —
    // синк без устройства не имеет смысла: некуда провизионировать device,
    // не с чем связать курсор.
    if (user->device_id.empty()) {
        json_error(res, 403,
                   "этот эндпоинт только для мобильного входа — токен без claim'а device_id "
                   "(см. README google-auth, «Мобильный вход»)");
        return std::nullopt;
    }

    // device_name — необязательное поле тела запроса, только чтобы обновить
    // человекочитаемое имя устройства при случае; отсутствие/некорректный
    // JSON — не ошибка (у GET /sync/pull тела обычно и нет вовсе).
    std::string device_name;
    try {
        json body = json::parse(req.body);
        device_name = body.value("device_name", std::string{});
    } catch (const std::exception&) {
        // тела нет или оно не JSON — device_name остаётся пустым, не более того
    }

    auto identity = provisioning::ensure_identity(*state.db_pool->acquire(), user->user_id, user->email,
                                                   user->device_id, device_name, user->platform);
    bool expense_only = !session::has_scope(*user, "wallet:write") && session::has_scope(*user, "expense:write");
    return Context{identity.ledger_id, user->device_id, identity.role, expense_only};
}

void handle_push(AppState& state, const httplib::Request& req, httplib::Response& res) {
    applog::set_route("POST /sync/push"); // литерал из register_routes ниже
    auto ctx = authenticate_and_provision(state, req, res);
    if (!ctx) return;

    json body;
    try {
        body = json::parse(req.body);
    } catch (const std::exception&) {
        json_error(res, 400, "invalid JSON body");
        return;
    }

    std::string batch_id = body.value("batch_id", std::string{});
    if (batch_id.empty()) {
        json_error(res, 400, "batch_id обязателен (идемпотентность отправки, см. README)");
        return;
    }
    json changes = body.value("changes", json::object());
    if (!changes.is_object()) {
        json_error(res, 400, "changes должен быть объектом {\"<таблица>\": [...]}");
        return;
    }

    sync_repo::PushMode mode = sync_repo::PushMode::Full;
    if (ctx->expense_only) {
        // Читатель леджера не пишет и через бота (п. 6 §2 TODO_telegram_bot.md).
        // Телефоны читателя этой проверкой пока не закрыты — отдельная задача
        // там же.
        if (ctx->role == "reader") {
            json_error(res, 403, "reader_cannot_write");
            return;
        }
        mode = sync_repo::PushMode::CreateOperationsOnly;
    }

    auto outcome =
        sync_repo::push_batch(*state.db_pool->acquire(), ctx->ledger_id, ctx->device_id, batch_id, changes, mode);
    res.status = outcome.http_status;
    res.set_content(outcome.response_body, kJsonContentType);
}

int64_t param_or(const httplib::Request& req, const char* name, int64_t fallback) {
    if (!req.has_param(name)) return fallback;
    try {
        return std::stoll(req.get_param_value(name));
    } catch (const std::exception&) {
        return fallback;
    }
}

void handle_pull(AppState& state, const httplib::Request& req, httplib::Response& res) {
    applog::set_route("GET /sync/pull"); // литерал из register_routes ниже
    auto ctx = authenticate_and_provision(state, req, res);
    if (!ctx) return;

    int64_t ledger_cursor = param_or(req, "ledger_seq", 0);
    int64_t reference_cursor = param_or(req, "reference_seq", 0);
    // 500 — разумный дефолт для мобильной сети; клиент всё равно не должен
    // предполагать, что вся история влезет в один ответ (см. README
    // wallet-api/schema, "Курсор и страницы" — страница может выйти БОЛЬШЕ
    // limit, если не разрезать группу с одинаковым seq, но не меньше).
    int limit = static_cast<int>(param_or(req, "limit", 500));

    auto ledger_result = sync_repo::pull_ledger_stream(*state.db_pool->acquire(), ctx->ledger_id, ledger_cursor, limit);
    auto reference_result = sync_repo::pull_reference_stream(*state.db_pool->acquire(), reference_cursor, limit);

    // ledger_id — чтобы клиент заметил смену леджера (другой пользователь
    // при том же email, переход по инвайту) и сбросил курсор сам, не
    // дожидаясь, пока старый курсор окажется дальше головы (reset).
    json out = {
        {"ledger",
         {{"ledger_id", ctx->ledger_id},
          {"next_seq", ledger_result.next_seq},
          {"reset", ledger_result.reset},
          {"changes", ledger_result.changes}}},
        {"reference",
         {{"next_seq", reference_result.next_seq},
          {"reset", reference_result.reset},
          {"changes", reference_result.changes}}},
    };
    res.set_content(out.dump(), kJsonContentType);
}

} // namespace

void register_routes(httplib::Server& svr, AppState& state) {
    svr.Post("/sync/push", [&state](const httplib::Request& req, httplib::Response& res) {
        handle_push(state, req, res);
    });
    svr.Get("/sync/pull", [&state](const httplib::Request& req, httplib::Response& res) {
        handle_pull(state, req, res);
    });
}

} // namespace syncapi
