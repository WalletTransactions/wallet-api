// Флаг приёма своих иконок (change optional-icon-upload) сквозь HTTP-слой
// против живого Postgres: POST /sync/blobs (blob.cpp), POST /sync/push и
// GET /sync/pull (sync.cpp) с настоящим JWT — флаг и роль проверяются именно
// там, а не в sync_repo. Флаг переключается прямо в AppState между запросами.
#include <chrono>
#include <string>
#include <thread>

#include "app_state.hpp"
#include "blob.hpp"
#include "fixture.hpp"
#include "httplib.h"
#include "nlohmann/json.hpp"
#include "sync.hpp"
#include "test_framework.hpp"
#include "../tests/test_rsa_helper.hpp"
#include "util/crypto.hpp"
#include "util/hex.hpp"
#include "util/jwks.hpp"
#include "util/uuid.hpp"

using nlohmann::json;

namespace {

constexpr const char* kKid = "it-icon-upload-kid";

class IconServer {
public:
    template <typename Configure>
    explicit IconServer(Configure configure) {
        configure(server_);
        port_ = server_.bind_to_any_port("127.0.0.1");
        thread_ = std::thread([this] { server_.listen_after_bind(); });
        while (!server_.is_running()) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    ~IconServer() {
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

uint64_t epoch_now() {
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count());
}

// JWKS + wallet-api (blob и sync) на локальных портах, флаг выключен.
struct Harness {
    TestRsaKey key;
    std::string jwks_body = make_test_jwks(key, kKid);
    IconServer jwks_server{[this](httplib::Server& s) {
        s.Get("/.well-known/jwks.json", [this](const httplib::Request&, httplib::Response& res) {
            res.set_content(jwks_body, "application/json");
        });
    }};
    AppState state;
    std::unique_ptr<IconServer> api;
    std::unique_ptr<httplib::Client> client;

    Harness() {
        state.jwks = std::make_unique<jwks::Cache>(jwks_server.base_url());
        state.db_pool = std::make_unique<db::Pool>(fixture::database_url(), 2);
        state.ledger_icon_upload = false;
        api = std::make_unique<IconServer>([this](httplib::Server& s) {
            blobapi::register_routes(s, state);
            syncapi::register_routes(s, state);
        });
        client = std::make_unique<httplib::Client>("127.0.0.1", api->port());
    }

    // Свой пользователь и устройство на каждый вызов (база не чистится).
    httplib::Headers token(const std::string& role) {
        json claims = {{"sub", uuidgen::v4()},
                       {"email", "it-icon-upload@example.com"},
                       {"iss", "google-auth"},
                       {"aud", json::array({"wallet-api"})},
                       {"scope", "wallet:read wallet:write"},
                       {"role", role},
                       {"device_id", uuidgen::v4()},
                       {"platform", "android"},
                       {"exp", epoch_now() + 900}};
        return httplib::Headers{{"Authorization", "Bearer " + make_test_jwt(key, kKid, claims)}};
    }

    json pull(const httplib::Headers& auth, int64_t ledger_seq = 0) {
        auto res = client->Get("/sync/pull?reference_seq=0&limit=1000&ledger_seq=" + std::to_string(ledger_seq), auth);
        if (!res) throw std::runtime_error("no response");
        if (res->status != 200) throw std::runtime_error("pull status " + std::to_string(res->status));
        return json::parse(res->body);
    }

    httplib::Result push(const httplib::Headers& auth, const std::string& batch_id, const json& changes) {
        json body = {{"batch_id", batch_id}, {"changes", changes}};
        return client->Post("/sync/push", auth, body.dump(), "application/json");
    }
};

// Уникальное содержимое на каждый прогон — иначе ON CONFLICT DO NOTHING
// скрыл бы, создан blob этим запросом или жил с прошлого раза.
std::string unique_body() { return "it-icon-upload " + uuidgen::v4() + uuidgen::v4(); }

bool blob_exists(db::Database& db, const std::string& body) {
    auto digest = crypto::sha256(body);
    std::string sha = hex::encode(std::string(reinterpret_cast<const char*>(digest.data()), digest.size()));
    return !db.exec("SELECT 1 FROM blob WHERE sha256 = decode($1, 'hex')", {sha}).rows.empty();
}

bool live_row(db::Database& db, const std::string& table, const std::string& uuid) {
    return !db.exec("SELECT 1 FROM " + table + " WHERE uuid = $1 AND deleted_at IS NULL", {uuid}).rows.empty();
}

json icon_row(const std::string& uuid, const std::string& sha) {
    return json{{"uuid", uuid}, {"name", "it-own-icon-" + uuid}, {"content_sha256", sha}, {"icon_type", 0}};
}

json account_row(const std::string& uuid, const std::string& icon_uuid) {
    return json{{"uuid", uuid},          {"name", "IconUp " + uuid}, {"comment", ""},
                {"icon_uuid", icon_uuid}, {"is_archived", false},    {"system_kind", 0},
                {"kind", 0},              {"category_kind", 2}};
}

json operation_row(const std::string& uuid, const std::string& from, const std::string& to) {
    return json{{"uuid", uuid},       {"date", "2026-11-22T12:00:00"}, {"acc_fr_uuid", from},
                {"acc_to_uuid", to}, {"amount", "10.00"},             {"comment", "icon upload test"}};
}

std::string make_blob(db::Database& db) {
    std::string sha = fixture::detail::random_hex64();
    db.exec("INSERT INTO blob (sha256, bytes) VALUES (decode($1, 'hex'), decode('00', 'hex'))", {sha});
    return sha;
}

} // namespace

TEST(icon_upload_blob_respects_flag_and_admin_role) {
    Harness h;
    auto db = fixture::open();

    // Без токена — 401, не 403: флаг проверяется после аутентификации.
    auto anon = h.client->Post("/sync/blobs", unique_body(), "application/octet-stream");
    REQUIRE(anon);
    CHECK_EQ(anon->status, 401);

    // Пользователь при выключенном флаге — 403, содержимое не сохранено.
    std::string body = unique_body();
    auto user = h.client->Post("/sync/blobs", h.token("user"), body, "application/octet-stream");
    REQUIRE(user);
    CHECK_EQ(user->status, 403);
    CHECK_EQ(json::parse(user->body).value("error", std::string{}), std::string("icon_upload_disabled"));
    CHECK(!blob_exists(*db, body));

    // Админ — 200 при выключенном флаге (общие иконки веба).
    std::string admin_body = unique_body();
    auto admin = h.client->Post("/sync/blobs", h.token("admin"), admin_body, "application/octet-stream");
    REQUIRE(admin);
    CHECK_EQ(admin->status, 200);
    CHECK(blob_exists(*db, admin_body));

    // Флаг включён — пользователю 200.
    h.state.ledger_icon_upload = true;
    auto allowed = h.client->Post("/sync/blobs", h.token("user"), body, "application/octet-stream");
    REQUIRE(allowed);
    CHECK_EQ(allowed->status, 200);
    CHECK(blob_exists(*db, body));
}

TEST(icon_upload_push_drops_icons_applies_rest_and_replays) {
    Harness h;
    auto db = fixture::open();
    auto auth = h.token("user");
    h.pull(auth); // провижининг леджера и устройства

    std::string ref_icon = fixture::make_reference_icon(*db);
    std::string own_icon = uuidgen::v4();
    std::string a = uuidgen::v4(), b = uuidgen::v4(), op = uuidgen::v4();
    json changes = {{"icon", json::array({icon_row(own_icon, make_blob(*db))})},
                    {"account", json::array({account_row(a, ref_icon), account_row(b, ref_icon)})},
                    {"operation", json::array({operation_row(op, a, b)})}};

    std::string batch_id = uuidgen::v4();
    auto first = h.push(auth, batch_id, changes);
    REQUIRE(first);
    REQUIRE(first->status == 200);
    json body = json::parse(first->body);
    CHECK_EQ(body.at("icons_rejected").at("error").get<std::string>(), std::string("icon_upload_disabled"));
    REQUIRE(body.at("icons_rejected").at("uuids").size() == 1);
    CHECK_EQ(body.at("icons_rejected").at("uuids").at(0).get<std::string>(), own_icon);
    CHECK(live_row(*db, "operation", op));
    CHECK(!live_row(*db, "icon", own_icon));

    // Повтор того же batch_id — тот же ответ, включая icons_rejected. Разобранный
    // JSON, не строка: sync_push_batch.response — jsonb, порядок ключей и пробелы
    // при обратном чтении не сохраняются (как в push_batch_replay_* рядом).
    auto replay = h.push(auth, batch_id, changes);
    REQUIRE(replay);
    CHECK_EQ(replay->status, 200);
    CHECK_EQ(json::parse(replay->body), body);

    // Батч без иконок — поля нет.
    auto plain = h.push(auth, uuidgen::v4(), {{"operation", json::array({operation_row(uuidgen::v4(), a, b)})}});
    REQUIRE(plain);
    CHECK_EQ(plain->status, 200);
    CHECK(!json::parse(plain->body).contains("icons_rejected"));
}

TEST(icon_upload_push_account_on_dropped_icon_is_missing_reference) {
    Harness h;
    auto db = fixture::open();
    auto auth = h.token("user");
    h.pull(auth);

    std::string own_icon = uuidgen::v4();
    std::string acc = uuidgen::v4();
    json changes = {{"icon", json::array({icon_row(own_icon, make_blob(*db))})},
                    {"account", json::array({account_row(acc, own_icon)})}};
    auto res = h.push(auth, uuidgen::v4(), changes);
    REQUIRE(res);
    CHECK_EQ(res->status, 409);
    json body = json::parse(res->body);
    CHECK_EQ(body.at("error").get<std::string>(), std::string("missing_reference"));
    CHECK(!body.contains("icons_rejected"));
    CHECK(!live_row(*db, "account", acc));
    CHECK(!live_row(*db, "icon", own_icon));
}

TEST(icon_upload_push_creates_icon_when_flag_on) {
    Harness h;
    h.state.ledger_icon_upload = true;
    auto db = fixture::open();
    auto auth = h.token("user");
    h.pull(auth);

    std::string own_icon = uuidgen::v4();
    std::string acc = uuidgen::v4();
    json changes = {{"icon", json::array({icon_row(own_icon, make_blob(*db))})},
                    {"account", json::array({account_row(acc, own_icon)})}};
    auto res = h.push(auth, uuidgen::v4(), changes);
    REQUIRE(res);
    CHECK_EQ(res->status, 200);
    CHECK(!json::parse(res->body).contains("icons_rejected"));
    CHECK(live_row(*db, "icon", own_icon));
    CHECK(live_row(*db, "account", acc));
}

TEST(icon_upload_pull_reports_capability_including_at_head) {
    Harness h;
    auto auth = h.token("user");

    json off = h.pull(auth);
    CHECK_EQ(off.at("capabilities").at("icon_upload").get<bool>(), false);

    h.state.ledger_icon_upload = true;
    int64_t head = off.at("ledger").at("next_seq").get<int64_t>();
    json at_head = h.pull(auth, head);
    CHECK_EQ(at_head.at("capabilities").at("icon_upload").get<bool>(), true);
    CHECK(at_head.at("ledger").at("changes").empty());
}
