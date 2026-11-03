// wallet-api — сервис синка/отчётов кошелька (см. README, "Что реализовано").
// Сам не логинит и не выпускает токены (этим занимается auth-сервис,
// google-auth) — только проверяет уже выданный access-токен по JWKS
// (session.hpp, тот же приём, что в wallet-gateway) и держит СВОЮ, отдельную
// от auth-сервиса, Postgres-базу (db.hpp).
//
// Демонстрационный REST кошельков (POST/DELETE /api/wallets, wallet.cpp/
// repo.cpp/types.hpp) убран целиком (по прямому запросу, 2026-09-11) — им
// пользовался только временный demo-CRUD экран веб-фронтенда, настоящих
// данных кошелька он не нёс (см. историю в git). Таблица wallets в схеме и
// её проверка в Database::verify_schema() остаются — это маркер первой
// миграции (000001), не про эту фичу, см. комментарий там же.

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <fstream>
#include <memory>
#include <sstream>
#include <string>
#include <unordered_set>

#include "access.hpp"
#include "account_deletion.hpp"
#include "app_state.hpp"
#include "blob.hpp"
#include "currencies.hpp"
#include "currency_pairs.hpp"
#include "docs.hpp"
#include "httplib.h"
#include "invites.hpp"
#include "nlohmann/json.hpp"
#include "reference_icons.hpp"
#include "sync.hpp"
#include "util/dotenv.hpp"
#include "util/jwks.hpp"
#include "util/log.hpp"
#include "util/metrics.hpp"
#include "version.hpp"

#ifdef _WIN32
#include <windows.h>
#endif

