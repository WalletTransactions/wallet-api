#include "sync.hpp"

#include <cctype>
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
    // Синк без устройства не имеет смысла: некуда провизионировать device,
    // не с чем связать курсор и updated_by. Браузер получает device_id на
    // каждый вход (google-auth, «device_id у браузера»), но токен сессии,
    // выпущенной раньше, его ещё не несёт — машинный код, а не фраза, чтобы
    // веб отличил этот случай и повторил запрос один раз через /auth/refresh.
    if (user->device_id.empty()) {
        json_error(res, 403, "device_required");
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

// ledger_id запроса совпадает с текущим леджером? uuid из Postgres — в
// нижнем регистре, клиент возвращает то, что получил, но регистр не
// значим — сравниваем без него.
bool same_uuid(std::string a, std::string b) {
    auto lower = [](std::string& s) {
        for (auto& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    };
    lower(a);
    lower(b);
    return a == b;
}

// Чистка tombstone после pull (change purge-synced-tombstones): не чаще
// раза в час на поток (троттлинг внутри maybe_purge_stream), отдельным
// соединением пула; ошибка — только в лог, ответ pull уже сформирован и не
// меняется.
void purge_after_pull(AppState& state, const std::string& stream_id) {
    try {
        sync_repo::maybe_purge_stream(*state.db_pool->acquire(), stream_id, state.tombstone_device_ttl_days);
    } catch (const std::exception& e) {
        applog::error("sync tombstone purge failed",
                      {{"event", "sync_tombstone_purge_failed"}, {"stream_id", stream_id}, {"error", e.what()}});
    }
}

json stream_json(const sync_repo::PullResult& r) {
    json out = {{"next_seq", r.next_seq}, {"reset", r.reset}, {"changes", r.changes}};
    // reset_reason — только при сбросе (спека sync-pull: без сброса поля нет).
    if (r.reset) out["reset_reason"] = r.reset_reason;
    return out;
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

    // Курсор от чужого леджера (ledger_id запроса не совпал) — не продолжение
    // загрузки этого потока, отметка начала загрузки к нему не относится.
    bool foreign_ledger =
        req.has_param("ledger_id") && !same_uuid(req.get_param_value("ledger_id"), ctx->ledger_id);
    // Отметки начала загрузки с нуля (миграция 000029): курсор ниже
    // purged_seq у устройства, которое грузится с нуля, — граница страницы,
    // а не отставание. Без них загрузка в несколько страниц после чистки
    // зацикливалась (ручная проверка на test 2026-11-04).
    auto bases = sync_repo::device_load_bases(*state.db_pool->acquire(), ctx->device_id);
    auto ledger_result = sync_repo::pull_ledger_stream(*state.db_pool->acquire(), ctx->ledger_id, ledger_cursor, limit,
                                                       foreign_ledger ? std::nullopt : bases.ledger);
    auto reference_result =
        sync_repo::pull_reference_stream(*state.db_pool->acquire(), reference_cursor, limit, bases.reference);

    // Подтверждение (change purge-synced-tombstones): курсор запроса — всё
    // до него устройство уже применило. При сбросе устройство начинает
    // поток заново, его подтверждение — 0 (курсор впереди головы или от
    // вычищенного прошлого ничего не подтверждает). ledger_id запроса не
    // совпал с текущим леджером — курсор от чужого потока, подтверждение
    // леджера не пишется; без ledger_id (старые клиенты) — пишется.
    std::optional<int64_t> ledger_ack = ledger_result.reset ? 0 : ledger_cursor;
    if (foreign_ledger) ledger_ack = std::nullopt;
    int64_t reference_ack = reference_result.reset ? 0 : reference_cursor;
    // Поток начат с нуля (курсор 0 или сброс) — запоминаем, до какого seq он
    // был вычищен в этот момент.
    std::optional<int64_t> ledger_base, reference_base;
    if (ledger_ack && *ledger_ack == 0) ledger_base = ledger_result.purged_seq;
    if (reference_ack == 0) reference_base = reference_result.purged_seq;
    sync_repo::record_ack(*state.db_pool->acquire(), ctx->device_id, ledger_ack, reference_ack, ledger_base,
                          reference_base);

    // ledger_id — чтобы клиент заметил смену леджера (другой пользователь
    // при том же email, переход по инвайту) и сбросил курсор сам, не
    // дожидаясь, пока старый курсор окажется дальше головы (reset).
    json ledger_out = stream_json(ledger_result);
    ledger_out["ledger_id"] = ctx->ledger_id;
    json out = {{"ledger", ledger_out}, {"reference", stream_json(reference_result)}};
    res.set_content(out.dump(), kJsonContentType);

    if (state.tombstone_purge) {
        purge_after_pull(state, ctx->ledger_id);
        purge_after_pull(state, sync_repo::kReferenceStreamId);
    }
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
