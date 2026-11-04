// Интеграционные тесты срока хранения tombstone синка (change
// purge-synced-tombstones) против живого Postgres: подтверждения устройств,
// переписывание устройства на текущий леджер, горизонт, чистка и сброс
// "purged". Последний тест — сквозной GET /sync/pull через HTTP-слой
// (sync.cpp) с настоящим JWT, как reference_icons_http_* в
// test_reference_icons.cpp: выключатель, троттлинг и падение чистки живут
// именно там.
//
// Поток справочников общий на всю тестовую базу, поэтому его чистка здесь
// через purge_stream НЕ запускается (подняла бы purged_seq для всех тестов
// и всех будущих прогонов) — SQL чистки справочников проверяется в
// откатываемой транзакции (reference_purge_sql_*), а HTTP-тест всегда
// подтверждает reference_seq=0, так что горизонт справочников в тестовой
// базе остаётся 0.
#include <algorithm>
#include <chrono>
#include <optional>
#include <string>
#include <thread>

#include "app_state.hpp"
#include "fixture.hpp"
#include "httplib.h"
#include "invites_repo.hpp"
#include "nlohmann/json.hpp"
#include "provisioning.hpp"
#include "sync.hpp"
#include "sync_repo.hpp"
#include "test_framework.hpp"
#include "../tests/test_rsa_helper.hpp"
#include "util/jwks.hpp"
#include "util/uuid.hpp"

using nlohmann::json;

namespace {

// NULL -> "" (см. db::Row) — "" здесь и значит «подтверждения нет».
std::string device_field(db::Database& db, const std::string& device_id, const std::string& column) {
    return db.exec("SELECT " + column + " FROM device WHERE id = $1", {device_id}).rows.at(0).fields.at(0);
}

int64_t purged_seq(db::Database& db, const std::string& stream_id) {
    return std::stoll(
        db.exec("SELECT purged_seq FROM change_stream WHERE id = $1", {stream_id}).rows.at(0).fields.at(0));
}

bool row_exists(db::Database& db, const std::string& table, const std::string& uuid) {
    return !db.exec("SELECT 1 FROM " + table + " WHERE uuid = $1", {uuid}).rows.empty();
}

json account_row(const std::string& uuid, const std::string& icon_uuid) {
    return json{{"uuid", uuid},          {"name", "Tomb " + uuid}, {"comment", ""},
                {"icon_uuid", icon_uuid}, {"is_archived", false},  {"system_kind", 0},
                {"kind", 0}};
}

json operation_row(const std::string& uuid, const std::string& from, const std::string& to) {
    return json{{"uuid", uuid},       {"date", "2026-11-04T12:00:00"}, {"acc_fr_uuid", from},
                {"acc_to_uuid", to}, {"amount", "10.00"},             {"comment", "tombstone test"}};
}

json deleted(json row) {
    row["deleted"] = true;
    return row;
}

// Батч целиком, seq батча из ответа.
int64_t push(db::Database& db, const std::string& ledger_id, const std::string& device_id, const json& changes) {
    auto outcome = sync_repo::push_batch(db, ledger_id, device_id, uuidgen::v4(), changes);
    if (outcome.http_status != 200) throw std::runtime_error("push failed: " + outcome.response_body);
    return json::parse(outcome.response_body).at("seq").get<int64_t>();
}

void set_last_seen_days_ago(db::Database& db, const std::string& device_id, int days) {
    db.exec("UPDATE device SET last_seen_at = now() - make_interval(days => $2::int) WHERE id = $1",
            {device_id, std::to_string(days)});
}

} // namespace

// --- Подтверждения ----------------------------------------------------------

TEST(record_ack_writes_both_cursors_and_allows_decrease) {
    auto db = fixture::open();
    auto id = fixture::make_identity(*db);

    // Свежее устройство ещё ничего не подтверждало.
    CHECK_EQ(device_field(*db, id.device_id, "last_ack_seq"), std::string(""));
    CHECK_EQ(device_field(*db, id.device_id, "last_ack_reference_seq"), std::string(""));

    sync_repo::record_ack(*db, id.device_id, 120, 7);
    CHECK_EQ(device_field(*db, id.device_id, "last_ack_seq"), std::string("120"));
    CHECK_EQ(device_field(*db, id.device_id, "last_ack_reference_seq"), std::string("7"));

    // Устройство начало поток заново — подтверждение уменьшается.
    sync_repo::record_ack(*db, id.device_id, 0, 3);
    CHECK_EQ(device_field(*db, id.device_id, "last_ack_seq"), std::string("0"));
    CHECK_EQ(device_field(*db, id.device_id, "last_ack_reference_seq"), std::string("3"));
}

