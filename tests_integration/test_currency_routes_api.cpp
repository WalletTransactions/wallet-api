// REST маршрутов пересчёта валют (change currency-conversion-routes, спеки
// currency-routes-api и currency-pairs-api) против живого Postgres:
// currency_routes_repo — список, создание по пути из валют, удаление; каскад
// мягкого удаления пары на маршруты (currency_pairs_repo::delete_pair);
// доставка маршрута на устройство обычным pull; один сквозной HTTP-тест с
// настоящим гейтом scope (access.cpp) и хендлерами currency_routes.cpp.
//
// Данные заводятся прямым SQL (как в test_currency_routes.cpp). Каждый тест —
// свой леджер (fixture::make_identity), валюты — свои.
#include "currency_routes_repo.hpp"

#include <chrono>
#include <thread>

#include "../tests/test_rsa_helper.hpp"
#include "access.hpp"
#include "app_state.hpp"
#include "currency_pairs_repo.hpp"
#include "currency_routes.hpp"
#include "fixture.hpp"
#include "httplib.h"
#include "nlohmann/json.hpp"
#include "provisioning.hpp"
#include "sync.hpp"
#include "sync_repo.hpp"
#include "test_framework.hpp"
#include "util/jwks.hpp"
#include "util/uuid.hpp"

using nlohmann::json;
using currency_routes_repo::CreateRouteError;

namespace {

struct Ledger {
    std::shared_ptr<db::Database> db;
    std::string ledger_id;
    std::string icon;
};

Ledger ledger_of(std::shared_ptr<db::Database> db, const std::string& ledger_id) {
    Ledger l;
    l.db = std::move(db);
    l.ledger_id = ledger_id;
    l.icon = fixture::make_reference_icon(*l.db);
    return l;
}

Ledger make_ledger() {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    return ledger_of(db, identity.ledger_id);
}

std::string next_seq(Ledger& l) {
    return l.db->exec("SELECT next_seq($1)", {l.ledger_id}).rows.at(0).fields.at(0);
}

std::string add_currency(Ledger& l, const std::string& iso, const std::string& owner_ledger = "") {
    std::string uuid = uuidgen::v4();
    const std::string& owner = owner_ledger.empty() ? l.ledger_id : owner_ledger;
    std::string seq = l.db->exec("SELECT next_seq($1)", {owner}).rows.at(0).fields.at(0);
    l.db->exec("INSERT INTO currency (uuid, ledger_id, seq, name, iso_code, icon_uuid, symbol) "
               "VALUES ($1,$2,$3,$4,$5,$6,$7)",
               {uuid, owner, seq, iso + " " + uuid, iso, l.icon, iso});
    return uuid;
}

std::string add_pair(Ledger& l, const std::string& base, const std::string& quote) {
    std::string uuid = uuidgen::v4();
    l.db->exec("INSERT INTO currency_pair (uuid, ledger_id, seq, symbol, base_currency_uuid, quote_currency_uuid) "
               "VALUES ($1,$2,$3,$4,$5,$6)",
               {uuid, l.ledger_id, next_seq(l), "P " + uuid, base, quote});
    return uuid;
}

void add_rate(Ledger& l, const std::string& pair, const std::string& rate) {
    l.db->exec("INSERT INTO currency_pair_rate (uuid, ledger_id, seq, currency_pair_uuid, \"date\", rate) "
               "VALUES ($1,$2,$3,$4,'2026-11-01',$5)",
               {uuidgen::v4(), l.ledger_id, next_seq(l), pair, rate});
}

// BTC, EUR, RUB и пары BTCEUR, EURRUB.
struct Market {
    std::string btc, eur, rub, p_btceur, p_eurrub;
};

Market make_market(Ledger& l) {
    Market m;
    m.btc = add_currency(l, "BTC");
    m.eur = add_currency(l, "EUR");
    m.rub = add_currency(l, "RUB");
    m.p_btceur = add_pair(l, m.btc, m.eur);
    m.p_eurrub = add_pair(l, m.eur, m.rub);
    return m;
}

int live_steps(Ledger& l) {
    return std::stoi(l.db->exec("SELECT count(*) FROM currency_conversion WHERE ledger_id = $1 AND deleted_at IS NULL",
                                {l.ledger_id})
                         .rows.at(0)
                         .fields.at(0));
}

} // namespace

