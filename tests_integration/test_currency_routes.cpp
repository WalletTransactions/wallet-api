// Маршруты пересчёта валют (change currency-conversion-routes, миграция 000043)
// против живого Postgres: ограничения currency_conversion и курс rate_on —
// явные маршруты, приоритет прямой пары,
// кросс через USD.
//
// Данные заводятся прямым SQL (как fixture::make_currency), не push_batch: здесь
// проверяются таблица и вьюха, а не протокол синка. Каждый тест — свой леджер
// (fixture::make_identity) со СВОИМИ валютами; «USD» хаба — собственная валюта
// леджера с iso_code = 'USD' (своя перекрывает общую), чтобы тест не зависел от
// общих валют базы.
#include <cmath>
#include <optional>
#include <string>

#include "fixture.hpp"
#include "test_framework.hpp"
#include "util/uuid.hpp"

namespace {

struct Ledger {
    std::shared_ptr<db::Database> db;
    fixture::TestIdentity identity;
    std::string icon;
};

Ledger make_ledger() {
    Ledger l;
    l.db = fixture::open();
    l.identity = fixture::make_identity(*l.db);
    l.icon = fixture::make_reference_icon(*l.db);
    return l;
}

std::string next_seq(Ledger& l) {
    return l.db->exec("SELECT next_seq($1)", {l.identity.ledger_id}).rows.at(0).fields.at(0);
}

// Своя валюта леджера с заданным iso_code (name — с uuid: уникален по леджеру).
std::string add_currency(Ledger& l, const std::string& iso) {
    std::string uuid = uuidgen::v4();
    l.db->exec("INSERT INTO currency (uuid, ledger_id, seq, name, iso_code, icon_uuid, symbol) "
               "VALUES ($1,$2,$3,$4,$5,$6,$7)",
               {uuid, l.identity.ledger_id, next_seq(l), iso + " " + uuid, iso, l.icon, iso});
    return uuid;
}

std::string add_pair(Ledger& l, const std::string& base, const std::string& quote) {
    std::string uuid = uuidgen::v4();
    l.db->exec("INSERT INTO currency_pair (uuid, ledger_id, seq, symbol, base_currency_uuid, quote_currency_uuid) "
               "VALUES ($1,$2,$3,$4,$5,$6)",
               {uuid, l.identity.ledger_id, next_seq(l), "P " + uuid, base, quote});
    return uuid;
}

void add_rate(Ledger& l, const std::string& pair, const std::string& date, const std::string& rate) {
    l.db->exec("INSERT INTO currency_pair_rate (uuid, ledger_id, seq, currency_pair_uuid, \"date\", rate) "
               "VALUES ($1,$2,$3,$4,$5,$6)",
               {uuidgen::v4(), l.identity.ledger_id, next_seq(l), pair, date, rate});
}

// Шаг маршрута from -> to: номер, пара, направление.
std::string add_step(Ledger& l, const std::string& from, const std::string& to, int num,
                     const std::string& pair, bool is_reverse) {
    std::string uuid = uuidgen::v4();
    l.db->exec("INSERT INTO currency_conversion "
               "(uuid, ledger_id, seq, from_currency_uuid, to_currency_uuid, num, currency_pair_uuid, is_reverse) "
               "VALUES ($1,$2,$3,$4,$5,$6,$7,$8)",
               {uuid, l.identity.ledger_id, next_seq(l), from, to, std::to_string(num), pair,
                is_reverse ? "t" : "f"});
    return uuid;
}

// Курс from -> to леджера на дату через SQL-функцию rate_on — ту самую, которой
// пользуются отчётные функции: прямой курс, иначе явный маршрут, иначе кросс через USD.
std::optional<double> rate_on(Ledger& l, const std::string& from, const std::string& to,
                              const std::string& date) {
    auto res = l.db->exec("SELECT rate::text FROM rate_on($1, $2, $3, $4::date)",
                          {l.identity.ledger_id, from, to, date});
    if (res.rows.empty()) return std::nullopt;
    return std::stod(res.rows.at(0).fields.at(0));
}

// Число курсов, которые rate_on отдаёт на далёкую дату (0 или 1: функция возвращает не больше одной строки).
int count_rows(Ledger& l, const std::string& from, const std::string& to) {
    auto res = l.db->exec("SELECT count(*) FROM rate_on($1, $2, $3, '2099-01-01')",
                          {l.identity.ledger_id, from, to});
    return std::stoi(res.rows.at(0).fields.at(0));
}

bool near(const std::optional<double>& got, double want) {
    if (!got) return false;
    return std::fabs(*got - want) <= std::fabs(want) * 1e-9;
}

std::string sqlstate_of(Ledger& l, const std::string& sql, const std::vector<std::string>& params) {
    try {
        l.db->exec(sql, params);
    } catch (const db::QueryError& e) {
        return e.sqlstate;
    }
    return "";
}

const char* kInsertStep =
    "INSERT INTO currency_conversion "
    "(uuid, ledger_id, seq, from_currency_uuid, to_currency_uuid, num, currency_pair_uuid) "
    "VALUES ($1,$2,$3,$4,$5,$6,$7)";

} // namespace