TEST(record_ack_without_ledger_cursor_keeps_ledger_ack) {
    // Чужой ledger_id в запросе (см. sync.cpp) — подтверждение леджера не
    // трогается, справочники пишутся.
    auto db = fixture::open();
    auto id = fixture::make_identity(*db);
    sync_repo::record_ack(*db, id.device_id, 50, 5);
    sync_repo::record_ack(*db, id.device_id, std::nullopt, 9);
    CHECK_EQ(device_field(*db, id.device_id, "last_ack_seq"), std::string("50"));
    CHECK_EQ(device_field(*db, id.device_id, "last_ack_reference_seq"), std::string("9"));
}

// --- Устройство на текущем леджере (решение 9) -------------------------------

TEST(device_follows_user_to_invited_ledger_and_back_to_new_personal) {
    auto db = fixture::open();
    auto owner = fixture::make_identity(*db);
    auto guest = fixture::make_identity(*db); // свой пустой личный леджер
    const std::string email = "integration-test@example.com";

    // Повторный вход в тот же леджер подтверждение не трогает.
    sync_repo::record_ack(*db, guest.device_id, 5, 0);
    provisioning::ensure_identity(*db, guest.user_id, email, guest.device_id, "", "other");
    CHECK_EQ(device_field(*db, guest.device_id, "ledger_id"), guest.ledger_id);
    CHECK_EQ(device_field(*db, guest.device_id, "last_ack_seq"), std::string("5"));

    // Принял приглашение (пустой личный леджер заменён — устройство ушло
    // вместе с ним каскадом и заводится заново уже на леджере владельца).
    auto invite = invites_repo::create_invite(*db, owner.ledger_id, owner.user_id, "member", 7);
    auto accepted = invites_repo::accept_invite(*db, guest.user_id, email, invite.token,
                                                /*replace_empty_ledger=*/true);
    REQUIRE(accepted.status == invites_repo::AcceptStatus::kOk);
    auto in_owner = provisioning::ensure_identity(*db, guest.user_id, email, guest.device_id, "", "other");
    CHECK_EQ(in_owner.ledger_id, owner.ledger_id);
    CHECK_EQ(device_field(*db, guest.device_id, "ledger_id"), owner.ledger_id);
    CHECK_EQ(device_field(*db, guest.device_id, "last_ack_seq"), std::string(""));

    // Подтвердил поток леджера владельца, затем удалён из участников —
    // устройство переписывается на новый личный леджер, подтверждение пусто.
    sync_repo::record_ack(*db, guest.device_id, 3, 0);
    REQUIRE(invites_repo::remove_member(*db, owner.ledger_id, guest.user_id));
    auto personal = provisioning::ensure_identity(*db, guest.user_id, email, guest.device_id, "", "other");
    CHECK(personal.ledger_id != owner.ledger_id);
    CHECK_EQ(device_field(*db, guest.device_id, "ledger_id"), personal.ledger_id);
    CHECK_EQ(device_field(*db, guest.device_id, "last_ack_seq"), std::string(""));
}

// --- Горизонт ---------------------------------------------------------------

TEST(horizon_two_phones_lost_phone_and_bot) {
    auto db = fixture::open();
    auto id = fixture::make_identity(*db);
    db->exec("UPDATE change_stream SET seq = 1000 WHERE id = $1", {id.ledger_id});

    // Только устройство без подтверждения (как бот: только push) — голова.
    CHECK_EQ(sync_repo::stream_horizon(*db, id.ledger_id, 90), int64_t{1000});

    auto add_device = [&](int64_t ack) {
        std::string device = uuidgen::v4();
        provisioning::ensure_identity(*db, id.user_id, "integration-test@example.com", device, "", "android");
        sync_repo::record_ack(*db, device, ack, 0);
        return device;
    };
    add_device(80);
    add_device(120);
    CHECK_EQ(sync_repo::stream_horizon(*db, id.ledger_id, 90), int64_t{80});

    // Потерянный телефон: подтверждение 10, pull был 91 день назад.
    std::string lost = add_device(10);
    set_last_seen_days_ago(*db, lost, 91);
    CHECK_EQ(sync_repo::stream_horizon(*db, id.ledger_id, 90), int64_t{80});
    // Тот же телефон в пределах срока держит горизонт.
    set_last_seen_days_ago(*db, lost, 89);
    CHECK_EQ(sync_repo::stream_horizon(*db, id.ledger_id, 90), int64_t{10});
}