TEST(routes_api_create_writes_all_steps_with_one_seq_and_lists_them) {
    auto l = make_ledger();
    auto m = make_market(l);
    auto result = currency_routes_repo::create_route(*l.db, l.ledger_id, {m.btc, m.eur, m.rub});
    REQUIRE(result.error == CreateRouteError::kOk);
    CHECK_EQ(result.route.at("from").at("iso_code").get<std::string>(), std::string("BTC"));
    CHECK_EQ(result.route.at("to").at("iso_code").get<std::string>(), std::string("RUB"));
    CHECK_EQ(result.route.at("steps").size(), static_cast<size_t>(2));

    // Все шаги — одной группой (один seq), пустой updated_by, from/to одинаковы у всех.
    auto rows = l.db->exec("SELECT DISTINCT seq, from_currency_uuid, to_currency_uuid, updated_by IS NULL "
                           "FROM currency_conversion WHERE ledger_id = $1 AND deleted_at IS NULL",
                           {l.ledger_id});
    REQUIRE(rows.rows.size() == 1);
    CHECK_EQ(rows.rows.at(0).fields.at(1), m.btc);
    CHECK_EQ(rows.rows.at(0).fields.at(2), m.rub);
    CHECK_EQ(rows.rows.at(0).fields.at(3), std::string("t"));

    auto list = currency_routes_repo::list_routes(*l.db, l.ledger_id);
    REQUIRE(list.size() == 1);
    CHECK_EQ(list.at(0).at("from").at("uuid").get<std::string>(), m.btc);
    CHECK_EQ(list.at(0).at("to").at("uuid").get<std::string>(), m.rub);
    REQUIRE(list.at(0).at("path").size() == 3);
    CHECK_EQ(list.at(0).at("path").at(1).at("iso_code").get<std::string>(), std::string("EUR"));
    CHECK_EQ(list.at(0).at("steps").at(0).at("currency_pair_uuid").get<std::string>(), m.p_btceur);
    CHECK_EQ(list.at(0).at("steps").at(0).at("is_reverse").get<bool>(), false);
    CHECK_EQ(list.at(0).at("steps").at(1).at("currency_pair_uuid").get<std::string>(), m.p_eurrub);
}

TEST(routes_api_step_over_reversed_pair_is_written_reversed) {
    auto l = make_ledger();
    std::string btc = add_currency(l, "BTC"), eur = add_currency(l, "EUR"), rub = add_currency(l, "RUB");
    std::string p1 = add_pair(l, btc, eur);
    std::string p2 = add_pair(l, rub, eur); // RUBEUR — шаг EUR → RUB только по обратной паре
    auto result = currency_routes_repo::create_route(*l.db, l.ledger_id, {btc, eur, rub});
    REQUIRE(result.error == CreateRouteError::kOk);
    CHECK_EQ(result.route.at("steps").at(0).at("is_reverse").get<bool>(), false);
    CHECK_EQ(result.route.at("steps").at(1).at("is_reverse").get<bool>(), true);
    CHECK_EQ(result.route.at("steps").at(1).at("currency_pair_uuid").get<std::string>(), p2);
    (void)p1;
}

TEST(routes_api_prefers_forward_pair_when_both_directions_exist) {
    auto l = make_ledger();
    std::string btc = add_currency(l, "BTC"), eur = add_currency(l, "EUR"), rub = add_currency(l, "RUB");
    add_pair(l, btc, eur);
    std::string forward = add_pair(l, eur, rub);
    add_pair(l, rub, eur); // и обратная — не должна победить
    auto result = currency_routes_repo::create_route(*l.db, l.ledger_id, {btc, eur, rub});
    REQUIRE(result.error == CreateRouteError::kOk);
    CHECK_EQ(result.route.at("steps").at(1).at("currency_pair_uuid").get<std::string>(), forward);
    CHECK_EQ(result.route.at("steps").at(1).at("is_reverse").get<bool>(), false);
}

