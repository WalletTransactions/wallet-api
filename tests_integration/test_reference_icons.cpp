// Интеграционные тесты общего набора иконок (change server-managed-icons,
// spec reference-icons-admin) против живого Postgres: reference_icons_repo —
// проверка blob, дубль имени, только общая строка, in_use по живым ссылкам,
// доставка в поток справочников (GET /sync/pull, раздел reference). Плюс один
// сквозной HTTP-тест: настоящий гейт (access.cpp) + хендлеры
// reference_icons.cpp + JWT админа без device_id — 201 без провизионирования.
#include "reference_icons_repo.hpp"

#include <chrono>
#include <thread>

#include "../tests/test_rsa_helper.hpp"
#include "access.hpp"
#include "fixture.hpp"
#include "httplib.h"
#include "nlohmann/json.hpp"
#include "reference_icons.hpp"
#include "sync_repo.hpp"
#include "test_framework.hpp"
#include "util/jwks.hpp"
#include "util/uuid.hpp"

using nlohmann::json;
using reference_icons_repo::IconInput;
using reference_icons_repo::WriteError;

namespace {

// Имя из свежего uuid: база не чистится между прогонами (fixture.hpp), а
// uq_icon_name_reference — по всем живым общим иконкам.
std::string fresh_name() { return "it-ref-icon-" + uuidgen::v4().substr(0, 13); }

// Содержимое «загружено через POST /sync/blobs» — та же строка blob.
std::string make_blob(db::Database& db) {
    std::string sha = fixture::detail::random_hex64();
    db.exec("INSERT INTO blob (sha256, bytes) VALUES (decode($1, 'hex'), decode('00', 'hex'))", {sha});
    return sha;
}

IconInput input(const std::string& name, int icon_type, const std::string& sha) {
    IconInput in;
    in.name = name;
    in.icon_type = icon_type;
    in.content_sha256 = sha;
    return in;
}

int64_t reference_head(db::Database& db) {
    return std::stoll(db.exec("SELECT seq FROM change_stream WHERE id = $1", {reference_icons_repo::kReferenceStreamId})
                          .rows.at(0)
                          .fields.at(0));
}

std::optional<json> pulled_icon(db::Database& db, int64_t cursor, const std::string& uuid) {
    auto pull = sync_repo::pull_reference_stream(db, cursor, 100000);
    if (!pull.changes.contains("icon")) return std::nullopt;
    for (const auto& row : pull.changes.at("icon")) {
        if (row.at("uuid").get<std::string>() == uuid) return row;
    }
    return std::nullopt;
}

std::string create_ok(db::Database& db, const std::string& name) {
    auto r = reference_icons_repo::create_icon(db, input(name, 0, make_blob(db)));
    if (r.error != WriteError::kOk) throw std::runtime_error("fixture reference icon not created");
    return r.icon.at("uuid").get<std::string>();
}

std::string add_account(db::Database& db, const std::string& ledger_id, const std::string& icon_uuid) {
    std::string uuid = uuidgen::v4();
    auto seq = db.exec("SELECT next_seq($1)", {ledger_id}).rows.at(0).fields.at(0);
    db.exec("INSERT INTO account (uuid, ledger_id, seq, name, icon_uuid) VALUES ($1,$2,$3,$4,$5)",
            {uuid, ledger_id, seq, "acc-" + uuid, icon_uuid});
    return uuid;
}

} // namespace

TEST(reference_icon_create_arrives_in_reference_pull) {
    auto db = fixture::open();
    std::string sha = make_blob(*db);
    std::string name = fresh_name();
    int64_t cursor = reference_head(*db);

    auto r = reference_icons_repo::create_icon(*db, input(name, 1, sha));
    REQUIRE(r.error == WriteError::kOk);
    std::string uuid = r.icon.at("uuid").get<std::string>();
    CHECK(uuidgen::looks_valid(uuid));
    CHECK_EQ(r.icon.at("name").get<std::string>(), name);
    CHECK_EQ(r.icon.at("icon_type").get<int>(), 1);
    CHECK_EQ(r.icon.at("content_sha256").get<std::string>(), sha);

    // Ровно один новый seq потока справочников, общая строка, без устройства.
    CHECK_EQ(reference_head(*db), cursor + 1);
    auto row = db->exec("SELECT ledger_id IS NULL, updated_by IS NULL, seq FROM icon WHERE uuid = $1", {uuid});
    CHECK_EQ(row.rows.at(0).fields.at(0), std::string("t"));
    CHECK_EQ(row.rows.at(0).fields.at(1), std::string("t"));
    CHECK_EQ(std::stoll(row.rows.at(0).fields.at(2)), cursor + 1);

    auto pulled = pulled_icon(*db, cursor, uuid);
    REQUIRE(pulled.has_value());
    CHECK_EQ(pulled->at("name").get<std::string>(), name);
    CHECK_EQ(pulled->at("icon_type").get<int>(), 1);
    CHECK_EQ(pulled->at("content_sha256").get<std::string>(), sha);
    CHECK(pulled->at("deleted_at").is_null());
}