// ---- Ограничения таблицы (1.4) ----

TEST(routes_table_rejects_num_outside_1_to_3) {
    auto l = make_ledger();
    std::string a = add_currency(l, "AAA"), b = add_currency(l, "BBB");
    std::string p = add_pair(l, a, b);
    for (const char* bad : {"0", "4"}) {
        CHECK_EQ(sqlstate_of(l, kInsertStep, {uuidgen::v4(), l.identity.ledger_id, next_seq(l), a, b, bad, p}),
                 std::string("23514")); // check_violation
    }
    for (const char* good : {"1", "2", "3"}) {
        // Разные (from, to) — чтобы не упереться в уникальность, нужен только диапазон;
        // iso_code уникален по леджеру, поэтому свой на каждый проход.
        std::string x = add_currency(l, std::string("X") + good), y = add_currency(l, std::string("Y") + good);
        std::string pp = add_pair(l, x, y);
        CHECK_EQ(sqlstate_of(l, kInsertStep, {uuidgen::v4(), l.identity.ledger_id, next_seq(l), x, y, good, pp}),
                 std::string(""));
    }
}

TEST(routes_table_rejects_duplicate_step_and_reverse_duplicate) {
    auto l = make_ledger();
    std::string a = add_currency(l, "AAA"), b = add_currency(l, "BBB");
    std::string p = add_pair(l, a, b);
    add_step(l, a, b, 1, p, false);
    // Тот же шаг маршрута — нарушение уникальности.
    CHECK_EQ(sqlstate_of(l, kInsertStep, {uuidgen::v4(), l.identity.ledger_id, next_seq(l), a, b, "1", p}),
             std::string("23505"));
    // Маршрут в обратную сторону на той же неупорядоченной паре — тоже.
    CHECK_EQ(sqlstate_of(l, kInsertStep, {uuidgen::v4(), l.identity.ledger_id, next_seq(l), b, a, "1", p}),
             std::string("23505"));
}

TEST(routes_table_allows_recreating_route_after_soft_delete) {
    auto l = make_ledger();
    std::string a = add_currency(l, "AAA"), b = add_currency(l, "BBB");
    std::string p = add_pair(l, a, b);
    std::string step = add_step(l, a, b, 1, p, false);
    l.db->exec("UPDATE currency_conversion SET deleted_at = now() WHERE uuid = $1", {step});
    CHECK_EQ(sqlstate_of(l, kInsertStep, {uuidgen::v4(), l.identity.ledger_id, next_seq(l), b, a, "1", p}),
             std::string(""));
}