TEST(routes_api_create_rejects_missing_pair_naming_step_and_writes_nothing) {
    auto l = make_ledger();
    std::string btc = add_currency(l, "BTC"), eur = add_currency(l, "EUR"), rub = add_currency(l, "RUB");
    add_pair(l, btc, eur); // пары EUR/RUB нет
    auto result = currency_routes_repo::create_route(*l.db, l.ledger_id, {btc, eur, rub});
    CHECK(result.error == CreateRouteError::kNoPairForStep);
    CHECK(result.detail.find("EUR") != std::string::npos);
    CHECK(result.detail.find("RUB") != std::string::npos);
    CHECK_EQ(live_steps(l), 0);
}

TEST(routes_api_create_validates_path_length_and_repeats) {
    auto l = make_ledger();
    auto m = make_market(l);
    std::string gbp = add_currency(l, "GBP"), chf = add_currency(l, "CHF");
    CHECK(currency_routes_repo::create_route(*l.db, l.ledger_id, {m.btc, m.rub}).error == CreateRouteError::kBadLength);
    CHECK(currency_routes_repo::create_route(*l.db, l.ledger_id, {m.btc, m.eur, m.rub, gbp, chf}).error ==
          CreateRouteError::kBadLength);
    CHECK(currency_routes_repo::create_route(*l.db, l.ledger_id, {m.btc, m.eur, m.btc}).error ==
          CreateRouteError::kDuplicateCurrency);
    CHECK_EQ(live_steps(l), 0);
}

TEST(routes_api_create_treats_foreign_currency_as_not_found) {
    auto l = make_ledger();
    auto m = make_market(l);
    auto other = make_ledger();
    std::string foreign = add_currency(other, "XXX"); // приватная валюта чужого леджера
    auto result = currency_routes_repo::create_route(*l.db, l.ledger_id, {m.btc, m.eur, foreign});
    CHECK(result.error == CreateRouteError::kCurrencyNotFound);
    CHECK_EQ(live_steps(l), 0);
    auto unknown = currency_routes_repo::create_route(*l.db, l.ledger_id, {m.btc, m.eur, uuidgen::v4()});
    CHECK(unknown.error == CreateRouteError::kCurrencyNotFound);
}

TEST(routes_api_create_duplicate_and_reverse_duplicate_conflict) {
    auto l = make_ledger();
    auto m = make_market(l);
    // Обратный маршрут возможен только по обратным парам: заводим их, чтобы проверка шла именно по маршруту.
    add_pair(l, m.rub, m.eur);
    add_pair(l, m.eur, m.btc);
    REQUIRE(currency_routes_repo::create_route(*l.db, l.ledger_id, {m.btc, m.eur, m.rub}).error == CreateRouteError::kOk);
    CHECK(currency_routes_repo::create_route(*l.db, l.ledger_id, {m.btc, m.eur, m.rub}).error ==
          CreateRouteError::kAlreadyExists);
    CHECK(currency_routes_repo::create_route(*l.db, l.ledger_id, {m.rub, m.eur, m.btc}).error ==
          CreateRouteError::kAlreadyExists);
    CHECK_EQ(live_steps(l), 2);
}

TEST(routes_api_delete_then_create_again_has_no_duplicate) {
    auto l = make_ledger();
    auto m = make_market(l);
    REQUIRE(currency_routes_repo::create_route(*l.db, l.ledger_id, {m.btc, m.eur, m.rub}).error == CreateRouteError::kOk);
    CHECK(currency_routes_repo::delete_route(*l.db, l.ledger_id, m.btc, m.rub));
    CHECK_EQ(live_steps(l), 0);
    CHECK_EQ(currency_routes_repo::list_routes(*l.db, l.ledger_id).size(), static_cast<size_t>(0));
    // Все шаги погашены одним seq и остались tombstone'ами.
    auto tomb = l.db->exec("SELECT count(DISTINCT seq), count(*) FROM currency_conversion "
                           "WHERE ledger_id = $1 AND deleted_at IS NOT NULL",
                           {l.ledger_id});
    CHECK_EQ(tomb.rows.at(0).fields.at(1), std::string("2"));
    // Курсы и пары шагов не тронуты.
    CHECK_EQ(l.db->exec("SELECT count(*) FROM currency_pair WHERE ledger_id = $1 AND deleted_at IS NULL", {l.ledger_id})
                 .rows.at(0)
                 .fields.at(0),
             std::string("2"));
    // Повторное создание — снова успех.
    CHECK(currency_routes_repo::create_route(*l.db, l.ledger_id, {m.btc, m.eur, m.rub}).error == CreateRouteError::kOk);
    CHECK_EQ(live_steps(l), 2);
}