namespace {

#ifdef _WIN32
void fix_console_encoding() {
    SetConsoleOutputCP(CP_UTF8);
    SetConsoleCP(CP_UTF8);
}
#else
void fix_console_encoding() {}
#endif

std::string env_or(const char* key, const std::string& fallback) {
    const char* v = std::getenv(key);
    return (v != nullptr && *v != '\0') ? std::string(v) : fallback;
}

std::string env_required(const char* key, const std::string& hint) {
    const char* v = std::getenv(key);
    if (v == nullptr || *v == '\0') {
        applog::error(std::string(key) + " must be set — " + hint + " (см. README.md)");
        std::exit(1);
    }
    return std::string(v);
}

bool env_bool(const char* key, bool fallback) {
    const char* v = std::getenv(key);
    if (v == nullptr) return fallback;
    std::string s(v);
    return s == "1" || s == "true" || s == "TRUE" || s == "True";
}

// "a, b" -> {"a", "b"} — тот же приём, что и в google-auth/src/main.cpp
// (parse_csv_list): обрезка пробелов вокруг запятой, без lowercase (имена
// параметров SQL регистрозависимы). Используется для LOG_SQL_MASK_PARAMS.
std::unordered_set<std::string> parse_csv_list(const std::string& csv) {
    std::unordered_set<std::string> out;
    std::stringstream ss(csv);
    std::string item;
    while (std::getline(ss, item, ',')) {
        auto not_space = [](unsigned char c) { return std::isspace(c) == 0; };
        item.erase(item.begin(), std::find_if(item.begin(), item.end(), not_space));
        item.erase(std::find_if(item.rbegin(), item.rend(), not_space).base(), item.end());
        if (!item.empty()) out.insert(item);
    }
    return out;
}

std::string strip_trailing_slash(std::string url) {
    while (!url.empty() && url.back() == '/') url.pop_back();
    return url;
}

// Не льём в лог мегабайтные тела целиком (blob — до 1 МиБ, см. blob.cpp;
// отчёты тоже могут быть немаленькими) — обрезаем и явно отмечаем факт
// обрезки в самой строке, а не молча теряем хвост незамеченным.
//
// Лимит — в СЫРЫХ байтах тела, а не в байтах итоговой строки лога. На
// бинарных телах (тот же blob — WebP/JPEG и т.п.) непечатные байты при
// JSON-экранировании (nlohmann::json) раздуваются до 6 символов (`\u00XX`)
// каждый — при старом лимите 4096 байт одна строка лога могла разрастись до
// ~24 КБ и не влезть в лимит длины строки у journald: conmon молча резал её
// на куски (`CONTAINER_PARTIAL_MESSAGE:true` в journal), а fluent-bit
// (строгий JSON-парсер app_json, см. infra/logging/parsers.conf) не мог
// разобрать оборванный кусок и оставлял всю запись без "наших" полей
// (level/service/trace_id/msg — см. фильтр parser в
// infra/logging/fluent-bit.conf), только сырой "message". 1024 байт — с
// запасом даже при полном 6-кратном раздутии.
constexpr std::size_t kMaxLoggedBodyBytes = 1024;

std::string truncate_body(const std::string& body) {
    if (body.size() <= kMaxLoggedBodyBytes) return body;
    return body.substr(0, kMaxLoggedBodyBytes) + "...(обрезано, всего " +
           std::to_string(body.size()) + " байт)";
}

// Тело ответа для debug-лога. httplib сжимает res.body ДО вызова логгера
// (CPPHTTPLIB_ZLIB_SUPPORT + Accept-Encoding клиента) — в лог шли байты
// gzip, нечитаемые. Сжатое тело не пишем, только кодировку и размер.
std::string loggable_response_body(const httplib::Response& res) {
    std::string encoding = res.get_header_value("Content-Encoding");
    if (!encoding.empty()) return "(сжато " + encoding + ", " + std::to_string(res.body.size()) + " байт)";
    return truncate_body(res.body);
}

std::string default_log_dir() {
#ifdef _WIN32
    return "logs";
#else
    return "";
#endif
}

// Читает trace_id, который поставил wallet-gateway (единственная точка
// входа, см. его main.cpp, ensure_trace_id) — сам НИКОГДА не порождает
// новый: если сюда пришёл запрос без X-Trace-Id (прямой curl мимо гейтвея,
// удобно для проверок — см. README), это ожидаемо и не повод путать логи
// чужим id. Кладёт в thread_local (applog) на время обработки — httplib
// обслуживает запрос от pre_routing_handler до set_logger на одном потоке
// целиком (см. комментарий у set_trace_id в log.hpp).
httplib::Server::HandlerResponse handle_pre_routing(const httplib::Request& req,
                                                     httplib::Response& res) {
    applog::start_request_timer(); // как можно раньше — считаем весь запрос, не только роутинг
    std::string trace_id = req.get_header_value("X-Trace-Id");
    if (!trace_id.empty()) {
        applog::set_trace_id(trace_id);
        res.set_header("X-Trace-Id", trace_id);
    }
    return httplib::Server::HandlerResponse::Unhandled; // только трейс-контекст, роутинг не трогаем
}

} // namespace

