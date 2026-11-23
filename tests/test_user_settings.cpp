// Разбор тела PUT /api/settings (user_settings_repo::parse_put, change
// user-eq-currency) — чистая функция, без базы. Проверка кода по валютам
// леджера, запись и сброс — tests_integration/test_user_settings.cpp; scope
// account — test_access.cpp.
#include "user_settings_repo.hpp"

#include "test_framework.hpp"

using nlohmann::json;
using user_settings_repo::parse_put;

TEST(user_settings_parse_code_normalized_to_upper) {
    auto r = parse_put(json{{"eq_currency", " eur "}});
    REQUIRE(r.error.empty());
    REQUIRE(r.eq_currency.has_value());
    CHECK_EQ(*r.eq_currency, std::string("EUR"));
}

TEST(user_settings_parse_null_is_reset) {
    auto r = parse_put(json{{"eq_currency", nullptr}});
    CHECK(r.error.empty());
    CHECK(!r.eq_currency.has_value());
}

TEST(user_settings_parse_rejects_bad_bodies) {
    for (const json& body : {json::array({"EUR"}), json("EUR"), json(nullptr), json::object(),
                             json{{"eq_currency", 978}}, json{{"eq_currency", true}},
                             json{{"eq_currency", json::array({"EUR"})}}, json{{"eq_currency", ""}},
                             json{{"eq_currency", "   "}}}) {
        auto r = parse_put(body);
        CHECK(!r.error.empty());
        CHECK(!r.eq_currency.has_value());
    }
}

TEST(user_settings_parse_ignores_unknown_fields) {
    auto r = parse_put(json{{"eq_currency", "usd"}, {"other", 1}});
    REQUIRE(r.error.empty());
    CHECK_EQ(r.eq_currency.value_or(""), std::string("USD"));
}
