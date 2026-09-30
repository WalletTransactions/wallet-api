// Юнит-тесты session::current_user() — единственное место, где wallet-api
// решает, кто стучится (Bearer/cookie, подпись по JWKS, device_id/platform).
// Не требует ни Postgres, ни настоящего google-auth: jwks::Cache реально
// ходит по HTTP за ключами (util/jwks.cpp) — вместо внешнего сервиса
// поднимаем на 127.0.0.1 такой же /.well-known/jwks.json сами, в этом же
// процессе (см. FakeJwksServer ниже). Другого способа скормить Cache
// тестовый ключ нет — у неё нет конструктора "из готовых ключей".
//
// Явно включает регрессию на баг 2026-09-04 (см. README wallet-api, "Как
// проверяется токен, исправлено..."): current_user раньше читал ТОЛЬКО
// cookie, Authorization: Bearer не разбирался вообще, хотя README и текст
// ошибки require_auth это обещали. Мобильный клиент (нет cookie jar) не
// смог бы пройти авторизацию здесь ни на одном эндпоинте.
#include "session.hpp"

#include <chrono>
#include <thread>

#include "httplib.h"
#include "nlohmann/json.hpp"
#include "test_framework.hpp"
#include "test_rsa_helper.hpp"
#include "util/jwks.hpp"

using nlohmann::json;

namespace {

constexpr const char* kTestKid = "test-kid";
constexpr const char* kOtherKid = "other-kid"; // не совпадает ни с одним ключом в фейковом JWKS

uint64_t epoch_now() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::seconds>(
                                      std::chrono::system_clock::now().time_since_epoch())
                                      .count());
}

// Поднимает GET /.well-known/jwks.json на 127.0.0.1 в отдельном потоке —
// jwks::Cache реально делает HTTP-запрос (см. шапку файла, почему иначе
// никак). Это по-прежнему юнит-тест, не интеграционный: процесс общается
// сам с собой через loopback, никакой внешней инфраструктуры не требуется.
class FakeJwksServer {
public:
    explicit FakeJwksServer(std::string jwks_body) : jwks_body_(std::move(jwks_body)) {
        server_.Get("/.well-known/jwks.json",
                     [this](const httplib::Request&, httplib::Response& res) {
                         res.set_content(jwks_body_, "application/json");
                     });
        port_ = server_.bind_to_any_port("127.0.0.1");
        thread_ = std::thread([this] { server_.listen_after_bind(); });
        while (!server_.is_running()) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }

    ~FakeJwksServer() {
        server_.stop();
        if (thread_.joinable()) thread_.join();
    }

    std::string base_url() const { return "http://127.0.0.1:" + std::to_string(port_); }

private:
    std::string jwks_body_;
    httplib::Server server_;
    int port_ = 0;
    std::thread thread_;
};

json base_payload() {
    return json{{"sub", "user-1"}, {"email", "u@example.com"}, {"name", "User"}, {"role", "user"}};
}

std::string valid_token(const TestRsaKey& key, json extra_claims = json::object()) {
    json payload = base_payload();
    payload.update(extra_claims);
    payload["exp"] = epoch_now() + 900;
    return make_test_jwt(key, kTestKid, payload);
}

} // namespace

TEST(session_current_user_returns_nullopt_without_any_token) {
    TestRsaKey key;
    FakeJwksServer jwks_server(make_test_jwks(key, kTestKid));
    jwks::Cache cache(jwks_server.base_url());

    httplib::Request req;
    CHECK(!session::current_user(req, cache).has_value());
}

TEST(session_current_user_accepts_bearer_header) {
    TestRsaKey key;
    FakeJwksServer jwks_server(make_test_jwks(key, kTestKid));
    jwks::Cache cache(jwks_server.base_url());

    httplib::Request req;
    req.set_header("Authorization", "Bearer " + valid_token(key));

    auto user = session::current_user(req, cache);
    REQUIRE(user.has_value());
    CHECK_EQ(user->user_id, std::string("user-1"));
    CHECK_EQ(user->email, std::string("u@example.com"));
    CHECK_EQ(user->name, std::string("User"));
    CHECK_EQ(user->role, std::string("user"));
}

TEST(session_current_user_accepts_session_cookie) {
    TestRsaKey key;
    FakeJwksServer jwks_server(make_test_jwks(key, kTestKid));
    jwks::Cache cache(jwks_server.base_url());

    httplib::Request req;
    req.set_header("Cookie", "other=1; session=" + valid_token(key) + "; another=2");

    auto user = session::current_user(req, cache);
    REQUIRE(user.has_value());
    CHECK_EQ(user->user_id, std::string("user-1"));
}