TEST(horizon_never_exceeds_head) {
    auto db = fixture::open();
    auto id = fixture::make_identity(*db);
    db->exec("UPDATE change_stream SET seq = 20 WHERE id = $1", {id.ledger_id});
    sync_repo::record_ack(*db, id.device_id, 500, 0); // старый клиент без ledger_id
    CHECK_EQ(sync_repo::stream_horizon(*db, id.ledger_id, 90), int64_t{20});
}

// --- Чистка -----------------------------------------------------------------

TEST(purge_removes_read_tombstones_and_keeps_referenced_and_unread) {
    auto db = fixture::open();
    auto id = fixture::make_identity(*db);
    std::string icon = fixture::make_reference_icon(*db);

    std::string a = uuidgen::v4(), b = uuidgen::v4(), referenced = uuidgen::v4(), lonely = uuidgen::v4();
    std::string op_read = uuidgen::v4(), op_live = uuidgen::v4(), op_lonely = uuidgen::v4(),
                op_unread = uuidgen::v4();
    push(*db, id.ledger_id, id.device_id,
         {{"account", json::array({account_row(a, icon), account_row(b, icon), account_row(referenced, icon),
                                   account_row(lonely, icon)})},
          {"operation", json::array({operation_row(op_read, a, b), operation_row(op_live, referenced, b),
                                     operation_row(op_lonely, lonely, b), operation_row(op_unread, a, b)})}});

    // Удалённая операция; удалённый счёт с живой операцией; удалённые
    // вместе счёт и его единственная операция (лист и корень в одном проходе).
    push(*db, id.ledger_id, id.device_id,
         {{"operation", json::array({deleted(operation_row(op_read, a, b)),
                                     deleted(operation_row(op_lonely, lonely, b))})},
          {"account", json::array({deleted(account_row(referenced, icon)), deleted(account_row(lonely, icon))})}});
    int64_t horizon = push(*db, id.ledger_id, id.device_id, {{"account", json::array({account_row(a, icon)})}});
    // Удаление выше горизонта — ещё не прочитано.
    push(*db, id.ledger_id, id.device_id, {{"operation", json::array({deleted(operation_row(op_unread, a, b))})}});

    auto stats = sync_repo::purge_stream(*db, id.ledger_id, horizon);
    CHECK_EQ(stats.deleted_rows, int64_t{3});
    CHECK_EQ(stats.purged_seq, horizon);
    CHECK_EQ(purged_seq(*db, id.ledger_id), horizon);

    CHECK(!row_exists(*db, "operation", op_read));
    CHECK(!row_exists(*db, "operation", op_lonely));
    CHECK(!row_exists(*db, "account", lonely));
    CHECK(row_exists(*db, "account", referenced)); // на него ссылается живая операция
    CHECK(row_exists(*db, "operation", op_live));
    CHECK(row_exists(*db, "operation", op_unread)); // seq выше горизонта

    // purged_seq не уменьшается.
    sync_repo::purge_stream(*db, id.ledger_id, horizon - 1);
    CHECK_EQ(purged_seq(*db, id.ledger_id), horizon);
}

TEST(pull_after_purge_resets_lagging_cursor_with_reason_purged) {
    auto db = fixture::open();
    auto id = fixture::make_identity(*db);
    std::string icon = fixture::make_reference_icon(*db);
    std::string a = uuidgen::v4(), b = uuidgen::v4(), op = uuidgen::v4();
    int64_t first = push(*db, id.ledger_id, id.device_id,
                         {{"account", json::array({account_row(a, icon), account_row(b, icon)})},
                          {"operation", json::array({operation_row(op, a, b)})}});
    int64_t del = push(*db, id.ledger_id, id.device_id, {{"operation", json::array({deleted(operation_row(op, a, b))})}});
    sync_repo::purge_stream(*db, id.ledger_id, del);

    auto lagging = sync_repo::pull_ledger_stream(*db, id.ledger_id, first, 1000);
    CHECK(lagging.reset);
    CHECK_EQ(lagging.reset_reason, std::string("purged"));
    CHECK(!lagging.changes.contains("operation")); // вычищенная строка не отдаётся
    REQUIRE(lagging.changes.contains("account"));

    auto at_purged = sync_repo::pull_ledger_stream(*db, id.ledger_id, del, 1000);
    CHECK(!at_purged.reset);
    CHECK_EQ(at_purged.reset_reason, std::string(""));

    auto fresh = sync_repo::pull_ledger_stream(*db, id.ledger_id, 0, 1000);
    CHECK(!fresh.reset);
    CHECK(!fresh.changes.contains("operation"));

    // Курсор впереди головы — по-прежнему "ahead".
    auto ahead = sync_repo::pull_ledger_stream(*db, id.ledger_id, del + 100, 1000);
    CHECK(ahead.reset);
    CHECK_EQ(ahead.reset_reason, std::string("ahead"));
}