TEST(reference_icon_create_without_blob_is_rejected) {
    auto db = fixture::open();
    std::string name = fresh_name();
    int64_t cursor = reference_head(*db);

    auto r = reference_icons_repo::create_icon(*db, input(name, 0, fixture::detail::random_hex64()));
    CHECK(r.error == WriteError::kBlobMissing);
    CHECK_EQ(db->exec("SELECT count(*) FROM icon WHERE name = $1", {name}).rows.at(0).fields.at(0), std::string("0"));
    CHECK_EQ(reference_head(*db), cursor);
}

TEST(reference_icon_duplicate_name_conflicts_on_create_and_rename) {
    auto db = fixture::open();
    std::string name = fresh_name();
    create_ok(*db, name);

    auto dup = reference_icons_repo::create_icon(*db, input(name, 0, make_blob(*db)));
    CHECK(dup.error == WriteError::kDuplicate);

    std::string other = create_ok(*db, fresh_name());
    IconInput rename;
    rename.name = name;
    CHECK(reference_icons_repo::update_icon(*db, other, rename).error == WriteError::kDuplicate);

    // Своя иконка леджера с тем же именем — другой индекс, общей не мешает.
    auto identity = fixture::make_identity(*db);
    auto seq = db->exec("SELECT next_seq($1)", {identity.ledger_id}).rows.at(0).fields.at(0);
    std::string own_name = fresh_name();
    db->exec("INSERT INTO icon (uuid, ledger_id, seq, name, content_sha256, icon_type) "
             "VALUES ($1, $2, $3, $4, decode($5, 'hex'), 0)",
             {uuidgen::v4(), identity.ledger_id, seq, own_name, make_blob(*db)});
    CHECK(reference_icons_repo::create_icon(*db, input(own_name, 0, make_blob(*db))).error == WriteError::kOk);
}

TEST(reference_icon_update_renames_keeping_uuid_and_content) {
    auto db = fixture::open();
    std::string sha = make_blob(*db);
    auto created = reference_icons_repo::create_icon(*db, input(fresh_name(), 0, sha));
    REQUIRE(created.error == WriteError::kOk);
    std::string uuid = created.icon.at("uuid").get<std::string>();
    int64_t cursor = reference_head(*db);

    std::string new_name = "Кино " + uuidgen::v4().substr(0, 8);
    IconInput rename;
    rename.name = new_name;
    auto r = reference_icons_repo::update_icon(*db, uuid, rename);
    REQUIRE(r.error == WriteError::kOk);
    CHECK_EQ(r.icon.at("uuid").get<std::string>(), uuid);
    CHECK_EQ(r.icon.at("name").get<std::string>(), new_name);
    CHECK_EQ(r.icon.at("icon_type").get<int>(), 0);
    CHECK_EQ(r.icon.at("content_sha256").get<std::string>(), sha);
    CHECK_EQ(reference_head(*db), cursor + 1);

    IconInput retype;
    retype.icon_type = 1;
    auto r2 = reference_icons_repo::update_icon(*db, uuid, retype);
    REQUIRE(r2.error == WriteError::kOk);
    CHECK_EQ(r2.icon.at("name").get<std::string>(), new_name);
    CHECK_EQ(r2.icon.at("icon_type").get<int>(), 1);

    auto pulled = pulled_icon(*db, cursor, uuid);
    REQUIRE(pulled.has_value());
    CHECK_EQ(pulled->at("name").get<std::string>(), new_name);
    CHECK_EQ(pulled->at("icon_type").get<int>(), 1);
}

TEST(reference_icon_update_and_delete_of_ledger_icon_are_not_found) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    std::string uuid = uuidgen::v4();
    std::string name = fresh_name();
    auto seq = db->exec("SELECT next_seq($1)", {identity.ledger_id}).rows.at(0).fields.at(0);
    db->exec("INSERT INTO icon (uuid, ledger_id, seq, name, content_sha256, icon_type) "
             "VALUES ($1, $2, $3, $4, decode($5, 'hex'), 0)",
             {uuid, identity.ledger_id, seq, name, make_blob(*db)});

    IconInput rename;
    rename.name = fresh_name();
    CHECK(reference_icons_repo::update_icon(*db, uuid, rename).error == WriteError::kNotFound);
    CHECK(reference_icons_repo::delete_icon(*db, uuid).error == WriteError::kNotFound);
    auto row = db->exec("SELECT name, deleted_at IS NULL FROM icon WHERE uuid = $1", {uuid});
    CHECK_EQ(row.rows.at(0).fields.at(0), name);
    CHECK_EQ(row.rows.at(0).fields.at(1), std::string("t"));

    CHECK(reference_icons_repo::update_icon(*db, uuidgen::v4(), rename).error == WriteError::kNotFound);
    CHECK(reference_icons_repo::delete_icon(*db, uuidgen::v4()).error == WriteError::kNotFound);
}

