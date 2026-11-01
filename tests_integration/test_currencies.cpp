// Интеграционные тесты currencies_repo (spec currencies-api, change
// currency-ui-tweaks) против живого Postgres: видимость своих и общих валют,
// явная уникальность против общих, запреты currency_in_pair/currency_in_use
// и доставка изменений в pull — всё это проверяется только на настоящей базе.
// HTTP-коды — карта WriteError в currencies.cpp (respond), здесь — сами исходы.
#include "currencies_repo.hpp"

#include "fixture.hpp"
#include "nlohmann/json.hpp"
#include "sync_repo.hpp"
#include "test_framework.hpp"
#include "util/uuid.hpp"

using currencies_repo::CurrencyInput;
using currencies_repo::WriteError;
using nlohmann::json;

namespace {

// Код из свежего uuid: база не чистится между прогонами (fixture.hpp).
std::string fresh_code() { return "c" + uuidgen::v4().substr(0, 7); }

CurrencyInput input(const std::string& name, const std::string& iso, const std::string& icon) {
    CurrencyInput in;
    in.name = name;
    in.iso_code = iso;
    in.icon_uuid = icon;
    return in;
}

std::string upper(std::string s) {
    for (char& c : s) c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
    return s;
}

std::string own_currency(db::Database& db, const std::string& ledger_id, const std::string& icon,
                         std::string* code_out = nullptr) {
    std::string code = upper(fresh_code());
    auto r = currencies_repo::create_currency(db, ledger_id, input("Cur " + code, code, icon));
    if (r.error != WriteError::kOk) throw std::runtime_error("fixture currency not created");
    if (code_out) *code_out = code;
    return r.currency.at("uuid").get<std::string>();
}

std::string own_count(db::Database& db, const std::string& ledger_id) {
    return db.exec("SELECT count(*) FROM currency WHERE ledger_id = $1", {ledger_id}).rows.at(0).fields.at(0);
}

std::optional<json> pulled_currency(db::Database& db, const std::string& ledger_id, int64_t cursor,
                                    const std::string& uuid) {
    auto pull = sync_repo::pull_ledger_stream(db, ledger_id, cursor, 100000);
    if (!pull.changes.contains("currency")) return std::nullopt;
    for (const auto& row : pull.changes.at("currency")) {
        if (row.at("uuid").get<std::string>() == uuid) return row;
    }
    return std::nullopt;
}

int64_t ledger_head(db::Database& db, const std::string& ledger_id) {
    return std::stoll(db.exec("SELECT seq FROM change_stream WHERE id = $1", {ledger_id}).rows.at(0).fields.at(0));
}

// Пара напрямую SQL (не currency_pairs_repo — тот здесь не собирается).
void make_pair(db::Database& db, const std::string& ledger_id, const std::string& base, const std::string& quote) {
    auto seq = db.exec("SELECT next_seq($1)", {ledger_id}).rows.at(0).fields.at(0);
    db.exec("INSERT INTO currency_pair (uuid, ledger_id, seq, symbol, base_currency_uuid, quote_currency_uuid, "
            "\"precision\") VALUES ($1, $2, $3, $4, $5, $6, 5)",
            {uuidgen::v4(), ledger_id, seq, "P" + uuidgen::v4().substr(0, 8), base, quote});
}

} // namespace

TEST(create_currency_minimal_applies_defaults) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    auto icon = fixture::make_reference_icon_with_sha256(*db);
    std::string code = fresh_code(); // строчными — сервер приводит к верхнему регистру

    auto parsed = currencies_repo::parse_create(json{{"name", "Тенге " + code}, {"iso_code", code}, {"icon_uuid", icon.uuid}});
    REQUIRE(parsed.error.empty());
    auto r = currencies_repo::create_currency(*db, identity.ledger_id, parsed.input);
    REQUIRE(r.error == WriteError::kOk);
    CHECK_EQ(r.currency.at("iso_code").get<std::string>(), upper(code));
    CHECK_EQ(r.currency.at("symbol").get<std::string>(), upper(code));
    CHECK_EQ(r.currency.at("precision").get<int>(), 2);
    CHECK(r.currency.at("show_in_equivalent") == json(true));
    CHECK(r.currency.at("is_own") == json(true));
    CHECK_EQ(r.currency.at("icon_uuid").get<std::string>(), icon.uuid);
    CHECK_EQ(r.currency.at("icon_sha256").get<std::string>(), icon.sha256_hex);

    auto row = db->exec("SELECT ledger_id::text, updated_by IS NULL FROM currency WHERE uuid = $1",
                        {r.currency.at("uuid").get<std::string>()});
    CHECK_EQ(row.rows.at(0).fields.at(0), identity.ledger_id);
    CHECK_EQ(row.rows.at(0).fields.at(1), std::string("t"));
}