TEST(maybe_purge_runs_once_per_hour) {
    auto db = fixture::open();
    auto id = fixture::make_identity(*db);
    auto first = sync_repo::maybe_purge_stream(*db, id.ledger_id, 90);
    CHECK(first.has_value());
    CHECK(!sync_repo::maybe_purge_stream(*db, id.ledger_id, 90).has_value());
    db->exec("UPDATE change_stream SET purged_at = now() - interval '61 minutes' WHERE id = $1", {id.ledger_id});
    CHECK(sync_repo::maybe_purge_stream(*db, id.ledger_id, 90).has_value());
}

TEST(reference_purge_sql_deletes_unreferenced_shared_icon_only) {
    // В откатываемой транзакции — см. шапку файла, почему не purge_stream.
    auto db = fixture::open();
    auto id = fixture::make_identity(*db);
    std::string unused = fixture::make_reference_icon(*db);
    std::string used = fixture::make_reference_icon(*db);
    push(*db, id.ledger_id, id.device_id, {{"account", json::array({account_row(uuidgen::v4(), used)})}});
    auto bump = db->exec("UPDATE icon SET deleted_at = now(), seq = next_seq($1) WHERE uuid IN ($2, $3) "
                         "RETURNING seq",
                         {sync_repo::kReferenceStreamId, unused, used});
    int64_t horizon = 0;
    for (const auto& r : bump.rows) horizon = std::max<int64_t>(horizon, std::stoll(r.fields.at(0)));

    std::string icon_sql;
    for (const auto& st : sync_repo::build_purge_statements(/*ledger_stream=*/false)) {
        if (st.table == "icon") icon_sql = st.sql;
    }
    REQUIRE(!icon_sql.empty());
    bool unused_gone = false, used_gone = false;
    {
        auto tx = db->begin_transaction();
        auto res = tx.exec(icon_sql + " RETURNING uuid", {std::to_string(horizon)});
        for (const auto& r : res.rows) {
            if (r.fields.at(0) == unused) unused_gone = true;
            if (r.fields.at(0) == used) used_gone = true;
        }
        // без commit — ROLLBACK в деструкторе
    }
    CHECK(unused_gone);
    CHECK(!used_gone); // общую иконку держит счёт леджера
    CHECK(row_exists(*db, "icon", unused));
}

// --- Сквозной GET /sync/pull ------------------------------------------------

namespace {

uint64_t epoch_seconds() {
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count());
}

