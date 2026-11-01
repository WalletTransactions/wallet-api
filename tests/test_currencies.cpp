// Разбор и проверка тела POST/PATCH /api/currencies (currencies_repo::
// parse_create/parse_update) — чистые функции, без базы. Сами записи,
// видимость иконки, уникальность и запреты — tests_integration/
// test_currencies.cpp.
#include "currencies_repo.hpp"

#include "test_framework.hpp"

using currencies_repo::parse_create;
using currencies_repo::parse_update;
using nlohmann::json;

namespace {

const char* kIcon = "22222222-2222-2222-2222-222222222222";

json minimal() { return json{{"name", "Тенге"}, {"iso_code", "kzt"}, {"icon_uuid", kIcon}}; }

} // namespace

TEST(currency_parse_create_minimal_normalizes) {
    json body = minimal();
    body["name"] = "  Тенге  ";
    body["iso_code"] = " kzt ";
    auto r = parse_create(body);
    REQUIRE(r.error.empty());
    CHECK_EQ(*r.input.name, std::string("Тенге"));
    CHECK_EQ(*r.input.iso_code, std::string("KZT"));
    CHECK(!r.input.symbol);
    CHECK(!r.input.precision);             // умолчание 2 подставит create_currency
    CHECK(!r.input.show_in_equivalent);    // умолчание true — тоже
}

TEST(currency_parse_create_requires_name_iso_icon) {
    for (const char* key : {"name", "iso_code", "icon_uuid"}) {
        json body = minimal();
        body.erase(key);
        auto r = parse_create(body);
        CHECK(!r.error.empty());
        CHECK_EQ(r.field, std::string(key));
    }
}

TEST(currency_parse_rejects_bad_fields_naming_the_field) {
    struct Case {
        const char* key;
        json value;
    };
    const Case cases[] = {
        {"name", "   "},           {"iso_code", ""},          {"name", 5},
        {"symbol", 1},             {"precision", 9},          {"precision", -1},
        {"precision", 2.5},        {"precision", "2"},        {"show_in_equivalent", "yes"},
        {"show_in_equivalent", 1}, {"icon_uuid", "not-uuid"},
    };
    for (const auto& c : cases) {
        json body = minimal();
        body[c.key] = c.value;
        auto r = parse_create(body);
        CHECK(!r.error.empty());
        CHECK_EQ(r.field, std::string(c.key));
        CHECK(r.error.find(c.key) != std::string::npos);
    }
}

TEST(currency_parse_accepts_full_body) {
    json body = minimal();
    body["symbol"] = " ₸ ";
    body["precision"] = 0;
    body["show_in_equivalent"] = false;
    auto r = parse_create(body);
    REQUIRE(r.error.empty());
    CHECK_EQ(*r.input.symbol, std::string("₸"));
    CHECK_EQ(*r.input.precision, 0);
    CHECK_EQ(*r.input.show_in_equivalent, false);

    body["symbol"] = ""; // пустой символ допустим: create подставит iso_code
    CHECK(parse_create(body).error.empty());
    body["precision"] = 8;
    CHECK(parse_create(body).error.empty());
}

TEST(currency_parse_update_any_subset) {
    auto r = parse_update(json{{"show_in_equivalent", false}});
    REQUIRE(r.error.empty());
    CHECK_EQ(*r.input.show_in_equivalent, false);
    CHECK(!r.input.name);
    CHECK(!r.input.iso_code);

    CHECK(!parse_update(json::object()).error.empty()); // нечего менять
    CHECK(!parse_update(json::array()).error.empty());  // не объект
    CHECK_EQ(parse_update(json{{"name", ""}}).field, std::string("name"));
    CHECK_EQ(*parse_update(json{{"iso_code", "gld"}}).input.iso_code, std::string("GLD"));
}

TEST(currency_is_uuid) {
    CHECK(currencies_repo::is_uuid("22222222-2222-2222-2222-222222222222"));
    CHECK(currencies_repo::is_uuid("ABCDEFab-2222-2222-2222-222222222222"));
    CHECK(!currencies_repo::is_uuid("22222222222222222222222222222222"));
    CHECK(!currencies_repo::is_uuid("x2222222-2222-2222-2222-222222222222"));
    CHECK(!currencies_repo::is_uuid(""));
}