TEST(reference_icon_delete_in_use_is_conflict) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    std::string uuid = create_ok(*db, fresh_name());
    add_account(*db, identity.ledger_id, uuid);
    fixture::make_currency(*db, identity.ledger_id, uuid);
    int64_t cursor = reference_head(*db);

    auto r = reference_icons_repo::delete_icon(*db, uuid);
    CHECK(r.error == WriteError::kInUse);
    CHECK_EQ(r.in_use, int64_t{2});
    CHECK(reference_icons_repo::find_icon(*db, uuid).has_value());
    CHECK_EQ(reference_head(*db), cursor);

    // Удалённый счёт не считается ссылкой.
    db->exec("UPDATE account SET deleted_at = now() WHERE icon_uuid = $1", {uuid});
    auto r2 = reference_icons_repo::delete_icon(*db, uuid);
    CHECK(r2.error == WriteError::kInUse);
    CHECK_EQ(r2.in_use, int64_t{1});
}

TEST(reference_icon_delete_unused_sends_tombstone) {
    auto db = fixture::open();
    std::string name = fresh_name();
    std::string uuid = create_ok(*db, name);
    int64_t cursor = reference_head(*db);

    CHECK(reference_icons_repo::delete_icon(*db, uuid).error == WriteError::kOk);
    CHECK_EQ(reference_head(*db), cursor + 1);
    CHECK(!reference_icons_repo::find_icon(*db, uuid).has_value());
    // blob не удаляется.
    auto blob = db->exec("SELECT count(*) FROM blob b JOIN icon i ON i.content_sha256 = b.sha256 WHERE i.uuid = $1",
                         {uuid});
    CHECK_EQ(blob.rows.at(0).fields.at(0), std::string("1"));

    auto pulled = pulled_icon(*db, cursor, uuid);
    REQUIRE(pulled.has_value());
    CHECK(!pulled->at("deleted_at").is_null());
    CHECK(pulled->at("updated_by").is_null());

    // Повтор и правка удалённой — 404.
    CHECK(reference_icons_repo::delete_icon(*db, uuid).error == WriteError::kNotFound);
    IconInput rename;
    rename.name = fresh_name();
    CHECK(reference_icons_repo::update_icon(*db, uuid, rename).error == WriteError::kNotFound);
    // Имя удалённой иконки снова свободно (индекс — только по живым).
    CHECK(reference_icons_repo::create_icon(*db, input(name, 0, make_blob(*db))).error == WriteError::kOk);
}

namespace {

uint64_t epoch_now() {
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count());
}

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