int main() {
    fix_console_encoding();
    dotenv::load(".env");

    std::string log_dir = env_or("LOG_DIR", default_log_dir());
    if (log_dir == "stdout" || log_dir == "-") log_dir.clear();
    applog::init(log_dir, "wallet-api");

    // build_info для /metrics (см. util/metrics.cpp) — один раз здесь, до
    // svr.listen() (см. GET /version, docs.cpp — та же тройка полей).
    metrics::set_build_info(version::kService, version::kVersion, version::kBuild,
                            version::kGitCommit);

    AppState state;

    std::string auth_service_url = strip_trailing_slash(
        env_required("AUTH_SERVICE_URL", "адрес auth-сервиса, например http://127.0.0.1:8080"));
    // Тянет JWKS сразу при старте — если auth-сервис ещё не поднят, не
    // фатально: залогируется ошибка, первый реальный запрос попробует
    // обновить кэш ещё раз (см. util/jwks.hpp).
    state.jwks = std::make_unique<jwks::Cache>(auth_service_url);

    std::string database_url = env_required(
        "DATABASE_URL",
        "строка подключения к СВОЕЙ (отдельной от auth-сервиса) Postgres-базе, например "
        "postgresql://user:password@localhost:5432/wallet_api");
    // false по умолчанию — параметры SQL-запросов не должны молча оседать в
    // логе; включайте только для локальной отладки (см. README.md,
    // "Логирование").
    bool log_sql_params = env_bool("LOG_SQL_PARAMS", false);
    // Доп. имена параметров, чьи значения маскируются в логе SQL "***" (сверх
    // встроенного набора password/token/secret/... — см. builtin_mask_param_names()
    // в db.cpp) — расширяет его, не заменяет; см. README.md, "Логирование".
    auto log_sql_mask_params = parse_csv_list(env_or("LOG_SQL_MASK_PARAMS", ""));
    // DATABASE_POOL_SIZE — сколько соединений держать одновременно (см.
    // db.hpp::Pool, зачем вообще пул, а не одно, как раньше) — 8 по
    // умолчанию, тот же дефолт, что REPORTS_DB_POOL_SIZE у wallet-report.
    int database_pool_size = std::stoi(env_or("DATABASE_POOL_SIZE", "8"));
    // < 1 отдельно от Pool(size == 0) — там size типа std::size_t, и
    // отрицательное int при касте в него стало бы огромным числом.
    if (database_pool_size < 1) {
        applog::error("DATABASE_POOL_SIZE должен быть положительным целым, получено: " +
                      std::to_string(database_pool_size));
        return 1;
    }
    try {
        state.db_pool = std::make_unique<db::Pool>(database_url, static_cast<std::size_t>(database_pool_size),
                                                     log_sql_params, log_sql_mask_params);
        state.db_pool->verify_schema();
    } catch (const std::exception& ex) {
        applog::error(std::string("Postgres: ") + ex.what());
        return 1;
    }

    std::string host = env_or("HOST", "127.0.0.1");
    int port = std::stoi(env_or("PORT", "8082"));

    httplib::Server svr;
    // Трейс-контекст, затем iss/aud/scope токена (access.hpp) — до
    // хендлеров, одной точкой на все маршруты.
    svr.set_pre_routing_handler([&state](const httplib::Request& req, httplib::Response& res) {
        handle_pre_routing(req, res);
        return authz::gate(req, res, *state.jwks);
    });
    syncapi::register_routes(svr, state);
    blobapi::register_routes(svr, state);
    invitesapi::register_routes(svr, state); // Фаза 6: /api/ledger/*, /api/invites/accept
    currency_pairs_api::register_routes(svr, state); // "Курсы валют": /api/currency-pairs*
    currencies_api::register_routes(svr, state); // свои валюты: /api/currencies*
    account_deletion_api::register_routes(svr, state); // "Удалить аккаунт": DELETE /api/account
    reference_icons_api::register_routes(svr, state); // общий набор иконок (admin): /api/admin/icons*
    docsapi::register_routes(svr); // GET /openapi.yaml, /docs, /healthz, статика /vendor/swagger-ui/*

    // Защита от несловленного исключения где угодно в хендлерах (Фаза 2
    // впервые заводит код, где такое реально может случиться — db::QueryError
    // из середины транзакции push'а, JSON-поля не того типа и т.п., см.
    // sync_repo.cpp) — без этого cpp-httplib само не гарантирует, что запрос
    // корректно завершится 500, а не оборвёт соединение/поток. 500 здесь —
    // последняя линия обороны, а не замена try/catch по месту: там, где нужен
    // осмысленный код ответа (401/404/409...), он уже расставлен в хендлерах.
    svr.set_exception_handler(
        [](const httplib::Request& req, httplib::Response& res, std::exception_ptr ep) {
            std::string message = "internal error";
            try {
                if (ep) std::rethrow_exception(ep);
            } catch (const std::exception& e) {
                message = e.what();
            }
            applog::error("unhandled exception: " + req.method + " " + req.path + " -> " + message);
            res.status = 500;
            res.set_content(nlohmann::json{{"error", "internal server error"}}.dump(),
                             "application/json");
        });

    // Ещё на том же потоке, что и handle_pre_routing — trace_id (если был)
    // всё ещё в thread_local, попадёт и в эту строку; clear_trace_id() —
    // последнее, что касается его на этом потоке, дальше он уйдёт в пул
    // httplib обслуживать чужой запрос (см. set_trace_id в log.hpp).
    svr.set_logger([](const httplib::Request& req, const httplib::Response& res) {
        // Метрики — на ВСЕ запросы, включая /healthz и сам /metrics: в
        // отличие от access-лога ниже, кардинальность здесь уже ограничена
        // applog::current_route() (см. util/metrics.hpp), а знать RPS/
        // латентность healthcheck'а тоже полезно (отличить "не отвечает
        // вовсе" от "отвечает медленно"). route выставляется каждым
        // хендлером через applog::set_route() — если хендлер (докстраница,
        // /healthz, /metrics) этого не делает, current_route() вернётся
        // пустой, "(unset)" группирует такие запросы одним лейблом.
        metrics::observe_http_request(
            req.method, applog::current_route().empty() ? "(unset)" : applog::current_route(),
            res.status, applog::request_duration_ms());

        // /healthz — не запрос приложения, а probe compose'а (interval 10s,
        // см. compose.yaml) — по логам он не отличим от реального трафика,
        // но забивает их шумом (~8640 строк/сутки) без всякой пользы: сама
        // проверка ничего не открывает и не пишет. clear_request_context()
        // всё равно нужен (thread_local не должен утечь в следующий, никак
        // не связанный запрос на этом потоке) — выходим, не пропуская его,
        // а не просто пропускаем обе строки лога.
        // /metrics — то же самое: скрейп Prometheus каждые 15 с, в теле —
        // текст метрик (или gzip), для разбора инцидентов бесполезный.
        if (req.path == "/healthz" || req.path == "/metrics") {
            applog::clear_request_context();
            return;
        }
        // details ДО clear_request_context() — trace_id/route/user_id ещё в
        // thread_local, попадут в эту строку сами (см. write_line в
        // log.cpp), явно передавать не нужно. "event":"request_finished" —
        // машиночитаемая метка ИМЕННО этой строки (не "db query" и не любой
        // другой info/error) — чтобы в Dashboards агрегировать перцентиль/
        // среднее по duration_ms надёжно, а не полагаться на разбор msg
        // (он меняется на каждый вызов: другой path/status).
        applog::info(req.method + " " + req.path + " -> " + std::to_string(res.status),
                     {{"event", "request_finished"}, {"duration_ms", applog::request_duration_ms()}});
        // Отдельной debug-строкой, не полями к строке выше — "request_finished"
        // агрегируют по duration_ms для метрик, подмешивать туда тела запроса/
        // ответа значило бы тащить их в тот же индекс/дашборд. Уровень именно
        // "debug" (см. log.hpp) — тело может нести персональные/платёжные
        // данные кошелька, а level — как раз то поле, по которому такие
        // строки отфильтровывают из постоянного мониторинга (jq/Loki), не
        // разбирая msg.
        applog::debug(req.method + " " + req.path,
                      {{"event", "request_body"},
                       {"request_body", truncate_body(req.body)},
                       {"response_body", loggable_response_body(res)}});
        applog::clear_request_context();
    });

    applog::info("wallet-api v" + std::string(version::kBuild) + " (" +
                 std::string(version::kGitCommit) + ") listening on http://" + host + ":" +
                 std::to_string(port) + " (auth-сервис: " + auth_service_url + ")" +
                 (log_dir.empty() ? "" : " (логи: " + log_dir + "/)"));
    if (!svr.listen(host, port)) {
        applog::error("не удалось запустить сервер на " + host + ":" + std::to_string(port) +
                      " (порт занят или недоступен?)");
        return 1;
    }
    return 0;
}
