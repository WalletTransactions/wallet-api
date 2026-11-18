// Шаги маршрутов пересчёта (change currency-conversion-routes) в протоколе
// синка: sync_repo::push_batch()/pull_ledger_stream() против живого Postgres —
// построчная валидация (400 invalid_row), ссылки (409 missing_reference),
// уникальность (409 duplicate_key), порядок применения и pull.
//
// Валюты и пары заводятся самим push (как это делает клиент), а не прямым SQL:
// проверяется именно протокол. Каждый тест — свой леджер (fixture::make_identity).
#include "sync_repo.hpp"

#include <string>

#include "fixture.hpp"
#include "nlohmann/json.hpp"
#include "test_framework.hpp"
#include "util/uuid.hpp"

using nlohmann::json;

namespace {

struct Route {
    std::shared_ptr<db::Database> db;
    fixture::TestIdentity identity;
    std::string icon;
    std::string btc, eur, rub;       // валюты
    std::string p1, p2;              // BTCEUR, EURRUB
};

json currency_row(const std::string& uuid, const std::string& icon, const std::string& iso) {
    return json{{"uuid", uuid}, {"name", iso}, {"iso_code", iso},
                {"icon_uuid", icon}, {"symbol", iso}, {"precision", 2}};
}

json pair_row(const std::string& uuid, const std::string& base, const std::string& quote,
              const std::string& symbol) {
    return json{{"uuid", uuid}, {"symbol", symbol}, {"base_currency_uuid", base},
                {"quote_currency_uuid", quote}, {"precision", 5}};
}

json step_row(const std::string& from, const std::string& to, json num, const std::string& pair,
              bool is_reverse = false) {
    return json{{"uuid", uuidgen::v4()}, {"from_currency_uuid", from}, {"to_currency_uuid", to},
                {"num", std::move(num)}, {"currency_pair_uuid", pair}, {"is_reverse", is_reverse}};
}

sync_repo::PushOutcome push(Route& r, const json& changes) {
    return sync_repo::push_batch(*r.db, r.identity.ledger_id, r.identity.device_id, uuidgen::v4(), changes);
}

// Валюты и две пары уже на сервере; шаги — каждый тест свои.
Route make_route() {
    Route r;
    r.db = fixture::open();
    r.identity = fixture::make_identity(*r.db);
    r.icon = fixture::make_reference_icon(*r.db);
    r.btc = uuidgen::v4();
    r.eur = uuidgen::v4();
    r.rub = uuidgen::v4();
    r.p1 = uuidgen::v4();
    r.p2 = uuidgen::v4();
    json setup = {
        {"currency", json::array({currency_row(r.btc, r.icon, "BTC"), currency_row(r.eur, r.icon, "EUR"),
                                   currency_row(r.rub, r.icon, "RUB")})},
        {"currency_pair", json::array({pair_row(r.p1, r.btc, r.eur, "BTCEUR"), pair_row(r.p2, r.eur, r.rub, "EURRUB")})},
    };
    auto out = push(r, setup);
    REQUIRE(out.http_status == 200);
    return r;
}

int live_steps(Route& r) {
    auto res = r.db->exec("SELECT count(*) FROM currency_conversion WHERE ledger_id = $1 AND deleted_at IS NULL",
                          {r.identity.ledger_id});
    return std::stoi(res.rows.at(0).fields.at(0));
}

json body_of(const sync_repo::PushOutcome& out) {
    return json::parse(out.response_body);
}

} // namespace

TEST(route_push_rejects_num_outside_range_and_applies_nothing) {
    auto r = make_route();
    for (int bad : {0, 4}) {
        auto out = push(r, {{"currency_conversion", json::array({step_row(r.btc, r.rub, bad, r.p1)})}});
        CHECK_EQ(out.http_status, 400);
        auto body = body_of(out);
        CHECK_EQ(body.value("error", ""), std::string("invalid_row"));
        CHECK(body.value("detail", "").find("num") != std::string::npos);
    }
    CHECK_EQ(live_steps(r), 0);
}

TEST(route_push_rejects_same_from_and_to_currency) {
    auto r = make_route();
    auto out = push(r, {{"currency_conversion", json::array({step_row(r.btc, r.btc, 1, r.p1)})}});
    CHECK_EQ(out.http_status, 400);
    CHECK_EQ(body_of(out).value("error", ""), std::string("invalid_row"));
    CHECK_EQ(live_steps(r), 0);
}

