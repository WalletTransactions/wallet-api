// Разбор тела POST/PATCH /api/admin/icons (reference_icons_repo::
// parse_create/parse_update) — чистые функции, без базы — и HTTP-пролог
// reference_icons.cpp: отказы 401/403 случаются ДО базы (AppState::db_pool
// пуст, тот же приём, что test_sync.cpp). Записи, blob, дубль имени, in_use,
// доставка в pull и 201 под админом — tests_integration/test_reference_icons.cpp.
#include "reference_icons.hpp"
#include "reference_icons_repo.hpp"

#include <chrono>
#include <thread>

#include "httplib.h"
#include "test_framework.hpp"
#include "test_rsa_helper.hpp"
#include "util/jwks.hpp"

using nlohmann::json;
using reference_icons_repo::parse_create;
using reference_icons_repo::parse_update;

namespace {

const std::string kSha = std::string(64, 'a');
constexpr const char* kKid = "reference-icons-test-kid";
constexpr const char* kIconPath = "/api/admin/icons/11111111-1111-1111-1111-111111111111";

json minimal() { return json{{"name", "Cinema"}, {"icon_type", 0}, {"content_sha256", kSha}}; }

uint64_t epoch_now() {
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count());
}

// Тот же LocalServer, что в test_sync.cpp.
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

// role = user/support или claim'а нет — 403 forbidden на всех трёх ручках,
// ещё до разбора тела и до базы.
TEST(reference_icons_http_rejects_non_admin) {
    TestRsaKey key;
    std::string jwks_body = make_test_jwks(key, kKid);
    LocalServer jwks_server([&](httplib::Server& s) {
        s.Get("/.well-known/jwks.json", [&](const httplib::Request&, httplib::Response& res) {
            res.set_content(jwks_body, "application/json");
        });
    });

    AppState state;
    state.jwks = std::make_unique<jwks::Cache>(jwks_server.base_url());
    LocalServer api([&](httplib::Server& s) { reference_icons_api::register_routes(s, state); });
    httplib::Client client("127.0.0.1", api.port());

    for (const char* role : {"user", "support", ""}) {
        json claims = {{"sub", "user-1"},
                       {"iss", "google-auth"},
                       {"aud", json::array({"wallet-api"})},
                       {"scope", "wallet:read wallet:write"},
                       {"exp", epoch_now() + 900}};
        if (*role) claims["role"] = role;
        httplib::Headers headers = {{"Authorization", "Bearer " + make_test_jwt(key, kKid, claims)}};

        auto post = client.Post("/api/admin/icons", headers, minimal().dump(), "application/json");
        REQUIRE(post);
        CHECK_EQ(post->status, 403);
        CHECK_EQ(json::parse(post->body).value("error", std::string{}), std::string("forbidden"));

        auto patch = client.Patch(kIconPath, headers, R"({"name":"Кино"})", "application/json");
        REQUIRE(patch);
        CHECK_EQ(patch->status, 403);

        auto del = client.Delete(kIconPath, headers);
        REQUIRE(del);
        CHECK_EQ(del->status, 403);
    }
}

TEST(reference_icons_http_rejects_missing_token) {
    AppState state;
    state.jwks = std::make_unique<jwks::Cache>("http://127.0.0.1:1");
    LocalServer api([&](httplib::Server& s) { reference_icons_api::register_routes(s, state); });
    httplib::Client client("127.0.0.1", api.port());

    auto post = client.Post("/api/admin/icons", minimal().dump(), "application/json");
    REQUIRE(post);
    CHECK_EQ(post->status, 401);
    auto del = client.Delete(kIconPath);
    REQUIRE(del);
    CHECK_EQ(del->status, 401);
}

TEST(reference_icon_parse_create_trims_and_normalizes) {
    json body = minimal();
    body["name"] = "  Кино \t";
    body["content_sha256"] = std::string(64, 'A');
    body["icon_type"] = 2;
    auto r = parse_create(body);
    REQUIRE(r.error.empty());
    CHECK_EQ(*r.input.name, std::string("Кино"));
    CHECK_EQ(*r.input.icon_type, 2);
    CHECK_EQ(*r.input.content_sha256, kSha);
}

TEST(reference_icon_parse_create_requires_all_fields) {
    for (const char* key : {"name", "icon_type", "content_sha256"}) {
        json body = minimal();
        body.erase(key);
        auto r = parse_create(body);
        CHECK(!r.error.empty());
        CHECK_EQ(r.field, std::string(key));
    }
}

TEST(reference_icon_parse_name_length_in_characters) {
    // 64 кириллических символа — 128 байт UTF-8, но длина считается в символах.
    std::string cyr64;
    for (int i = 0; i < 64; ++i) cyr64 += "ж";
    json body = minimal();
    body["name"] = cyr64;
    CHECK(parse_create(body).error.empty());

    body["name"] = cyr64 + "ж";
    auto r = parse_create(body);
    CHECK(!r.error.empty());
    CHECK_EQ(r.field, std::string("name"));

    body["name"] = "  " + std::string(64, 'x') + "  "; // края не считаются
    CHECK(parse_create(body).error.empty());
}

TEST(reference_icon_parse_rejects_bad_fields_naming_the_field) {
    struct Case {
        const char* key;
        json value;
    };
    const Case cases[] = {
        {"name", "   "},
        {"name", 5},
        {"icon_type", -1},
        {"icon_type", 1.5},
        {"icon_type", "0"},
        {"icon_type", 40000},
        {"icon_type", json(std::uint64_t{18446744073709551615ULL})},
        {"content_sha256", std::string(63, 'a')},
        {"content_sha256", std::string(64, 'g')},
        {"content_sha256", 1},
    };
    for (const auto& c : cases) {
        json body = minimal();
        body[c.key] = c.value;
        auto r = parse_create(body);
        CHECK(!r.error.empty());
        CHECK_EQ(r.field, std::string(c.key));
    }
}

TEST(reference_icon_parse_create_rejects_non_object) {
    CHECK(!parse_create(json::array()).error.empty());
    CHECK(!parse_create(json("x")).error.empty());
}

TEST(reference_icon_parse_update_subset) {
    auto r = parse_update(json{{"name", " Кино "}});
    REQUIRE(r.error.empty());
    CHECK_EQ(*r.input.name, std::string("Кино"));
    CHECK(!r.input.icon_type);

    r = parse_update(json{{"icon_type", 1}});
    REQUIRE(r.error.empty());
    CHECK_EQ(*r.input.icon_type, 1);
    CHECK(!r.input.name);
}

TEST(reference_icon_parse_update_empty_and_content_rejected) {
    CHECK(!parse_update(json::object()).error.empty());
    // Чужие ключи не считаются полями для изменения.
    CHECK(!parse_update(json{{"color", "red"}}).error.empty());

    auto r = parse_update(json{{"name", "Кино"}, {"content_sha256", kSha}});
    CHECK(!r.error.empty());
    CHECK_EQ(r.field, std::string("content_sha256"));

    r = parse_update(json{{"name", ""}});
    CHECK_EQ(r.field, std::string("name"));
}