class PullServer {
public:
    template <typename Configure>
    explicit PullServer(Configure configure) {
        configure(server_);
        port_ = server_.bind_to_any_port("127.0.0.1");
        thread_ = std::thread([this] { server_.listen_after_bind(); });
        while (!server_.is_running()) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    ~PullServer() {
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

TEST(sync_pull_http_acks_purges_throttles_and_survives_purge_failure) {
    constexpr const char* kKid = "it-tombstone-kid";
    TestRsaKey key;
    std::string jwks_body = make_test_jwks(key, kKid);
    PullServer jwks_server([&](httplib::Server& s) {
        s.Get("/.well-known/jwks.json", [&](const httplib::Request&, httplib::Response& res) {
            res.set_content(jwks_body, "application/json");
        });
    });

    AppState state;
    state.jwks = std::make_unique<jwks::Cache>(jwks_server.base_url());
    state.db_pool = std::make_unique<db::Pool>(fixture::database_url(), 2);
    state.tombstone_purge = false;
    PullServer api([&](httplib::Server& s) { syncapi::register_routes(s, state); });
    httplib::Client client("127.0.0.1", api.port());

    std::string sub = uuidgen::v4();
    std::string device_id = uuidgen::v4();
    json claims = {{"sub", sub},
                   {"email", "it-tombstone@example.com"},
                   {"iss", "google-auth"},
                   {"aud", json::array({"wallet-api"})},
                   {"scope", "wallet:read wallet:write"},
                   {"device_id", device_id},
                   {"platform", "android"},
                   {"exp", epoch_seconds() + 900}};
    httplib::Headers auth{{"Authorization", "Bearer " + make_test_jwt(key, kKid, claims)}};
    // reference_seq всегда 0 — горизонт общего потока справочников тестовой
    // базы не сдвигается (см. шапку файла).
    auto pull = [&](int64_t ledger_seq, const std::string& ledger_id_param = "") {
        std::string path = "/sync/pull?reference_seq=0&limit=1000&ledger_seq=" + std::to_string(ledger_seq);
        if (!ledger_id_param.empty()) path += "&ledger_id=" + ledger_id_param;
        auto res = client.Get(path, auth);
        if (!res) throw std::runtime_error("no response");
        if (res->status != 200) throw std::runtime_error("status " + std::to_string(res->status) + ": " + res->body);
        return json::parse(res->body);
    };

    auto db = fixture::open();
    json first = pull(0);
    std::string ledger_id = first.at("ledger").at("ledger_id").get<std::string>();
    CHECK(!first.at("ledger").contains("reset_reason"));
    CHECK_EQ(device_field(*db, device_id, "last_ack_seq"), std::string("0"));
    CHECK_EQ(device_field(*db, device_id, "last_ack_reference_seq"), std::string("0"));

    std::string icon = fixture::make_reference_icon(*db);
    std::string a = uuidgen::v4(), b = uuidgen::v4(), op1 = uuidgen::v4(), op2 = uuidgen::v4();
    int64_t created = push(*db, ledger_id, device_id,
                           {{"account", json::array({account_row(a, icon), account_row(b, icon)})},
                            {"operation", json::array({operation_row(op1, a, b), operation_row(op2, a, b)})}});
    int64_t del1 = push(*db, ledger_id, device_id, {{"operation", json::array({deleted(operation_row(op1, a, b))})}});

    // Чистка выключена: подтверждение пишется, строки на месте, purged_seq 0.
    pull(del1, ledger_id);
    CHECK_EQ(device_field(*db, device_id, "last_ack_seq"), std::to_string(del1));
    CHECK(row_exists(*db, "operation", op1));
    CHECK_EQ(purged_seq(*db, ledger_id), int64_t{0});

    // Курсор от чужого леджера не подтверждает.
    pull(1, uuidgen::v4());
    CHECK_EQ(device_field(*db, device_id, "last_ack_seq"), std::to_string(del1));

    // Включили: pull с курсором del1 вычищает удалённую op1.
    state.tombstone_purge = true;
    pull(del1, ledger_id);
    CHECK(!row_exists(*db, "operation", op1));
    CHECK_EQ(purged_seq(*db, ledger_id), del1);

    // Отставший курсор — сброс "purged"; на purged_seq — без сброса.
    json lagging = pull(created, ledger_id);
    CHECK(lagging.at("ledger").at("reset").get<bool>());
    CHECK_EQ(lagging.at("ledger").at("reset_reason").get<std::string>(), std::string("purged"));
    // Сброс — устройство начинает с нуля, подтверждение 0.
    CHECK_EQ(device_field(*db, device_id, "last_ack_seq"), std::string("0"));
    json caught_up = pull(del1, ledger_id);
    CHECK(!caught_up.at("ledger").at("reset").get<bool>());
    CHECK(!caught_up.at("ledger").contains("reset_reason"));

    // Второй pull в течение часа не чистит.
    int64_t del2 = push(*db, ledger_id, device_id, {{"operation", json::array({deleted(operation_row(op2, a, b))})}});
    pull(del2, ledger_id);
    CHECK(row_exists(*db, "operation", op2));

    // Падение чистки (триггер на DELETE строк этого леджера) не ломает 200.
    std::string fn = "it_fail_purge_" + uuidgen::v4().substr(0, 8);
    db->exec("CREATE FUNCTION " + fn + "() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN "
             "IF OLD.ledger_id = '" + ledger_id + "' THEN RAISE EXCEPTION 'it: purge blocked'; END IF; "
             "RETURN OLD; END $$");
    db->exec("CREATE TRIGGER " + fn + " BEFORE DELETE ON operation FOR EACH ROW EXECUTE FUNCTION " + fn + "()");
    db->exec("UPDATE change_stream SET purged_at = NULL WHERE id = $1", {ledger_id});
    bool ok = true;
    try {
        json survived = pull(del2, ledger_id);
        CHECK(survived.at("ledger").contains("changes"));
    } catch (const std::exception&) {
        ok = false;
    }
    db->exec("DROP TRIGGER " + fn + " ON operation");
    db->exec("DROP FUNCTION " + fn + "()");
    CHECK(ok);
    CHECK(row_exists(*db, "operation", op2));
    CHECK_EQ(purged_seq(*db, ledger_id), del1); // транзакция чистки откатилась целиком
}