TEST(route_push_missing_pair_is_409_and_resend_with_pair_passes) {
    auto r = make_route();
    std::string unknown_pair = uuidgen::v4();
    auto bad = push(r, {{"currency_conversion", json::array({step_row(r.btc, r.rub, 1, unknown_pair)})}});
    CHECK_EQ(bad.http_status, 409);
    auto body = body_of(bad);
    CHECK_EQ(body.value("error", ""), std::string("missing_reference"));
    CHECK_EQ(body.value("table", ""), std::string("currency_pair"));
    CHECK_EQ(body.value("uuid", ""), unknown_pair);
    CHECK_EQ(live_steps(r), 0);

    // Клиент досылает именно названную пару вместе с шагом — батч проходит.
    json fixed = {{"currency_pair", json::array({pair_row(unknown_pair, r.btc, r.rub, "BTCRUB")})},
                  {"currency_conversion", json::array({step_row(r.btc, r.rub, 1, unknown_pair)})}};
    CHECK_EQ(push(r, fixed).http_status, 200);
    CHECK_EQ(live_steps(r), 1);
}

TEST(route_push_new_pair_and_step_in_one_batch_applies_in_dependency_order) {
    auto r = make_route();
    std::string gbp = uuidgen::v4();
    std::string pair = uuidgen::v4();
    // Новая валюта, новая пара и шаг одним батчем: порядок применения — currency, currency_pair, currency_conversion.
    json changes = {{"currency_conversion", json::array({step_row(r.btc, gbp, 1, pair)})},
                    {"currency_pair", json::array({pair_row(pair, r.btc, gbp, "BTCGBP")})},
                    {"currency", json::array({currency_row(gbp, r.icon, "GBP")})}};
    CHECK_EQ(push(r, changes).http_status, 200);
    CHECK_EQ(live_steps(r), 1);
}

TEST(route_push_reverse_route_is_duplicate_key) {
    auto r = make_route();
    CHECK_EQ(push(r, {{"currency_conversion", json::array({step_row(r.btc, r.rub, 1, r.p1)})}}).http_status, 200);
    // Шаг 1 маршрута RUB → BTC при живом шаге 1 маршрута BTC → RUB.
    auto out = push(r, {{"currency_conversion", json::array({step_row(r.rub, r.btc, 1, r.p1, true)})}});
    CHECK_EQ(out.http_status, 409);
    CHECK_EQ(body_of(out).value("error", ""), std::string("duplicate_key"));
    CHECK_EQ(live_steps(r), 1);
}

TEST(route_push_steps_in_separate_batches_and_pull_returns_them) {
    auto r = make_route();
    json s1 = step_row(r.btc, r.rub, 1, r.p1);
    json s2 = step_row(r.btc, r.rub, 2, r.p2);
    // Первый батч — недостроенная цепочка: проходит, целостность при push не проверяется.
    CHECK_EQ(push(r, {{"currency_conversion", json::array({s1})}}).http_status, 200);
    CHECK_EQ(push(r, {{"currency_conversion", json::array({s2})}}).http_status, 200);

    auto pulled = sync_repo::pull_ledger_stream(*r.db, r.identity.ledger_id, 0, 1000);
    REQUIRE(pulled.changes.contains("currency_conversion"));
    const auto& rows = pulled.changes.at("currency_conversion");
    REQUIRE(rows.size() == 2);
    int seen_nums = 0;
    for (const auto& row : rows) {
        seen_nums += row.at("num").get<int>();
        CHECK_EQ(row.at("from_currency_uuid").get<std::string>(), r.btc);
        CHECK_EQ(row.at("to_currency_uuid").get<std::string>(), r.rub);
        CHECK(row.contains("currency_pair_uuid"));
        CHECK(row.contains("is_reverse"));
    }
    CHECK_EQ(seen_nums, 3); // шаги 1 и 2

    // Курс по достроенной цепочке появляется сразу после второго батча.
    r.db->exec("INSERT INTO currency_pair_rate (uuid, ledger_id, seq, currency_pair_uuid, \"date\", rate) "
               "VALUES ($1,$2,next_seq($2),$3,'2026-11-01', 90000), ($4,$2,next_seq($2),$5,'2026-11-01', 100)",
               {uuidgen::v4(), r.identity.ledger_id, r.p1, uuidgen::v4(), r.p2});
    auto rate = r.db->exec("SELECT rate::text FROM rate_on($1, $2, $3, '2026-11-05')",
                           {r.identity.ledger_id, r.btc, r.rub});
    REQUIRE(rate.rows.size() == 1);
    CHECK_EQ(std::stod(rate.rows.at(0).fields.at(0)), 9000000.0);
}

TEST(route_step_is_not_in_the_reference_stream) {
    auto r = make_route();
    CHECK_EQ(push(r, {{"currency_conversion", json::array({step_row(r.btc, r.rub, 1, r.p1)})}}).http_status, 200);
    // Маршруты принадлежат леджеру: в общем потоке справочников их нет.
    auto reference = sync_repo::pull_reference_stream(*r.db, 0, 100000);
    if (reference.changes.contains("currency_conversion")) {
        CHECK_EQ(reference.changes.at("currency_conversion").size(), static_cast<size_t>(0));
    }
}