TEST(routes_table_rejects_missing_ledger_and_same_currency) {
    auto l = make_ledger();
    std::string a = add_currency(l, "AAA"), b = add_currency(l, "BBB");
    std::string p = add_pair(l, a, b);
    CHECK_EQ(sqlstate_of(l,
                         "INSERT INTO currency_conversion "
                         "(uuid, ledger_id, seq, from_currency_uuid, to_currency_uuid, num, currency_pair_uuid) "
                         "VALUES ($1, NULL, $2, $3, $4, 1, $5)",
                         {uuidgen::v4(), next_seq(l), a, b, p}),
             std::string("23502")); // not_null_violation
    CHECK_EQ(sqlstate_of(l, kInsertStep, {uuidgen::v4(), l.identity.ledger_id, next_seq(l), a, a, "1", p}),
             std::string("23514"));
}

// ---- rate_on: возвращаемая дата и точность (2.1) ----

TEST(routes_rate_on_returns_latest_step_date_and_exact_product) {
    auto l = make_ledger();
    std::string btc = add_currency(l, "BTC"), eur = add_currency(l, "EUR"), rub = add_currency(l, "RUB");
    std::string p1 = add_pair(l, btc, eur), p2 = add_pair(l, eur, rub);
    add_rate(l, p1, "2026-11-01", "0.0000333333");
    add_rate(l, p2, "2026-11-10", "90.5");
    add_step(l, btc, rub, 1, p1, false);
    add_step(l, btc, rub, 2, p2, false);
    // Дата составного курса — наибольшая из дат шагов (как строка вьюхи на дату изменения).
    auto res = l.db->exec("SELECT \"date\"::text, rate::text FROM rate_on($1, $2, $3, '2026-11-12')",
                          {l.identity.ledger_id, btc, rub});
    REQUIRE(res.rows.size() == 1);
    CHECK_EQ(res.rows.at(0).fields.at(0), std::string("2026-11-10"));
    // 0.0000333333 × 90.5 = 0.00301666365 — произведение numeric, без потери знаков двоичной дроби.
    CHECK_EQ(res.rows.at(0).fields.at(1).rfind("0.00301666365", 0), static_cast<size_t>(0));
    // Не больше одной строки на запрос, даже если путей несколько.
    CHECK_EQ(count_rows(l, btc, rub), 1);
}

// ---- Составной курс по явному маршруту (2.2) ----

TEST(routes_two_steps_give_product_and_reverse_direction) {
    auto l = make_ledger();
    std::string btc = add_currency(l, "BTC"), eur = add_currency(l, "EUR"), rub = add_currency(l, "RUB");
    std::string p1 = add_pair(l, btc, eur), p2 = add_pair(l, eur, rub);
    add_rate(l, p1, "2026-11-01", "90000");
    add_rate(l, p2, "2026-11-01", "100");
    add_step(l, btc, rub, 1, p1, false);
    add_step(l, btc, rub, 2, p2, false);
    CHECK(near(rate_on(l, btc, rub, "2026-11-05"), 9000000.0));
    CHECK(near(rate_on(l, rub, btc, "2026-11-05"), 1.0 / 9000000.0));
}

TEST(routes_step_over_reversed_pair_uses_inverse_rate) {
    auto l = make_ledger();
    std::string btc = add_currency(l, "BTC"), eur = add_currency(l, "EUR"), rub = add_currency(l, "RUB");
    std::string p1 = add_pair(l, btc, eur);
    std::string p2 = add_pair(l, rub, eur); // RUBEUR: шаг EUR -> RUB идёт по ней в обратную сторону
    add_rate(l, p1, "2026-11-01", "90000");
    add_rate(l, p2, "2026-11-01", "0.01");
    add_step(l, btc, rub, 1, p1, false);
    add_step(l, btc, rub, 2, p2, true);
    CHECK(near(rate_on(l, btc, rub, "2026-11-05"), 9000000.0));
}

TEST(routes_three_steps_multiply_all_rates) {
    auto l = make_ledger();
    std::string btc = add_currency(l, "BTC"), usd = add_currency(l, "USD"), eur = add_currency(l, "EUR"),
                rub = add_currency(l, "RUB");
    std::string p1 = add_pair(l, btc, usd), p2 = add_pair(l, usd, eur), p3 = add_pair(l, eur, rub);
    add_rate(l, p1, "2026-11-01", "60000");
    add_rate(l, p2, "2026-11-01", "0.9");
    add_rate(l, p3, "2026-11-01", "100");
    add_step(l, btc, rub, 1, p1, false);
    add_step(l, btc, rub, 2, p2, false);
    add_step(l, btc, rub, 3, p3, false);
    CHECK(near(rate_on(l, btc, rub, "2026-11-05"), 5400000.0));
}