TEST(routes_api_delete_of_foreign_or_unknown_route_is_not_found) {
    auto l = make_ledger();
    auto m = make_market(l);
    REQUIRE(currency_routes_repo::create_route(*l.db, l.ledger_id, {m.btc, m.eur, m.rub}).error == CreateRouteError::kOk);
    auto other = make_ledger();
    // Тот же (from, to), но чужой леджер: маршрут неотличим от несуществующего и не тронут.
    CHECK(!currency_routes_repo::delete_route(*other.db, other.ledger_id, m.btc, m.rub));
    CHECK(!currency_routes_repo::delete_route(*l.db, l.ledger_id, m.btc, m.eur));
    CHECK_EQ(live_steps(l), 2);
    CHECK_EQ(currency_routes_repo::list_routes(*other.db, other.ledger_id).size(), static_cast<size_t>(0));
}

TEST(routes_api_list_hides_unfinished_and_broken_routes_and_create_replaces_broken) {
    auto l = make_ledger();
    auto m = make_market(l);
    // Недостроенная цепочка (как после обрыва синка): только шаг 1.
    l.db->exec("INSERT INTO currency_conversion (uuid, ledger_id, seq, from_currency_uuid, to_currency_uuid, num, "
               "currency_pair_uuid, is_reverse) VALUES ($1,$2,$3,$4,$5,1,$6,false)",
               {uuidgen::v4(), l.ledger_id, next_seq(l), m.btc, m.rub, m.p_btceur});
    CHECK_EQ(currency_routes_repo::list_routes(*l.db, l.ledger_id).size(), static_cast<size_t>(0));
    // Оборванный маршрут не блокирует создание заново: его шаги гасятся той же группой.
    auto created = currency_routes_repo::create_route(*l.db, l.ledger_id, {m.btc, m.eur, m.rub});
    CHECK(created.error == CreateRouteError::kOk);
    CHECK_EQ(live_steps(l), 2);
    CHECK_EQ(currency_routes_repo::list_routes(*l.db, l.ledger_id).size(), static_cast<size_t>(1));
}

TEST(routes_api_route_created_on_web_arrives_on_phone_with_one_seq) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    auto l = ledger_of(db, identity.ledger_id);
    auto m = make_market(l);
    int64_t cursor = std::stoll(
        db->exec("SELECT seq FROM change_stream WHERE id = $1", {identity.ledger_id}).rows.at(0).fields.at(0));

    REQUIRE(currency_routes_repo::create_route(*db, identity.ledger_id, {m.btc, m.eur, m.rub}).error ==
            CreateRouteError::kOk);
    auto pulled = sync_repo::pull_ledger_stream(*db, identity.ledger_id, cursor, 1000);
    REQUIRE(pulled.changes.contains("currency_conversion"));
    const auto& steps = pulled.changes.at("currency_conversion");
    REQUIRE(steps.size() == 2);
    CHECK_EQ(steps.at(0).at("seq").get<int64_t>(), steps.at(1).at("seq").get<int64_t>());
    CHECK_EQ(steps.at(0).at("seq").get<int64_t>(), cursor + 1);

    // Удаление едет тем же путём: два tombstone'а одним новым seq.
    int64_t after_create = pulled.next_seq;
    REQUIRE(currency_routes_repo::delete_route(*db, identity.ledger_id, m.btc, m.rub));
    auto deleted = sync_repo::pull_ledger_stream(*db, identity.ledger_id, after_create, 1000);
    REQUIRE(deleted.changes.contains("currency_conversion"));
    const auto& tombs = deleted.changes.at("currency_conversion");
    REQUIRE(tombs.size() == 2);
    CHECK(!tombs.at(0).at("deleted_at").is_null());
    CHECK_EQ(tombs.at(0).at("seq").get<int64_t>(), tombs.at(1).at("seq").get<int64_t>());
}

