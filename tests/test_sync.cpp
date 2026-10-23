// HTTP-пролог /sync/push и /sync/pull (sync.cpp, authenticate_and_provision)
// — только отказы, которые случаются ДО провижининга: AppState::db_pool здесь
// пуст, и тест, дошедший до базы, упал бы на нулевом указателе. JWKS — тот же
// фейковый сервер, что в test_session.cpp/test_access.cpp.
#include "sync.hpp"

#include <chrono>
#include <thread>

#include "httplib.h"
#include "nlohmann/json.hpp"
#include "test_framework.hpp"
#include "test_rsa_helper.hpp"
#include "util/jwks.hpp"

using nlohmann::json;

namespace {

constexpr const char* kKid = "sync-test-kid";

uint64_t epoch_now() {
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count());
}

// Поднимает httplib::Server в отдельном потоке на свободном порту 127.0.0.1;
// configure вызывается до старта — регистрирует маршруты.
class LocalServer {
public:
    template <typename Configure>
    explicit LocalServer(Configure configure) {
        configure(server_);
        port_ = server_.bind_to_any_port("127.0.0.1");
        thread_ = std::thread([this] { server_.listen_after_bind(); });
        while (!server_.is_running()) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    ~LocalServer() {
        server_.stop();
        if (thread_.joinable()) thread_.join();
    }
    std::string base_url() const { return "http://127.0.0.1:" + std::to_string(port_); }
    int port() const { return port_; }

private:
    httplib::Server server_;
    int port_ = 0;
    std::thread thread_;
};

} // namespace

// Токен без device_id (браузерная сессия, выпущенная до выдачи ей device_id)
// — 403 с машинным кодом, по которому веб делает один повтор через refresh.
TEST(sync_rejects_token_without_device_id_with_machine_code) {
    TestRsaKey key;
    std::string jwks_body = make_test_jwks(key, kKid);
    LocalServer jwks_server([&](httplib::Server& s) {
        s.Get("/.well-known/jwks.json", [&](const httplib::Request&, httplib::Response& res) {
            res.set_content(jwks_body, "application/json");
        });
    });

    AppState state;
    state.jwks = std::make_unique<jwks::Cache>(jwks_server.base_url());
    LocalServer api([&](httplib::Server& s) { syncapi::register_routes(s, state); });

    json claims = {{"sub", "user-1"},
                   {"email", "u@example.com"},
                   {"iss", "google-auth"},
                   {"aud", json::array({"wallet-api", "wallet-report", "google-auth"})},
                   {"scope", "wallet:read wallet:write reports:read account"},
                   {"platform", "web"},
                   {"exp", epoch_now() + 900}};
    std::string token = make_test_jwt(key, kKid, claims);
    httplib::Headers headers = {{"Authorization", "Bearer " + token}};

    httplib::Client client("127.0.0.1", api.port());
    auto push = client.Post("/sync/push", headers, R"({"batch_id":"b1","changes":{}})", "application/json");
    CHECK(push);
    CHECK_EQ(push->status, 403);
    CHECK_EQ(json::parse(push->body).value("error", std::string{}), std::string("device_required"));

    auto pull = client.Get("/sync/pull", headers);
    CHECK(pull);
    CHECK_EQ(pull->status, 403);
    CHECK_EQ(json::parse(pull->body).value("error", std::string{}), std::string("device_required"));
}

// Без токена — 401, до проверки устройства.
TEST(sync_rejects_missing_token_before_device_check) {
    AppState state;
    state.jwks = std::make_unique<jwks::Cache>("http://127.0.0.1:1");
    LocalServer api([&](httplib::Server& s) { syncapi::register_routes(s, state); });

    httplib::Client client("127.0.0.1", api.port());
    auto push = client.Post("/sync/push", R"({"batch_id":"b1","changes":{}})", "application/json");
    CHECK(push);
    CHECK_EQ(push->status, 401);
}