TEST(routes_steps_take_latest_rate_independently_by_date) {
    auto l = make_ledger();
    std::string btc = add_currency(l, "BTC"), eur = add_currency(l, "EUR"), rub = add_currency(l, "RUB");
    std::string p1 = add_pair(l, btc, eur), p2 = add_pair(l, eur, rub);
    add_rate(l, p1, "2026-11-01", "90000");
    add_rate(l, p2, "2026-11-10", "100");
    add_step(l, btc, rub, 1, p1, false);
    add_step(l, btc, rub, 2, p2, false);
    // Шаги заведены в разные дни: на 12.11 берутся курс 01.11 и курс 10.11.
    CHECK(near(rate_on(l, btc, rub, "2026-11-12"), 9000000.0));
    // Первый курс EUR→RUB появился 10.11: до этой даты составного курса нет.
    CHECK(!rate_on(l, btc, rub, "2026-11-05").has_value());
    // Курс меняется на дату изменения любого шага.
    add_rate(l, p1, "2026-11-15", "100000");
    CHECK(near(rate_on(l, btc, rub, "2026-11-15"), 10000000.0));
    CHECK(near(rate_on(l, btc, rub, "2026-11-12"), 9000000.0));
}

TEST(routes_unfinished_or_disjoint_chain_gives_no_rate) {
    auto l = make_ledger();
    std::string btc = add_currency(l, "BTC"), eur = add_currency(l, "EUR"), rub = add_currency(l, "RUB"),
                gbp = add_currency(l, "GBP");
    std::string p1 = add_pair(l, btc, eur), p2 = add_pair(l, eur, rub), p3 = add_pair(l, gbp, rub);
    for (const auto& p : {p1, p2, p3}) add_rate(l, p, "2026-11-01", "2");
    // Недостроенная: шаг 1 есть, шага 2 нет.
    add_step(l, btc, rub, 1, p1, false);
    CHECK(!rate_on(l, btc, rub, "2026-11-05").has_value());
    // Шаги не стыкуются: шаг 1 кончается в EUR, шаг 2 начинается в GBP.
    add_step(l, btc, rub, 2, p3, false);
    CHECK(!rate_on(l, btc, rub, "2026-11-05").has_value());
    // Дыра в нумерации (1 и 3 без 2) тоже не цепочка.
    auto m = make_ledger();
    std::string a = add_currency(m, "AAA"), b = add_currency(m, "BBB"), c = add_currency(m, "CCC");
    std::string q1 = add_pair(m, a, b), q2 = add_pair(m, b, c);
    add_rate(m, q1, "2026-11-01", "2");
    add_rate(m, q2, "2026-11-01", "3");
    add_step(m, a, c, 1, q1, false);
    add_step(m, a, c, 3, q2, false);
    CHECK(!rate_on(m, a, c, "2026-11-05").has_value());
}

TEST(routes_broken_by_deleted_pair_or_currency) {
    auto l = make_ledger();
    std::string btc = add_currency(l, "BTC"), eur = add_currency(l, "EUR"), rub = add_currency(l, "RUB");
    std::string p1 = add_pair(l, btc, eur), p2 = add_pair(l, eur, rub);
    add_rate(l, p1, "2026-11-01", "90000");
    add_rate(l, p2, "2026-11-01", "100");
    add_step(l, btc, rub, 1, p1, false);
    add_step(l, btc, rub, 2, p2, false);
    CHECK(near(rate_on(l, btc, rub, "2026-11-05"), 9000000.0));

    // Пара шага мягко удалена: курса по маршруту нет, и 1:1 тоже.
    l.db->exec("UPDATE currency_pair SET deleted_at = now() WHERE uuid = $1", {p2});
    CHECK(!rate_on(l, btc, rub, "2026-11-05").has_value());
    l.db->exec("UPDATE currency_pair SET deleted_at = NULL WHERE uuid = $1", {p2});
    CHECK(near(rate_on(l, btc, rub, "2026-11-05"), 9000000.0));

    // Промежуточная валюта мягко удалена.
    l.db->exec("UPDATE currency SET deleted_at = now() WHERE uuid = $1", {eur});
    CHECK(!rate_on(l, btc, rub, "2026-11-05").has_value());
    CHECK_EQ(count_rows(l, btc, rub), 0);
}