TEST(create_currency_invalid_fields_create_nothing) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    std::string icon = fixture::make_reference_icon(*db);
    for (json body : {json{{"name", ""}, {"iso_code", "X"}, {"icon_uuid", icon}},
                      json{{"name", "N"}, {"iso_code", "X"}, {"icon_uuid", icon}, {"precision", 9}},
                      json{{"name", "N"}, {"iso_code", "X"}, {"icon_uuid", icon}, {"show_in_equivalent", "no"}}}) {
        CHECK(!currencies_repo::parse_create(body).error.empty());
    }
    CHECK_EQ(own_count(*db, identity.ledger_id), std::string("0"));
}

TEST(create_currency_rejects_icon_of_other_ledger) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    auto other = fixture::make_identity(*db);
    auto blob = fixture::make_reference_icon_with_sha256(*db);
    // Своя иконка ЧУЖОГО леджера (тот же blob — содержимое общее).
    std::string foreign_icon = uuidgen::v4();
    auto seq = db->exec("SELECT next_seq($1)", {other.ledger_id}).rows.at(0).fields.at(0);
    db->exec("INSERT INTO icon (uuid, ledger_id, seq, name, content_sha256, icon_type) "
             "VALUES ($1, $2, $3, $4, decode($5, 'hex'), 0)",
             {foreign_icon, other.ledger_id, seq, "foreign-" + foreign_icon, blob.sha256_hex});

    std::string code = upper(fresh_code());
    auto r = currencies_repo::create_currency(*db, identity.ledger_id, input("N " + code, code, foreign_icon));
    CHECK(r.error == WriteError::kIconNotFound);
    CHECK_EQ(own_count(*db, identity.ledger_id), std::string("0"));
}

TEST(shared_currency_is_not_found_for_patch_and_delete) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    std::string icon = fixture::make_reference_icon(*db);
    std::string shared = fixture::make_currency(*db, "", icon);
    auto before = db->exec("SELECT seq, name, show_in_equivalent, deleted_at IS NULL FROM currency WHERE uuid = $1", {shared});

    CurrencyInput patch;
    patch.show_in_equivalent = false;
    CHECK(currencies_repo::update_currency(*db, identity.ledger_id, shared, patch).error == WriteError::kNotFound);
    CHECK(currencies_repo::delete_currency(*db, identity.ledger_id, shared).error == WriteError::kNotFound);
    auto after = db->exec("SELECT seq, name, show_in_equivalent, deleted_at IS NULL FROM currency WHERE uuid = $1", {shared});
    CHECK(after.rows.at(0).fields == before.rows.at(0).fields);

    // Чужая своя валюта — тот же 404.
    auto other = fixture::make_identity(*db);
    std::string foreign = own_currency(*db, other.ledger_id, icon);
    CHECK(currencies_repo::update_currency(*db, identity.ledger_id, foreign, patch).error == WriteError::kNotFound);
}

TEST(create_currency_duplicate_of_shared_code_or_name_is_409) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    std::string icon = fixture::make_reference_icon(*db);
    // fixture::make_currency: iso_code = name = symbol = 8 hex-символов строчными.
    std::string shared = fixture::make_currency(*db, "", icon);
    std::string shared_code = db->exec("SELECT iso_code FROM currency WHERE uuid = $1", {shared}).rows.at(0).fields.at(0);

    auto by_code = currencies_repo::create_currency(*db, identity.ledger_id, input("Unique " + shared_code, upper(shared_code), icon));
    CHECK(by_code.error == WriteError::kDuplicate);
    CHECK_EQ(by_code.field, std::string("iso_code"));

    auto by_name = currencies_repo::create_currency(*db, identity.ledger_id, input(shared_code, upper(fresh_code()), icon));
    CHECK(by_name.error == WriteError::kDuplicate);
    CHECK_EQ(by_name.field, std::string("name"));

    // Дубль своей же валюты при правке другой.
    std::string first_code;
    own_currency(*db, identity.ledger_id, icon, &first_code);
    std::string second = own_currency(*db, identity.ledger_id, icon);
    CurrencyInput patch;
    patch.iso_code = first_code;
    auto r = currencies_repo::update_currency(*db, identity.ledger_id, second, patch);
    CHECK(r.error == WriteError::kDuplicate);
    CHECK_EQ(r.field, std::string("iso_code"));
}

