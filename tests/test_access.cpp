// Проверка iss/aud/scope (org/docs/TODO_telegram_tokens.md, шаг 2):
// util/jwt_claims — чистая функция, authz::required_scope — таблица
// маршрутов, authz::gate — целиком, на фейковом JWKS (тот же приём, что в
// test_session.cpp).
#include "access.hpp"

#include <chrono>
#include <thread>

#include "httplib.h"
#include "nlohmann/json.hpp"
#include "session.hpp"
#include "test_framework.hpp"
#include "test_rsa_helper.hpp"
#include "util/jwks.hpp"
#include "util/jwt_claims.hpp"

using nlohmann::json;

namespace {

constexpr const char* kKid = "access-test-kid";

uint64_t epoch_now() {
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count());
}

class JwksServer {
public:
    explicit JwksServer(std::string body) : body_(std::move(body)) {
        server_.Get("/.well-known/jwks.json", [this](const httplib::Request&, httplib::Response& res) {
            res.set_content(body_, "application/json");
        });
        port_ = server_.bind_to_any_port("127.0.0.1");
        thread_ = std::thread([this] { server_.listen_after_bind(); });
        while (!server_.is_running()) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    ~JwksServer() {
        server_.stop();
        if (thread_.joinable()) thread_.join();
    }
    std::string base_url() const { return "http://127.0.0.1:" + std::to_string(port_); }

private:
    std::string body_;
    httplib::Server server_;
    int port_ = 0;
    std::thread thread_;
};

json user_claims() {
    return json{{"sub", "user-1"},
                {"iss", "google-auth"},
                {"aud", json::array({"wallet-api", "wallet-report", "google-auth"})},
                {"scope", "wallet:read wallet:write reports:read account"}};
}

httplib::Request request(const std::string& method, const std::string& path, const std::string& token) {
    httplib::Request req;
    req.method = method;
    req.path = path;
    if (!token.empty()) req.set_header("Authorization", "Bearer " + token);
    return req;
}

} // namespace

TEST(jwt_claims_check_cases) {
    json ok = user_claims();
    CHECK(jwt_claims::check(ok, "wallet-api", "wallet:write") == jwt_claims::Result::Ok);
    CHECK(jwt_claims::check(ok, "wallet-api", "") == jwt_claims::Result::Ok);

    json legacy = {{"sub", "u"}};
    CHECK(jwt_claims::check(legacy, "wallet-api", "wallet:write") == jwt_claims::Result::Legacy);

    json bad_iss = ok;
    bad_iss["iss"] = "evil";
    CHECK(jwt_claims::check(bad_iss, "wallet-api", "") == jwt_claims::Result::WrongIssuer);
    json no_iss = ok;
    no_iss.erase("iss");
    CHECK(jwt_claims::check(no_iss, "wallet-api", "") == jwt_claims::Result::WrongIssuer);

    // Токен бота: aud без google-auth, узкий scope.
    json bot = {{"iss", "google-auth"},
                {"aud", json::array({"wallet-report", "wallet-api"})},
                {"scope", "reports:read expense:write"}};
    CHECK(jwt_claims::check(bot, "google-auth", "") == jwt_claims::Result::WrongAudience);
    CHECK(jwt_claims::check(bot, "wallet-api", "wallet:write") == jwt_claims::Result::InsufficientScope);
    CHECK(jwt_claims::check(bot, "wallet-report", "reports:read") == jwt_claims::Result::Ok);

    // aud строкой (RFC 7519 допускает).
    json single = {{"iss", "google-auth"}, {"aud", "wallet-api"}, {"scope", "wallet:read"}};
    CHECK(jwt_claims::check(single, "wallet-api", "wallet:read") == jwt_claims::Result::Ok);
    CHECK(jwt_claims::check(single, "wallet-report", "") == jwt_claims::Result::WrongAudience);

    // Скоуп — целым словом, не подстрокой.
    json partial = {{"iss", "google-auth"}, {"aud", "wallet-api"}, {"scope", "wallet:read-only"}};
    CHECK(jwt_claims::check(partial, "wallet-api", "wallet:read") == jwt_claims::Result::InsufficientScope);
}

TEST(access_required_scope_table) {
    CHECK_EQ(authz::required_scope("POST", "/sync/push"), std::string("wallet:write"));
    CHECK_EQ(authz::required_scope("GET", "/sync/pull"), std::string("wallet:read"));
    CHECK_EQ(authz::required_scope("GET", "/sync/blobs/abc"), std::string("wallet:read"));
    CHECK_EQ(authz::required_scope("POST", "/sync/blobs"), std::string("wallet:write"));
    CHECK_EQ(authz::required_scope("GET", "/api/ledger/members"), std::string("wallet:read"));
    CHECK_EQ(authz::required_scope("PATCH", "/api/ledger/members/u2"), std::string("wallet:write"));
    CHECK_EQ(authz::required_scope("POST", "/api/invites/accept"), std::string("wallet:write"));
    CHECK_EQ(authz::required_scope("GET", "/api/currency-pairs"), std::string("wallet:read"));
    CHECK_EQ(authz::required_scope("DELETE", "/api/currency-pairs/x/rates/2026-01-01"), std::string("wallet:write"));
    CHECK_EQ(authz::required_scope("POST", "/api/currencies"), std::string("wallet:write"));
    CHECK_EQ(authz::required_scope("PATCH", "/api/currencies/x"), std::string("wallet:write"));
    CHECK_EQ(authz::required_scope("DELETE", "/api/currencies/x"), std::string("wallet:write"));
    CHECK_EQ(authz::required_scope("GET", "/api/currencies"), std::string("wallet:read"));
    CHECK(authz::required_scope("GET", "/api/currenciesx").empty());
    CHECK_EQ(authz::required_scope("DELETE", "/api/account"), std::string("account"));
    CHECK(authz::required_scope("GET", "/healthz").empty());
    CHECK(authz::required_scope("GET", "/docs").empty());

    CHECK_EQ(authz::alternative_scope("POST", "/sync/push"), std::string("expense:write"));
    CHECK(authz::alternative_scope("GET", "/sync/pull").empty());
    CHECK(authz::alternative_scope("POST", "/sync/blobs").empty());
}