TEST(routes_are_isolated_by_ledger) {
    auto l1 = make_ledger();
    std::string btc = add_currency(l1, "BTC"), eur = add_currency(l1, "EUR"), rub = add_currency(l1, "RUB");
    std::string p1 = add_pair(l1, btc, eur), p2 = add_pair(l1, eur, rub);
    add_rate(l1, p1, "2026-11-01", "90000");
    add_rate(l1, p2, "2026-11-01", "100");
    add_step(l1, btc, rub, 1, p1, false);
    add_step(l1, btc, rub, 2, p2, false);
    CHECK(near(rate_on(l1, btc, rub, "2026-11-05"), 9000000.0));

    // Тот же запрос глазами соседнего леджера: строки леджера L1 не видны.
    auto l2 = make_ledger();
    CHECK(!rate_on(l2, btc, rub, "2026-11-05").has_value());
    CHECK_EQ(count_rows(l2, btc, rub), 0);
}

TEST(routes_identity_rate_is_unchanged) {
    auto l = make_ledger();
    std::string btc = add_currency(l, "BTC");
    CHECK(near(rate_on(l, btc, btc, "2026-11-05"), 1.0));
    CHECK_EQ(count_rows(l, btc, btc), 1);
}

// ---- Приоритет прямой пары (2.3) ----

TEST(routes_direct_pair_beats_route_and_route_returns_when_pair_deleted) {
    auto l = make_ledger();
    std::string btc = add_currency(l, "BTC"), eur = add_currency(l, "EUR"), rub = add_currency(l, "RUB");
    std::string p1 = add_pair(l, btc, eur), p2 = add_pair(l, eur, rub);
    add_rate(l, p1, "2026-11-01", "90000");
    add_rate(l, p2, "2026-11-01", "100");
    add_step(l, btc, rub, 1, p1, false);
    add_step(l, btc, rub, 2, p2, false);
    std::string direct = add_pair(l, btc, rub);
    add_rate(l, direct, "2026-11-01", "8000000");

    // Прямой курс есть (хоть на одну дату): маршрут не применяется на ЛЮБУЮ дату.
    CHECK(near(rate_on(l, btc, rub, "2026-11-05"), 8000000.0));
    CHECK(near(rate_on(l, btc, rub, "2026-12-31"), 8000000.0));
    CHECK(near(rate_on(l, rub, btc, "2026-12-31"), 1.0 / 8000000.0));
    // До первой даты прямого курса маршрут тоже не подставляется: прямой есть «на любую дату».
    add_rate(l, p1, "2026-09-01", "90000");
    add_rate(l, p2, "2026-09-01", "100");
    CHECK(!rate_on(l, btc, rub, "2026-10-01").has_value());

    // Единственная прямая пара удалена — курс снова по маршруту.
    l.db->exec("UPDATE currency_pair SET deleted_at = now() WHERE uuid = $1", {direct});
    CHECK(near(rate_on(l, btc, rub, "2026-11-05"), 9000000.0));
}

// ---- Кросс через USD (2.4) ----

TEST(cross_usd_builds_rate_from_two_direct_steps_both_directions) {
    auto l = make_ledger();
    std::string btc = add_currency(l, "BTC"), usd = add_currency(l, "USD"), rub = add_currency(l, "RUB");
    std::string p1 = add_pair(l, btc, usd), p2 = add_pair(l, usd, rub);
    add_rate(l, p1, "2026-11-01", "60000");
    add_rate(l, p2, "2026-11-01", "90");
    CHECK(near(rate_on(l, btc, rub, "2026-11-05"), 5400000.0));
    CHECK(near(rate_on(l, rub, btc, "2026-11-05"), 1.0 / 5400000.0));
}

