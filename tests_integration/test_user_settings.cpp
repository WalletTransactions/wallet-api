// Интеграционные тесты user_settings_repo (spec user-settings-api, change
// user-eq-currency) против живого Postgres: видимость кода валюты леджеру
// (общие + свои, без леджера — только общие), сохранение, сброс, отказ без
// изменений, каскад при удалении аккаунта, грант wallet_reader. HTTP-коды и
// scope — user_settings.cpp и tests/test_access.cpp.
#include "user_settings_repo.hpp"

#include <cctype>

#include "account_deletion_repo.hpp"
#include "fixture.hpp"
#include "test_framework.hpp"
#include "util/uuid.hpp"

using user_settings_repo::WriteError;

namespace {

std::string upper(std::string s) {
    for (char& c : s) c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
    return s;
}

// Код валюты, заведённой fixture::make_currency (строчные hex из uuid).
std::string iso_of(db::Database& db, const std::string& currency_uuid) {
    return db.exec("SELECT iso_code FROM currency WHERE uuid = $1", {currency_uuid}).rows.at(0).fields.at(0);
}

std::string settings_rows(db::Database& db, const std::string& user_id) {
    return db.exec("SELECT count(*) FROM user_settings WHERE user_id = $1", {user_id}).rows.at(0).fields.at(0);
}

const char* kEmail = "integration-test@example.com";

} // namespace

TEST(user_settings_not_set_is_nullopt) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    CHECK(!user_settings_repo::find_eq_currency(*db, identity.user_id));
}

TEST(user_settings_saves_own_currency_in_upper_case) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    std::string icon = fixture::make_reference_icon(*db);
    std::string code = iso_of(*db, fixture::make_currency(*db, identity.ledger_id, icon));

    auto parsed = user_settings_repo::parse_put(nlohmann::json{{"eq_currency", code}});
    REQUIRE(parsed.error.empty());
    REQUIRE(user_settings_repo::save_eq_currency(*db, identity.user_id, kEmail, identity.ledger_id,
                                                 parsed.eq_currency) == WriteError::kOk);
    auto saved = user_settings_repo::find_eq_currency(*db, identity.user_id);
    REQUIRE(saved.has_value());
    CHECK_EQ(*saved, upper(code));
}

TEST(user_settings_shared_currency_is_visible) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    std::string icon = fixture::make_reference_icon(*db);
    std::string code = upper(iso_of(*db, fixture::make_currency(*db, "", icon)));
    CHECK(user_settings_repo::save_eq_currency(*db, identity.user_id, kEmail, identity.ledger_id, code) ==
          WriteError::kOk);
    CHECK_EQ(user_settings_repo::find_eq_currency(*db, identity.user_id).value_or(""), code);
}

TEST(user_settings_unknown_currency_keeps_previous_value) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    auto other = fixture::make_identity(*db);
    std::string icon = fixture::make_reference_icon(*db);
    std::string own = upper(iso_of(*db, fixture::make_currency(*db, identity.ledger_id, icon)));
    std::string foreign = upper(iso_of(*db, fixture::make_currency(*db, other.ledger_id, icon)));
    std::string deleted_uuid = fixture::make_currency(*db, identity.ledger_id, icon);
    std::string deleted = upper(iso_of(*db, deleted_uuid));
    db->exec("UPDATE currency SET deleted_at = now() WHERE uuid = $1", {deleted_uuid});

    REQUIRE(user_settings_repo::save_eq_currency(*db, identity.user_id, kEmail, identity.ledger_id, own) ==
            WriteError::kOk);
    // Нет нигде, своя валюта чужого леджера, своя удалённая — всё неизвестно.
    for (const std::string& code : {std::string("XYZ") + uuidgen::v4().substr(0, 4), foreign, deleted}) {
        CHECK(user_settings_repo::save_eq_currency(*db, identity.user_id, kEmail, identity.ledger_id, code) ==
              WriteError::kUnknownCurrency);
    }
    CHECK_EQ(user_settings_repo::find_eq_currency(*db, identity.user_id).value_or(""), own);
}