// ---- Каскад удаления пары (5.1) ----

TEST(routes_api_deleting_pair_tombstones_whole_route_with_the_same_seq) {
    auto l = make_ledger();
    auto m = make_market(l);
    REQUIRE(currency_routes_repo::create_route(*l.db, l.ledger_id, {m.btc, m.eur, m.rub}).error == CreateRouteError::kOk);
    REQUIRE(currency_pairs_repo::delete_pair(*l.db, l.ledger_id, m.p_eurrub));

    CHECK_EQ(live_steps(l), 0); // и шаг пары EURRUB, и шаг BTCEUR того же маршрута
    CHECK_EQ(currency_routes_repo::list_routes(*l.db, l.ledger_id).size(), static_cast<size_t>(0));
    auto seqs = l.db->exec("SELECT (SELECT seq FROM currency_pair WHERE uuid = $2), "
                           "       count(DISTINCT seq) FILTER (WHERE true), min(seq) "
                           "FROM currency_conversion WHERE ledger_id = $1",
                           {l.ledger_id, m.p_eurrub});
    CHECK_EQ(seqs.rows.at(0).fields.at(1), std::string("1"));
    CHECK_EQ(seqs.rows.at(0).fields.at(0), seqs.rows.at(0).fields.at(2)); // тот же seq, что у самой пары
}

TEST(routes_api_deleting_pair_outside_routes_leaves_routes_untouched) {
    auto l = make_ledger();
    auto m = make_market(l);
    std::string unrelated = add_pair(l, m.btc, m.rub);
    // Прямая пара BTCRUB существует — но маршрут от неё независим; создаём маршрут и удаляем её.
    REQUIRE(currency_routes_repo::create_route(*l.db, l.ledger_id, {m.btc, m.eur, m.rub}).error == CreateRouteError::kOk);
    REQUIRE(currency_pairs_repo::delete_pair(*l.db, l.ledger_id, unrelated));
    CHECK_EQ(live_steps(l), 2);
    CHECK_EQ(currency_routes_repo::list_routes(*l.db, l.ledger_id).size(), static_cast<size_t>(1));
}

TEST(routes_api_deleting_foreign_or_shared_pair_does_not_touch_routes) {
    auto l = make_ledger();
    auto m = make_market(l);
    REQUIRE(currency_routes_repo::create_route(*l.db, l.ledger_id, {m.btc, m.eur, m.rub}).error == CreateRouteError::kOk);
    auto other = make_ledger();
    // Чужой леджер не может удалить пару этого — 404 (false), маршрут цел.
    CHECK(!currency_pairs_repo::delete_pair(*other.db, other.ledger_id, m.p_eurrub));
    CHECK_EQ(live_steps(l), 2);
}

// ---- HTTP-слой ----

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