TEST(cross_usd_uses_reversed_pairs_for_steps) {
    auto l = make_ledger();
    std::string eur = add_currency(l, "EUR"), usd = add_currency(l, "USD"), rub = add_currency(l, "RUB");
    std::string p1 = add_pair(l, eur, usd);  // EURUSD 1.1
    std::string p2 = add_pair(l, rub, usd);  // RUBUSD 0.011 — шаг USD -> RUB идёт по ней в обратную сторону
    add_rate(l, p1, "2026-11-01", "1.1");
    add_rate(l, p2, "2026-11-01", "0.011");
    CHECK(near(rate_on(l, eur, rub, "2026-11-05"), 100.0));
}

TEST(cross_usd_takes_each_leg_independently_by_date) {
    auto l = make_ledger();
    std::string btc = add_currency(l, "BTC"), usd = add_currency(l, "USD"), rub = add_currency(l, "RUB");
    std::string p1 = add_pair(l, btc, usd), p2 = add_pair(l, usd, rub);
    add_rate(l, p1, "2026-11-01", "60000");
    add_rate(l, p2, "2026-11-10", "90");
    CHECK(!rate_on(l, btc, rub, "2026-11-05").has_value());
    CHECK(near(rate_on(l, btc, rub, "2026-11-12"), 5400000.0));
    add_rate(l, p1, "2026-11-15", "70000");
    CHECK(near(rate_on(l, btc, rub, "2026-11-15"), 6300000.0));
}

TEST(cross_usd_needs_both_legs_and_does_not_apply_to_usd_itself) {
    auto l = make_ledger();
    std::string btc = add_currency(l, "BTC"), usd = add_currency(l, "USD"), rub = add_currency(l, "RUB");
    std::string p1 = add_pair(l, btc, usd);
    add_rate(l, p1, "2026-11-01", "60000");
    // Нет пары между USD и RUB: курса BTC→RUB нет.
    CHECK(!rate_on(l, btc, rub, "2026-11-05").has_value());

    auto m = make_ledger();
    std::string b = add_currency(m, "BTC"), u = add_currency(m, "USD"), r = add_currency(m, "RUB");
    std::string q = add_pair(m, u, r);
    add_rate(m, q, "2026-11-01", "90");
    // Сама USD: BTC→USD прямой пары нет, кросса через USD нет.
    CHECK(!rate_on(m, b, u, "2026-11-05").has_value());
    CHECK(!rate_on(m, u, b, "2026-11-05").has_value());
}

TEST(cross_usd_explicit_route_wins_and_valid_route_without_rate_blocks_usd) {
    auto l = make_ledger();
    std::string btc = add_currency(l, "BTC"), usd = add_currency(l, "USD"), eur = add_currency(l, "EUR"),
                rub = add_currency(l, "RUB");
    std::string bu = add_pair(l, btc, usd), ur = add_pair(l, usd, rub);
    std::string be = add_pair(l, btc, eur), er = add_pair(l, eur, rub);
    add_rate(l, bu, "2026-11-01", "60000");
    add_rate(l, ur, "2026-11-01", "90");
    add_rate(l, be, "2026-11-01", "90000");
    add_step(l, btc, rub, 1, be, false);
    add_step(l, btc, rub, 2, er, false);

    // Маршрут валиден, но у шага EUR→RUB курса нет: USD НЕ подставляется.
    CHECK(!rate_on(l, btc, rub, "2026-11-05").has_value());

    // Курс шага появился — считается по маршруту через EUR, а не через USD.
    add_rate(l, er, "2026-11-01", "100");
    CHECK(near(rate_on(l, btc, rub, "2026-11-05"), 9000000.0));
}

