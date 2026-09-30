// Интеграционные тесты account_deletion_repo.hpp против ЖИВОГО Postgres —
// тем же приёмом, что test_invites.cpp: HTTP-слой (account_deletion.cpp —
// session::current_user, коды ответа) сюда намеренно не входит, только
// testable-логика каскадного удаления.
#include "account_deletion_repo.hpp"

#include <string>

#include "fixture.hpp"
#include "invites_repo.hpp"
#include "test_framework.hpp"
#include "util/uuid.hpp"

namespace {

// Добавляет участника НАПРЯМУЮ SQL — тот же приём, что add_member в
// test_invites.cpp (не продублирован оттуда: тесты каждого файла собираются
// в один бинарь, но .cpp друг у друга приватные helpers не видят — см.
// анонимный namespace в обоих).
std::string add_member(db::Database& db, const std::string& ledger_id, const std::string& role) {
    std::string user_id = uuidgen::v4();
    db.exec("INSERT INTO app_user (id, email) VALUES ($1, $2)",
            {user_id, "member-" + user_id + "@example.com"});
    db.exec("INSERT INTO ledger_member (ledger_id, user_id, role) VALUES ($1, $2, $3)",
            {ledger_id, user_id, role});
    return user_id;
}

// Настоящая строка account этого леджера — напрямую SQL (тем же приёмом,
// что fixture::make_currency), чтобы проверить, что ON DELETE CASCADE от
// ledger реально сносит и её, не только "верхние" ledger_member/device.
std::string add_account(db::Database& db, const std::string& ledger_id, const std::string& icon_uuid) {
    std::string uuid = uuidgen::v4();
    auto seq_res = db.exec("SELECT next_seq($1)", {ledger_id});
    db.exec("INSERT INTO account (uuid, ledger_id, seq, name, icon_uuid) VALUES ($1,$2,$3,$4,$5)",
            {uuid, ledger_id, seq_res.rows.at(0).fields.at(0), "wallet-" + uuid, icon_uuid});
    return uuid;
}

bool ledger_exists(db::Database& db, const std::string& ledger_id) {
    auto res = db.exec("SELECT 1 FROM ledger WHERE id = $1", {ledger_id});
    return !res.rows.empty();
}

bool change_stream_exists(db::Database& db, const std::string& id) {
    auto res = db.exec("SELECT 1 FROM change_stream WHERE id = $1", {id});
    return !res.rows.empty();
}

bool app_user_exists(db::Database& db, const std::string& user_id) {
    auto res = db.exec("SELECT 1 FROM app_user WHERE id = $1", {user_id});
    return !res.rows.empty();
}

bool account_exists(db::Database& db, const std::string& ledger_id, const std::string& uuid) {
    auto res = db.exec("SELECT 1 FROM account WHERE ledger_id = $1 AND uuid = $2", {ledger_id, uuid});
    return !res.rows.empty();
}

} // namespace

TEST(delete_own_account_sole_owner_wipes_ledger_and_all_its_data) {
    auto db = fixture::open();
    auto owner = fixture::make_identity(*db);
    auto icon = fixture::make_reference_icon(*db);
    std::string account_uuid = add_account(*db, owner.ledger_id, icon);

    REQUIRE(ledger_exists(*db, owner.ledger_id));
    REQUIRE(account_exists(*db, owner.ledger_id, account_uuid));

    auto status = account_deletion_repo::delete_own_account(*db, owner.user_id);
    REQUIRE(status == account_deletion_repo::DeleteStatus::kOk);

    // Каскад от ledger (wallet-api/schema/table/account.sql, ON DELETE CASCADE) —
    // не только сам леджер, но и данные внутри него.
    CHECK(!ledger_exists(*db, owner.ledger_id));
    CHECK(!account_exists(*db, owner.ledger_id, account_uuid));
    // ledger.id REFERENCES change_stream ON DELETE RESTRICT — леджер снят
    // первым, поток за ним, не наоборот (см. account_deletion_repo.cpp).
    CHECK(!change_stream_exists(*db, owner.ledger_id));
    CHECK(!app_user_exists(*db, owner.user_id));
}

TEST(delete_own_account_owner_with_other_members_is_rejected_untouched) {
    auto db = fixture::open();
    auto owner = fixture::make_identity(*db);
    std::string member_id = add_member(*db, owner.ledger_id, "member");

    auto status = account_deletion_repo::delete_own_account(*db, owner.user_id);
    CHECK(status == account_deletion_repo::DeleteStatus::kOwnsSharedLedger);

    // Отказ — не "откатили начатое", а "не начинали вовсе": ни владелец, ни
    // леджер, ни второй участник не пострадали.
    CHECK(ledger_exists(*db, owner.ledger_id));
    CHECK(app_user_exists(*db, owner.user_id));
    CHECK(app_user_exists(*db, member_id));
    auto membership = invites_repo::find_membership(*db, owner.user_id);
    REQUIRE(membership.has_value());
    CHECK_EQ(membership->role, std::string("owner"));
}

TEST(delete_own_account_plain_member_only_leaves_shared_ledger) {
    auto db = fixture::open();
    auto owner = fixture::make_identity(*db);
    std::string member_id = add_member(*db, owner.ledger_id, "member");

    auto status = account_deletion_repo::delete_own_account(*db, member_id);
    REQUIRE(status == account_deletion_repo::DeleteStatus::kOk);

    // Собственные данные удалившегося участника исчезли...
    CHECK(!app_user_exists(*db, member_id));
    // ...но леджер и его владелец — ЧУЖИЕ данные — не тронуты вовсе: FK
    // ledger_member.user_id ON DELETE CASCADE снял только его строку
    // членства, не сам ledger_id (см. account_deletion_repo.hpp, шаг 2).
    CHECK(ledger_exists(*db, owner.ledger_id));
    auto owner_membership = invites_repo::find_membership(*db, owner.user_id);
    REQUIRE(owner_membership.has_value());
    CHECK_EQ(owner_membership->role, std::string("owner"));
}

TEST(delete_own_account_never_provisioned_user_is_idempotent_ok) {
    auto db = fixture::open();
    // Ни разу не касался wallet-api — ни app_user, ни ledger_member. Тот же
    // принцип, что у repo::delete_user в google-auth: повтор/незнакомый id —
    // не ошибка (см. account_deletion_repo.hpp).
    std::string stranger_id = uuidgen::v4();
    auto status = account_deletion_repo::delete_own_account(*db, stranger_id);
    CHECK(status == account_deletion_repo::DeleteStatus::kOk);
}