TEST(session_has_scope_whole_words) {
    session::User u;
    u.scope = "reports:read expense:write";
    CHECK(session::has_scope(u, "expense:write"));
    CHECK(session::has_scope(u, "reports:read"));
    CHECK(!session::has_scope(u, "wallet:write"));
    CHECK(!session::has_scope(u, "expense"));
    CHECK(!session::has_scope(u, ""));
    u.scope.clear();
    CHECK(!session::has_scope(u, "wallet:write"));
}

TEST(access_gate_end_to_end) {
    TestRsaKey key;
    JwksServer jwks_server(make_test_jwks(key, kKid));
    jwks::Cache cache(jwks_server.base_url());
    auto token = [&](json claims) {
        claims["exp"] = epoch_now() + 900;
        return make_test_jwt(key, kKid, claims);
    };

    // Пользователь — пропускается к хендлеру.
    {
        httplib::Response res;
        auto req = request("POST", "/sync/push", token(user_claims()));
        CHECK(authz::gate(req, res, cache) == httplib::Server::HandlerResponse::Unhandled);
    }
    // Старый токен без aud — 401 (шаг 3), и на push, и на pull.
    for (const char* path : {"/sync/push", "/sync/pull"}) {
        httplib::Response res;
        auto req = request(std::string(path) == "/sync/push" ? "POST" : "GET", path, token(json{{"sub", "user-1"}}));
        CHECK(authz::gate(req, res, cache) == httplib::Server::HandlerResponse::Handled);
        CHECK_EQ(res.status, 401);
        CHECK(res.get_header_value("WWW-Authenticate").find("invalid_token") != std::string::npos);
    }
    // Токен другого сервиса — 401.
    {
        json claims = user_claims();
        claims["aud"] = json::array({"wallet-report"});
        httplib::Response res;
        auto req = request("GET", "/sync/pull", token(claims));
        CHECK(authz::gate(req, res, cache) == httplib::Server::HandlerResponse::Handled);
        CHECK_EQ(res.status, 401);
    }
    // Токен бота: push пропускается (expense:write — границы проверит
    // хендлер), остальное с wallet:write/wallet:read — 403.
    {
        json bot = {{"sub", "user-1"},
                    {"iss", "google-auth"},
                    {"aud", json::array({"wallet-report", "wallet-api"})},
                    {"scope", "reports:read expense:write"}};
        httplib::Response res;
        auto req = request("POST", "/sync/push", token(bot));
        CHECK(authz::gate(req, res, cache) == httplib::Server::HandlerResponse::Unhandled);

        httplib::Response pull_res;
        auto pull = request("GET", "/sync/pull", token(bot));
        CHECK(authz::gate(pull, pull_res, cache) == httplib::Server::HandlerResponse::Handled);
        CHECK_EQ(pull_res.status, 403);

        httplib::Response blob_res;
        auto blob = request("POST", "/sync/blobs", token(bot));
        CHECK(authz::gate(blob, blob_res, cache) == httplib::Server::HandlerResponse::Handled);
        CHECK_EQ(blob_res.status, 403);
    }
    // Только reports:read — push закрыт.
    {
        json reader = {{"sub", "user-1"},
                       {"iss", "google-auth"},
                       {"aud", json::array({"wallet-api"})},
                       {"scope", "reports:read"}};
        httplib::Response res;
        auto req = request("POST", "/sync/push", token(reader));
        CHECK(authz::gate(req, res, cache) == httplib::Server::HandlerResponse::Handled);
        CHECK_EQ(res.status, 403);
        CHECK(res.get_header_value("WWW-Authenticate").find("insufficient_scope") != std::string::npos);
    }
    // Правка валюты без записи (spec api-access-control) — 403 «нужен scope wallet:write».
    {
        json read_only = user_claims();
        read_only["scope"] = "wallet:read reports:read";
        httplib::Response res;
        auto req = request("PATCH", "/api/currencies/11111111-1111-1111-1111-111111111111", token(read_only));
        CHECK(authz::gate(req, res, cache) == httplib::Server::HandlerResponse::Handled);
        CHECK_EQ(res.status, 403);
        CHECK_EQ(json::parse(res.body).value("error", std::string{}), std::string("нужен scope wallet:write"));
    }
    // Без токена и с битым токеном — решает хендлер (401), gate не вмешивается.
    {
        httplib::Response res;
        auto req = request("POST", "/sync/push", "");
        CHECK(authz::gate(req, res, cache) == httplib::Server::HandlerResponse::Unhandled);
        auto bad = request("POST", "/sync/push", "not.a.jwt");
        CHECK(authz::gate(bad, res, cache) == httplib::Server::HandlerResponse::Unhandled);
    }
    // Служебные ручки — без проверки вовсе.
    {
        json claims = user_claims();
        claims["aud"] = "something-else";
        httplib::Response res;
        auto req = request("GET", "/healthz", token(claims));
        CHECK(authz::gate(req, res, cache) == httplib::Server::HandlerResponse::Unhandled);
    }
}