TEST(cross_usd_direct_pair_beats_cross) {
    auto l = make_ledger();
    std::string btc = add_currency(l, "BTC"), usd = add_currency(l, "USD"), rub = add_currency(l, "RUB");
    std::string bu = add_pair(l, btc, usd), ur = add_pair(l, usd, rub), br = add_pair(l, btc, rub);
    add_rate(l, bu, "2026-11-01", "60000");
    add_rate(l, ur, "2026-11-01", "90");
    add_rate(l, br, "2026-11-01", "5000000");
    CHECK(near(rate_on(l, btc, rub, "2026-11-05"), 5000000.0));
}

TEST(cross_usd_does_not_chain_through_other_cross_steps) {
    auto l = make_ledger();
    std::string btc = add_currency(l, "BTC"), usd = add_currency(l, "USD"), eur = add_currency(l, "EUR"),
                rub = add_currency(l, "RUB");
    std::string bu = add_pair(l, btc, usd), ur = add_pair(l, usd, rub), er = add_pair(l, eur, rub);
    add_rate(l, bu, "2026-11-01", "60000");
    add_rate(l, ur, "2026-11-01", "90");
    add_rate(l, er, "2026-11-01", "100");
    // BTC→EUR: BTC→USD есть, USD→EUR нет (EUR связан только с RUB) — курса нет, цепочки через RUB не строятся.
    CHECK(!rate_on(l, btc, eur, "2026-11-05").has_value());
}

// ---- Регрессия потребителей (2.5): эквивалент кошелька через маршрут и через USD ----

namespace {

// Кошелёк в валюте `currency` с поступлением `amount` на 2026-03-05.
std::string wallet_with_balance(Ledger& l, const std::string& currency, const std::string& amount) {
    auto add_account = [&](const std::string& name, int kind) {
        std::string uuid = uuidgen::v4();
        l.db->exec("INSERT INTO account (uuid, ledger_id, seq, name, icon_uuid, kind) VALUES ($1,$2,$3,$4,$5,$6)",
                   {uuid, l.identity.ledger_id, next_seq(l), name + " " + uuid, l.icon, std::to_string(kind)});
        return uuid;
    };
    std::string wallet = add_account("Кошелёк", 1);
    l.db->exec("INSERT INTO account_operating (uuid, ledger_id, seq, currency_uuid) VALUES ($1,$2,$3,$4)",
               {wallet, l.identity.ledger_id, next_seq(l), currency});
    std::string category = add_account("Доход", 0);
    l.db->exec("INSERT INTO operation (uuid, ledger_id, seq, \"date\", acc_fr_uuid, acc_to_uuid, amount, comment) "
               "VALUES ($1,$2,$3,'2026-03-05 10:00:00',$4,$5,$6,'')",
               {uuidgen::v4(), l.identity.ledger_id, next_seq(l), category, wallet, amount});
    return wallet;
}

std::string balance_eq(Ledger& l, const std::string& wallet, const std::string& eq_currency) {
    auto res = l.db->exec("SELECT coalesce(balance_eq::text, 'NULL') FROM f_balance_to_date($1, '2026-04-01', $2) "
                          "WHERE account_uuid = $3",
                          {l.identity.ledger_id, eq_currency, wallet});
    return res.rows.empty() ? std::string("NONE") : res.rows.at(0).fields.at(0);
}

} // namespace

TEST(consumers_wallet_equivalent_resolves_through_explicit_route) {
    auto l = make_ledger();
    std::string btc = add_currency(l, "BTC"), eur = add_currency(l, "EUR"), rub = add_currency(l, "RUB");
    std::string p1 = add_pair(l, btc, eur), p2 = add_pair(l, eur, rub);
    add_rate(l, p1, "2026-01-01", "90000");
    add_rate(l, p2, "2026-01-01", "100");
    add_step(l, btc, rub, 1, p1, false);
    add_step(l, btc, rub, 2, p2, false);
    std::string wallet = wallet_with_balance(l, btc, "2");
    CHECK_EQ(balance_eq(l, wallet, rub), std::string("18000000.00"));
}