// Сквозной путь, как в проде (main.cpp): гейт scope в pre-routing, сессия без
// device_id. Новый пользователь видит пустой список и леджер не создаётся;
// создание заводит леджер; коды 201/400/404/409/204; токен только на чтение — 403.
TEST(routes_api_http_roundtrip_with_scope_gate) {
    constexpr const char* kKid = "it-currency-routes-kid";
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
        currency_routes_api::register_routes(s, state);
    });
    httplib::Client client("127.0.0.1", api.port());

    auto db = fixture::open();
    std::string sub = uuidgen::v4();
    auto token = [&](const std::string& scope) {
        json claims = {{"sub", sub},
                       {"email", "it-routes@example.com"},
                       {"iss", "google-auth"},
                       {"aud", json::array({"wallet-api", "wallet-report", "google-auth"})},
                       {"scope", scope},
                       {"exp", epoch_now() + 900}};
        return httplib::Headers{{"Authorization", "Bearer " + make_test_jwt(key, kKid, claims)}};
    };
    auto rw = token("wallet:read wallet:write");
    auto ro = token("wallet:read");

    auto ledgers = [&] {
        return db->exec("SELECT count(*) FROM ledger_member WHERE user_id = $1", {sub}).rows.at(0).fields.at(0);
    };

    // Новый пользователь: пустой список, леджер не создан.
    auto empty = client.Get("/api/currency-routes", rw);
    REQUIRE(empty);
    CHECK_EQ(empty->status, 200);
    CHECK_EQ(json::parse(empty->body).at("routes").size(), static_cast<size_t>(0));
    CHECK_EQ(ledgers(), std::string("0"));
    // Без токена — 401; DELETE без леджера — 404.
    auto anonymous = client.Get("/api/currency-routes");
    REQUIRE(anonymous);
    CHECK_EQ(anonymous->status, 401);
    auto no_ledger = client.Delete(("/api/currency-routes/" + uuidgen::v4() + "/" + uuidgen::v4()).c_str(), rw);
    REQUIRE(no_ledger);
    CHECK_EQ(no_ledger->status, 404);

    // Леджер пользователя и рынок — прямым SQL (валюты и пары заводятся своими ручками).
    std::string ledger_id = provisioning::ensure_personal_ledger(*db, sub, "it-routes@example.com");
    auto l = ledger_of(db, ledger_id);
    auto m = make_market(l);

    json body = {{"currency_uuids", json::array({m.btc, m.eur, m.rub})}};

    // Токен только на чтение — 403 гейта, ничего не создано.
    auto forbidden = client.Post("/api/currency-routes", ro, body.dump(), "application/json");
    REQUIRE(forbidden);
    CHECK_EQ(forbidden->status, 403);
    CHECK_EQ(live_steps(l), 0);

    auto created = client.Post("/api/currency-routes", rw, body.dump(), "application/json");
    REQUIRE(created);
    CHECK_EQ(created->status, 201);
    CHECK_EQ(json::parse(created->body).at("steps").size(), static_cast<size_t>(2));
    CHECK_EQ(live_steps(l), 2);

    auto list = client.Get("/api/currency-routes", ro);
    REQUIRE(list);
    CHECK_EQ(list->status, 200);
    CHECK_EQ(json::parse(list->body).at("routes").size(), static_cast<size_t>(1));

    // Дубль и обратный дубль — 409.
    auto dup = client.Post("/api/currency-routes", rw, body.dump(), "application/json");
    REQUIRE(dup);
    CHECK_EQ(dup->status, 409);

    // Ошибки ввода — 400: короткий путь, повтор валюты, не uuid, не JSON, нет пары для шага.
    for (const json& bad : {json{{"currency_uuids", json::array({m.btc, m.rub})}},
                            json{{"currency_uuids", json::array({m.btc, m.eur, m.btc})}},
                            json{{"currency_uuids", json::array({"not-a-uuid", m.eur, m.rub})}},
                            json{{"currency_uuids", json::array({m.rub, m.btc, m.eur})}},
                            json{{"nothing", 1}}}) {
        auto r = client.Post("/api/currency-routes", rw, bad.dump(), "application/json");
        REQUIRE(r);
        CHECK_EQ(r->status, 400);
    }
    auto not_json = client.Post("/api/currency-routes", rw, "{oops", "application/json");
    REQUIRE(not_json);
    CHECK_EQ(not_json->status, 400);

    // Чужой маршрут и мусор в пути — 404; свой — 204, и снова можно создать.
    auto stranger = client.Delete(("/api/currency-routes/" + uuidgen::v4() + "/" + m.rub).c_str(), rw);
    REQUIRE(stranger);
    CHECK_EQ(stranger->status, 404);
    auto garbage = client.Delete("/api/currency-routes/x/y", rw);
    REQUIRE(garbage);
    CHECK_EQ(garbage->status, 404);
    auto removed = client.Delete(("/api/currency-routes/" + m.btc + "/" + m.rub).c_str(), rw);
    REQUIRE(removed);
    CHECK_EQ(removed->status, 204);
    CHECK_EQ(live_steps(l), 0);
    auto again = client.Post("/api/currency-routes", rw, body.dump(), "application/json");
    REQUIRE(again);
    CHECK_EQ(again->status, 201);
}