TEST(patch_iso_code_of_pair_currency_is_409_but_other_fields_change) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    std::string icon = fixture::make_reference_icon(*db);
    std::string code;
    std::string xau = own_currency(*db, identity.ledger_id, icon, &code);
    std::string usd = fixture::make_currency(*db, "", icon);
    make_pair(*db, identity.ledger_id, xau, usd);

    CurrencyInput new_code;
    new_code.iso_code = upper(fresh_code());
    CHECK(currencies_repo::update_currency(*db, identity.ledger_id, xau, new_code).error == WriteError::kInPair);
    CHECK_EQ(db->exec("SELECT iso_code FROM currency WHERE uuid = $1", {xau}).rows.at(0).fields.at(0), code);

    CurrencyInput same_code;
    same_code.iso_code = code;
    same_code.name = "Золото " + code;
    auto r = currencies_repo::update_currency(*db, identity.ledger_id, xau, same_code);
    REQUIRE(r.error == WriteError::kOk);
    CHECK_EQ(r.currency.at("name").get<std::string>(), "Золото " + code);
}

TEST(patch_show_in_equivalent_keeps_other_fields) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    std::string icon = fixture::make_reference_icon(*db);
    std::string uuid = own_currency(*db, identity.ledger_id, icon);
    auto before = *currencies_repo::find_currency(*db, identity.ledger_id, uuid);

    CurrencyInput patch;
    patch.show_in_equivalent = false;
    auto r = currencies_repo::update_currency(*db, identity.ledger_id, uuid, patch);
    REQUIRE(r.error == WriteError::kOk);
    json expected = before;
    expected["show_in_equivalent"] = false;
    CHECK_EQ(r.currency, expected);
}

TEST(delete_currency_in_use_is_409) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    std::string icon = fixture::make_reference_icon(*db);

    // Валюта живого кошелька.
    std::string wallet_currency = own_currency(*db, identity.ledger_id, icon);
    std::string account = uuidgen::v4();
    json changes = {
        {"account", json::array({json{{"uuid", account}, {"name", "Wallet " + account}, {"comment", ""},
                                      {"icon_uuid", icon}, {"is_archived", false}, {"system_kind", 0}, {"kind", 0}}})},
        {"account_operating", json::array({json{{"uuid", account}, {"currency_uuid", wallet_currency}}})},
    };
    REQUIRE(sync_repo::push_batch(*db, identity.ledger_id, identity.device_id, uuidgen::v4(), changes).http_status == 200);
    CHECK(currencies_repo::delete_currency(*db, identity.ledger_id, wallet_currency).error == WriteError::kInUse);

    // Валюта живой пары (котируемая).
    std::string pair_currency = own_currency(*db, identity.ledger_id, icon);
    make_pair(*db, identity.ledger_id, fixture::make_currency(*db, "", icon), pair_currency);
    CHECK(currencies_repo::delete_currency(*db, identity.ledger_id, pair_currency).error == WriteError::kInUse);

    auto alive = db->exec("SELECT count(*) FROM currency WHERE uuid IN ($1, $2) AND deleted_at IS NULL",
                          {wallet_currency, pair_currency});
    CHECK_EQ(alive.rows.at(0).fields.at(0), std::string("2"));
}

TEST(delete_free_currency_goes_to_pull_as_tombstone) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    std::string icon = fixture::make_reference_icon(*db);
    std::string uuid = own_currency(*db, identity.ledger_id, icon);
    int64_t cursor = ledger_head(*db, identity.ledger_id);

    CHECK(currencies_repo::delete_currency(*db, identity.ledger_id, uuid).error == WriteError::kOk);
    CHECK(!currencies_repo::find_currency(*db, identity.ledger_id, uuid).has_value());
    auto pulled = pulled_currency(*db, identity.ledger_id, cursor, uuid);
    REQUIRE(pulled.has_value());
    CHECK(!pulled->at("deleted_at").is_null());
    CHECK_EQ(pulled->at("seq").get<int64_t>(), cursor + 1);
    // Повторное удаление — уже нечего удалять.
    CHECK(currencies_repo::delete_currency(*db, identity.ledger_id, uuid).error == WriteError::kNotFound);
}

TEST(currency_edit_from_web_reaches_pull_with_one_new_seq) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    std::string icon = fixture::make_reference_icon(*db);
    std::string uuid = own_currency(*db, identity.ledger_id, icon);
    int64_t cursor = ledger_head(*db, identity.ledger_id);

    CurrencyInput patch;
    patch.name = "Renamed " + uuid;
    patch.symbol = ""; // пустой символ = код
    auto r = currencies_repo::update_currency(*db, identity.ledger_id, uuid, patch);
    REQUIRE(r.error == WriteError::kOk);
    CHECK_EQ(r.currency.at("symbol"), r.currency.at("iso_code"));
    CHECK_EQ(ledger_head(*db, identity.ledger_id), cursor + 1);

    auto pulled = pulled_currency(*db, identity.ledger_id, cursor, uuid);
    REQUIRE(pulled.has_value());
    CHECK_EQ(pulled->at("name").get<std::string>(), "Renamed " + uuid);
    CHECK(pulled->at("updated_by").is_null());
}