TEST(consumers_wallet_equivalent_resolves_through_usd_cross) {
    auto l = make_ledger();
    std::string btc = add_currency(l, "BTC"), usd = add_currency(l, "USD"), rub = add_currency(l, "RUB");
    std::string p1 = add_pair(l, btc, usd), p2 = add_pair(l, usd, rub);
    add_rate(l, p1, "2026-01-01", "60000");
    add_rate(l, p2, "2026-01-01", "90");
    std::string wallet = wallet_with_balance(l, btc, "2");
    CHECK_EQ(balance_eq(l, wallet, rub), std::string("10800000.00"));
}

TEST(consumers_wallet_equivalent_is_null_without_any_rate_source) {
    auto l = make_ledger();
    std::string btc = add_currency(l, "BTC"), rub = add_currency(l, "RUB");
    std::string wallet = wallet_with_balance(l, btc, "2");
    // Нет ни пары, ни маршрута, ни USD: эквивалента нет (а не сумма по курсу 1:1).
    CHECK_EQ(balance_eq(l, wallet, rub), std::string("NULL"));
}

// ---- rate_on: прямой курс по индексу (миграция 000044) ----
// Семантика «последний курс не позже даты» при длинной истории курсов: раньше функция строила все курсы пары
// до даты и сортировала, теперь берёт один по индексу (LATERAL … LIMIT 1) — результат обязан совпасть.

TEST(rate_on_direct_takes_latest_rate_not_after_date_among_many) {
    auto l = make_ledger();
    std::string eur = add_currency(l, "EUR"), usd = add_currency(l, "USD");
    std::string pair = add_pair(l, eur, usd);
    // Ежедневные курсы за 120 дней: 1.00, 1.01, 1.02, … (рост на 0.01 в день), начиная с 2026-01-01.
    l.db->exec("INSERT INTO currency_pair_rate (uuid, ledger_id, seq, currency_pair_uuid, \"date\", rate) "
               "SELECT gen_random_uuid(), $1, 100000 + g, $2, DATE '2026-01-01' + g, 1 + g * 0.01 "
               "FROM generate_series(0, 119) g",
               {l.identity.ledger_id, pair});
    // Дата между курсами — берётся последний не позже даты (день 41 → 1.41), а не ближайший и не первый.
    CHECK(near(rate_on(l, eur, usd, "2026-02-11"), 1.41));
    CHECK(near(rate_on(l, eur, usd, "2026-01-01"), 1.0));    // ровно на дату первого курса
    CHECK(near(rate_on(l, eur, usd, "2026-04-30"), 2.19));   // день 119 — последний курс (1 + 119 * 0.01)
    CHECK(near(rate_on(l, eur, usd, "2030-01-01"), 2.19));   // далеко после истории — всё равно последний
    // До первого курса прямого курса нет (и маршрута/USD тоже): пусто, а не 1:1.
    CHECK(!rate_on(l, eur, usd, "2025-12-31").has_value());
    // Обратное направление — 1/курс на ту же дату.
    CHECK(near(rate_on(l, usd, eur, "2026-02-11"), 1.0 / 1.41));
    // Пара и обратная пара не путаются: «возрастающий» курс не отдаётся за курс другой валюты.
    std::string rub = add_currency(l, "RUB");
    CHECK(!rate_on(l, eur, rub, "2026-02-11").has_value());
}

TEST(rate_on_identity_rate_for_same_currency_and_deleted_rate_is_ignored) {
    auto l = make_ledger();
    std::string eur = add_currency(l, "EUR"), usd = add_currency(l, "USD");
    // Валюта на саму себя — «тождественный» курс 1 (как раньше во второй ветке v_currency_conversion_rate).
    CHECK(near(rate_on(l, eur, eur, "2026-03-01"), 1.0));
    std::string pair = add_pair(l, eur, usd);
    add_rate(l, pair, "2026-03-01", "1.10");
    add_rate(l, pair, "2026-03-10", "1.20");
    // Удалённый курс не участвует: на 03-15 действует 1.10, а не удалённый 1.20.
    l.db->exec("UPDATE currency_pair_rate SET deleted_at = now() "
               "WHERE currency_pair_uuid = $1 AND \"date\" = DATE '2026-03-10'",
               {pair});
    CHECK(near(rate_on(l, eur, usd, "2026-03-15"), 1.10));
}