// Читатель общего леджера (ledger_member.role = 'reader') не пишет, хотя у его
// токена wallet:write: REST маршрутов — 403 reader_cannot_write, /sync/push со
// строками — тоже 403 и ничего не применено; холостой push без строк проходит.
TEST(reader_of_shared_ledger_cannot_write_via_rest_or_push) {
    constexpr const char* kKid = "it-reader-write-kid";
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
        currency_routes_api::register_routes(s, state);
        syncapi::register_routes(s, state);
    });
    httplib::Client client("127.0.0.1", api.port());

    auto db = fixture::open();
    std::string owner_sub = uuidgen::v4();
    std::string ledger_id = provisioning::ensure_personal_ledger(*db, owner_sub, "it-owner@example.com");
    auto l = ledger_of(db, ledger_id);
    auto m = make_market(l);

    std::string reader_sub = uuidgen::v4();
    db->exec("INSERT INTO app_user (id, email) VALUES ($1, $2)", {reader_sub, "it-reader@example.com"});
    db->exec("INSERT INTO ledger_member (ledger_id, user_id, role) VALUES ($1, $2, 'reader')", {ledger_id, reader_sub});

    auto token = [&](const std::string& sub, const std::string& device_id) {
        json claims = {{"sub", sub},
                       {"email", sub + "@example.com"},
                       {"iss", "google-auth"},
                       {"aud", json::array({"wallet-api", "wallet-report", "google-auth"})},
                       {"scope", "wallet:read wallet:write"},
                       {"exp", epoch_now() + 900}};
        if (!device_id.empty()) {
            claims["device_id"] = device_id;
            claims["platform"] = "android";
        }
        return httplib::Headers{{"Authorization", "Bearer " + make_test_jwt(key, kKid, claims)}};
    };
    auto reader_web = token(reader_sub, "");
    auto reader_phone = token(reader_sub, uuidgen::v4());
    auto owner_web = token(owner_sub, "");

    // REST: создать маршрут читатель не может, владелец — может; удалить его читатель тоже не может.
    json body = {{"currency_uuids", json::array({m.btc, m.eur, m.rub})}};
    auto forbidden = client.Post("/api/currency-routes", reader_web, body.dump(), "application/json");
    REQUIRE(forbidden);
    CHECK_EQ(forbidden->status, 403);
    CHECK_EQ(json::parse(forbidden->body).at("error").get<std::string>(), std::string("reader_cannot_write"));
    CHECK_EQ(live_steps(l), 0);

    auto created = client.Post("/api/currency-routes", owner_web, body.dump(), "application/json");
    REQUIRE(created);
    CHECK_EQ(created->status, 201);
    auto reader_delete = client.Delete(("/api/currency-routes/" + m.btc + "/" + m.rub).c_str(), reader_web);
    REQUIRE(reader_delete);
    CHECK_EQ(reader_delete->status, 403);
    CHECK_EQ(live_steps(l), 2);

    // Чтение читателю доступно.
    auto list = client.Get("/api/currency-routes", reader_web);
    REQUIRE(list);
    CHECK_EQ(list->status, 200);

    // /sync/push с телефона читателя: строка удаления пары — 403, пара жива.
    json push = {{"batch_id", uuidgen::v4()},
                 {"changes", {{"currency_pair", json::array({{{"uuid", m.p_btceur}, {"deleted", true}}})}}}};
    auto pushed = client.Post("/sync/push", reader_phone, push.dump(), "application/json");
    REQUIRE(pushed);
    CHECK_EQ(pushed->status, 403);
    CHECK_EQ(json::parse(pushed->body).at("error").get<std::string>(), std::string("reader_cannot_write"));
    CHECK_EQ(db->exec("SELECT count(*) FROM currency_pair WHERE uuid = $1 AND deleted_at IS NULL", {m.p_btceur})
                 .rows.at(0)
                 .fields.at(0),
             std::string("1"));

    // Холостой push без строк — не запись, проходит.
    json idle = {{"batch_id", uuidgen::v4()}, {"changes", {{"operation", json::array()}}}};
    auto idle_res = client.Post("/sync/push", reader_phone, idle.dump(), "application/json");
    REQUIRE(idle_res);
    CHECK_EQ(idle_res->status, 200);
}