// Сквозной путь, как в проде (main.cpp): гейт scope в pre-routing, роль —
// в хендлере. Браузерная сессия админа без device_id создаёт, правит и
// удаляет иконку; пользователь, леджер и устройство под её sub не заводятся.
TEST(reference_icons_http_admin_browser_session_without_device) {
    constexpr const char* kKid = "it-reference-icons-kid";
    TestRsaKey key;
    std::string jwks_body = make_test_jwks(key, kKid);
    LocalServer jwks_server([&](httplib::Server& s) {
        s.Get("/.well-known/jwks.json", [&](const httplib::Request&, httplib::Response& res) {
            res.set_content(jwks_body, "application/json");
        });
    });

    AppState state;
    state.jwks = std::make_unique<jwks::Cache>(jwks_server.base_url());
    state.db_pool = std::make_unique<db::Pool>(fixture::database_url(), 2);
    LocalServer api([&](httplib::Server& s) {
        s.set_pre_routing_handler([&state](const httplib::Request& req, httplib::Response& res) {
            return authz::gate(req, res, *state.jwks);
        });
        reference_icons_api::register_routes(s, state);
    });
    httplib::Client client("127.0.0.1", api.port());

    auto db = fixture::open();
    std::string sub = uuidgen::v4();
    auto token = [&](const std::string& role, const std::string& scope) {
        json claims = {{"sub", sub},
                       {"email", "it-admin@example.com"},
                       {"iss", "google-auth"},
                       {"aud", json::array({"wallet-api", "wallet-report", "google-auth"})},
                       {"scope", scope},
                       {"role", role},
                       {"exp", epoch_now() + 900}};
        return httplib::Headers{{"Authorization", "Bearer " + make_test_jwt(key, kKid, claims)}};
    };
    std::string sha = make_blob(*db);
    std::string name = fresh_name();
    json body = {{"name", "  " + name + " "}, {"icon_type", 0}, {"content_sha256", sha}};

    // Обычный пользователь — 403 forbidden, иконки нет.
    auto as_user = client.Post("/api/admin/icons", token("user", "wallet:read wallet:write"), body.dump(),
                               "application/json");
    REQUIRE(as_user);
    CHECK_EQ(as_user->status, 403);
    CHECK_EQ(json::parse(as_user->body).value("error", std::string{}), std::string("forbidden"));
    // Админ без wallet:write — 403 гейта по scope.
    auto no_scope = client.Post("/api/admin/icons", token("admin", "wallet:read"), body.dump(), "application/json");
    REQUIRE(no_scope);
    CHECK_EQ(no_scope->status, 403);
    CHECK_EQ(json::parse(no_scope->body).value("error", std::string{}), std::string("нужен scope wallet:write"));
    CHECK_EQ(db->exec("SELECT count(*) FROM icon WHERE name = $1", {name}).rows.at(0).fields.at(0), std::string("0"));

    auto admin = token("admin", "wallet:read wallet:write reports:read account");
    auto created = client.Post("/api/admin/icons", admin, body.dump(), "application/json");
    REQUIRE(created);
    CHECK_EQ(created->status, 201);
    json icon = json::parse(created->body);
    CHECK_EQ(icon.at("name").get<std::string>(), name);
    CHECK_EQ(icon.at("content_sha256").get<std::string>(), sha);
    std::string uuid = icon.at("uuid").get<std::string>();

    // Ни пользователя, ни устройства, ни леджера под sub админа.
    CHECK_EQ(db->exec("SELECT count(*) FROM device WHERE user_id = $1", {sub}).rows.at(0).fields.at(0),
             std::string("0"));
    CHECK_EQ(db->exec("SELECT count(*) FROM ledger_member WHERE user_id = $1", {sub}).rows.at(0).fields.at(0),
             std::string("0"));

    // Коды ошибок по HTTP.
    auto dup = client.Post("/api/admin/icons", admin, body.dump(), "application/json");
    REQUIRE(dup);
    CHECK_EQ(dup->status, 409);
    CHECK_EQ(json::parse(dup->body).value("field", std::string{}), std::string("name"));

    json no_blob = {{"name", fresh_name()}, {"icon_type", 0}, {"content_sha256", fixture::detail::random_hex64()}};
    auto missing = client.Post("/api/admin/icons", admin, no_blob.dump(), "application/json");
    REQUIRE(missing);
    CHECK_EQ(missing->status, 400);
    CHECK_EQ(json::parse(missing->body).value("field", std::string{}), std::string("content_sha256"));

    auto bad = client.Post("/api/admin/icons", admin, R"({"name":"x","icon_type":-1,"content_sha256":"00"})",
                           "application/json");
    REQUIRE(bad);
    CHECK_EQ(bad->status, 400);

    std::string renamed = fresh_name();
    auto patched =
        client.Patch("/api/admin/icons/" + uuid, admin, json{{"name", renamed}}.dump(), "application/json");
    REQUIRE(patched);
    CHECK_EQ(patched->status, 200);
    CHECK_EQ(json::parse(patched->body).value("name", std::string{}), renamed);

    auto empty_patch = client.Patch("/api/admin/icons/" + uuid, admin, "{}", "application/json");
    REQUIRE(empty_patch);
    CHECK_EQ(empty_patch->status, 400);

    auto not_uuid = client.Patch("/api/admin/icons/not-a-uuid", admin, json{{"name", "x"}}.dump(), "application/json");
    REQUIRE(not_uuid);
    CHECK_EQ(not_uuid->status, 404);

    // Используемая — 409 in_use; после удаления ссылки — 204, затем 404.
    auto identity = fixture::make_identity(*db);
    std::string account = add_account(*db, identity.ledger_id, uuid);
    auto in_use = client.Delete("/api/admin/icons/" + uuid, admin);
    REQUIRE(in_use);
    CHECK_EQ(in_use->status, 409);
    CHECK_EQ(json::parse(in_use->body).value("error", std::string{}), std::string("in_use"));
    CHECK_EQ(json::parse(in_use->body).value("in_use", 0), 1);

    db->exec("UPDATE account SET deleted_at = now() WHERE uuid = $1", {account});
    auto deleted = client.Delete("/api/admin/icons/" + uuid, admin);
    REQUIRE(deleted);
    CHECK_EQ(deleted->status, 204);
    auto again = client.Delete("/api/admin/icons/" + uuid, admin);
    REQUIRE(again);
    CHECK_EQ(again->status, 404);
}