TEST(session_current_user_prefers_bearer_over_cookie_when_both_present) {
    TestRsaKey key;
    FakeJwksServer jwks_server(make_test_jwks(key, kTestKid));
    jwks::Cache cache(jwks_server.base_url());

    std::string bearer_token = valid_token(key, json{{"sub", "from-bearer"}});
    std::string cookie_token = valid_token(key, json{{"sub", "from-cookie"}});

    httplib::Request req;
    req.set_header("Authorization", "Bearer " + bearer_token);
    req.set_header("Cookie", "session=" + cookie_token);

    auto user = session::current_user(req, cache);
    REQUIRE(user.has_value());
    CHECK_EQ(user->user_id, std::string("from-bearer"));
}

TEST(session_current_user_ignores_non_bearer_authorization_and_falls_back_to_cookie) {
    // "Authorization: Basic ..." — не наш формат; extract_bearer() должен
    // просто не найти токен там и попробовать cookie, а не споткнуться.
    TestRsaKey key;
    FakeJwksServer jwks_server(make_test_jwks(key, kTestKid));
    jwks::Cache cache(jwks_server.base_url());

    httplib::Request req;
    req.set_header("Authorization", "Basic dXNlcjpwYXNz");
    req.set_header("Cookie", "session=" + valid_token(key));

    auto user = session::current_user(req, cache);
    REQUIRE(user.has_value());
    CHECK_EQ(user->user_id, std::string("user-1"));
}

TEST(session_current_user_rejects_garbage_bearer_token) {
    TestRsaKey key;
    FakeJwksServer jwks_server(make_test_jwks(key, kTestKid));
    jwks::Cache cache(jwks_server.base_url());

    httplib::Request req;
    req.set_header("Authorization", "Bearer not-a-real-jwt");
    CHECK(!session::current_user(req, cache).has_value());
}

TEST(session_current_user_rejects_token_with_unknown_kid) {
    // Токен подписан ключом, которого нет в (фейковом) JWKS — имитирует и
    // "чужой ключ", и "ключ на auth-сервисе успел смениться".
    TestRsaKey key;
    FakeJwksServer jwks_server(make_test_jwks(key, kTestKid));
    jwks::Cache cache(jwks_server.base_url());

    json payload = base_payload();
    payload["exp"] = epoch_now() + 900;
    std::string token = make_test_jwt(key, kOtherKid, payload);

    httplib::Request req;
    req.set_header("Authorization", "Bearer " + token);
    CHECK(!session::current_user(req, cache).has_value());
}

TEST(session_current_user_rejects_token_signed_by_a_different_key) {
    TestRsaKey key;
    TestRsaKey other_key;
    FakeJwksServer jwks_server(make_test_jwks(key, kTestKid));
    jwks::Cache cache(jwks_server.base_url());

    json payload = base_payload();
    payload["exp"] = epoch_now() + 900;
    // Тот же kid, что реально в JWKS, но подписано ДРУГИМ ключом — подмена
    // подписи должна провалиться, а не пройти по случайному совпадению kid.
    std::string token = make_test_jwt(other_key, kTestKid, payload);

    httplib::Request req;
    req.set_header("Authorization", "Bearer " + token);
    CHECK(!session::current_user(req, cache).has_value());
}

TEST(session_current_user_rejects_expired_token) {
    TestRsaKey key;
    FakeJwksServer jwks_server(make_test_jwks(key, kTestKid));
    jwks::Cache cache(jwks_server.base_url());

    json payload = base_payload();
    payload["exp"] = epoch_now() - 3600;
    std::string token = make_test_jwt(key, kTestKid, payload);

    httplib::Request req;
    req.set_header("Authorization", "Bearer " + token);
    CHECK(!session::current_user(req, cache).has_value());
}

TEST(session_current_user_extracts_device_claims_when_present) {
    // Заполнено только у токена мобильного входа (см. DeviceInfo,
    // google-auth) — этот тест покрывает контракт, на который опирается
    // sync.cpp::authenticate_and_provision (требует непустой device_id).
    TestRsaKey key;
    FakeJwksServer jwks_server(make_test_jwks(key, kTestKid));
    jwks::Cache cache(jwks_server.base_url());

    std::string token = valid_token(key, json{{"device_id", "device-1"}, {"platform", "android"}});

    httplib::Request req;
    req.set_header("Authorization", "Bearer " + token);

    auto user = session::current_user(req, cache);
    REQUIRE(user.has_value());
    CHECK_EQ(user->device_id, std::string("device-1"));
    CHECK_EQ(user->platform, std::string("android"));
}

TEST(session_current_user_device_claims_are_empty_for_browser_style_token) {
    // Браузерный вход не даёт device_id вообще — sync.cpp обязан отличать
    // это от мобильного (см. authenticate_and_provision, 403 без device_id).
    TestRsaKey key;
    FakeJwksServer jwks_server(make_test_jwks(key, kTestKid));
    jwks::Cache cache(jwks_server.base_url());

    httplib::Request req;
    req.set_header("Authorization", "Bearer " + valid_token(key));

    auto user = session::current_user(req, cache);
    REQUIRE(user.has_value());
    CHECK(user->device_id.empty());
    CHECK(user->platform.empty());
}