TEST(user_settings_null_resets) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    std::string icon = fixture::make_reference_icon(*db);
    std::string code = upper(iso_of(*db, fixture::make_currency(*db, identity.ledger_id, icon)));
    REQUIRE(user_settings_repo::save_eq_currency(*db, identity.user_id, kEmail, identity.ledger_id, code) ==
            WriteError::kOk);
    CHECK(user_settings_repo::save_eq_currency(*db, identity.user_id, kEmail, identity.ledger_id, std::nullopt) ==
          WriteError::kOk);
    CHECK(!user_settings_repo::find_eq_currency(*db, identity.user_id));
    // Сброс без строки — тоже kOk, строку не заводит.
    auto fresh = fixture::make_identity(*db);
    CHECK(user_settings_repo::save_eq_currency(*db, fresh.user_id, kEmail, fresh.ledger_id, std::nullopt) ==
          WriteError::kOk);
    CHECK_EQ(settings_rows(*db, fresh.user_id), std::string("0"));
}

TEST(user_settings_reader_member_can_save) {
    auto db = fixture::open();
    auto owner = fixture::make_identity(*db);
    std::string icon = fixture::make_reference_icon(*db);
    std::string code = upper(iso_of(*db, fixture::make_currency(*db, owner.ledger_id, icon)));

    std::string reader = uuidgen::v4();
    db->exec("INSERT INTO app_user (id, email) VALUES ($1, $2)", {reader, "reader-" + reader + "@example.com"});
    db->exec("INSERT INTO ledger_member (ledger_id, user_id, role) VALUES ($1, $2, 'reader')",
             {owner.ledger_id, reader});
    CHECK(user_settings_repo::save_eq_currency(*db, reader, "", owner.ledger_id, code) == WriteError::kOk);
    CHECK_EQ(user_settings_repo::find_eq_currency(*db, reader).value_or(""), code);
}

TEST(user_settings_without_ledger_only_shared_and_creates_app_user) {
    auto db = fixture::open();
    auto other = fixture::make_identity(*db);
    std::string icon = fixture::make_reference_icon(*db);
    std::string shared = upper(iso_of(*db, fixture::make_currency(*db, "", icon)));
    std::string own_of_other = upper(iso_of(*db, fixture::make_currency(*db, other.ledger_id, icon)));

    // Веб-пользователь, которого ещё нет ни в app_user, ни в ledger_member.
    std::string user_id = uuidgen::v4();
    CHECK(user_settings_repo::save_eq_currency(*db, user_id, kEmail, "", own_of_other) ==
          WriteError::kUnknownCurrency);
    CHECK_EQ(db->exec("SELECT count(*) FROM app_user WHERE id = $1", {user_id}).rows.at(0).fields.at(0),
             std::string("0"));
    CHECK(user_settings_repo::save_eq_currency(*db, user_id, kEmail, "", shared) == WriteError::kOk);
    CHECK_EQ(user_settings_repo::find_eq_currency(*db, user_id).value_or(""), shared);
}

TEST(user_settings_row_removed_with_account) {
    auto db = fixture::open();
    auto identity = fixture::make_identity(*db);
    std::string icon = fixture::make_reference_icon(*db);
    std::string code = upper(iso_of(*db, fixture::make_currency(*db, identity.ledger_id, icon)));
    REQUIRE(user_settings_repo::save_eq_currency(*db, identity.user_id, kEmail, identity.ledger_id, code) ==
            WriteError::kOk);
    REQUIRE(settings_rows(*db, identity.user_id) == "1");

    REQUIRE(account_deletion_repo::delete_own_account(*db, identity.user_id) ==
            account_deletion_repo::DeleteStatus::kOk);
    CHECK_EQ(settings_rows(*db, identity.user_id), std::string("0"));
}

TEST(user_settings_wallet_reader_can_select) {
    auto db = fixture::open();
    auto res = db->exec("SELECT has_table_privilege('wallet_reader', 'user_settings', 'SELECT')");
    CHECK_EQ(res.rows.at(0).fields.at(0), std::string("t"));
}
