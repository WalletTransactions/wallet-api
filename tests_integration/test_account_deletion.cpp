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

// Регрессия 2026-10-01 (org/docs/TODO_telegram_bot.md, шаг 8): у леджера, где есть
// своя валюта и кошелёк в ней, каскад падал на RESTRICT-ключе
// account_operating_currency_uuid_fkey — RESTRICT проверяется сразу, а каскад
// удалял currency раньше account_operating. Здесь все ключи, которые до миграции
// 000025 были RESTRICT или неоткладываемыми: своя иконка (account/currency →
// icon), своя валюта (account_operating → currency), пара своих валют
// (currency_pair → currency) и операция (operation → account).
TEST(delete_own_account_wipes_ledger_with_own_icon_currency_pair_and_wallet) {
    auto db = fixture::open();
    auto owner = fixture::make_identity(*db);

    auto shared_icon = fixture::make_reference_icon_with_sha256(*db);
    std::string own_icon = uuidgen::v4();
    auto icon_seq = db->exec("SELECT next_seq($1)", {owner.ledger_id});
    db->exec("INSERT INTO icon (uuid, ledger_id, seq, name, content_sha256, icon_type) "
             "VALUES ($1, $2, $3, $4, decode($5, 'hex'), 0)",
             {own_icon, owner.ledger_id, icon_seq.rows.at(0).fields.at(0), "own-icon-" + own_icon,
              shared_icon.sha256_hex});

    std::string base = fixture::make_currency(*db, owner.ledger_id, own_icon);
    std::string quote = fixture::make_currency(*db, owner.ledger_id, own_icon);
    auto pair_seq = db->exec("SELECT next_seq($1)", {owner.ledger_id});
    db->exec("INSERT INTO currency_pair (uuid, ledger_id, seq, symbol, base_currency_uuid, quote_currency_uuid) "
             "VALUES ($1, $2, $3, 'X/Y', $4, $5)",
             {uuidgen::v4(), owner.ledger_id, pair_seq.rows.at(0).fields.at(0), base, quote});

    std::string wallet = add_account(*db, owner.ledger_id, own_icon);
    auto op_seq = db->exec("SELECT next_seq($1)", {owner.ledger_id});
    db->exec("INSERT INTO account_operating (uuid, ledger_id, seq, currency_uuid) VALUES ($1, $2, $3, $4)",
             {wallet, owner.ledger_id, op_seq.rows.at(0).fields.at(0), base});
    // capital-assets: кошелёк — актив; каскад account → account_operating →
    // account_asset уносит и эту строку без отдельного SET CONSTRAINTS.
    auto asset_seq = db->exec("SELECT next_seq($1)", {owner.ledger_id});
    db->exec("INSERT INTO account_asset (uuid, ledger_id, seq, asset_type) VALUES ($1, $2, $3, 1)",
             {wallet, owner.ledger_id, asset_seq.rows.at(0).fields.at(0)});
    std::string category = add_account(*db, owner.ledger_id, own_icon);
    auto operation_seq = db->exec("SELECT next_seq($1)", {owner.ledger_id});
    db->exec("INSERT INTO operation (uuid, ledger_id, seq, \"date\", acc_fr_uuid, acc_to_uuid, amount) "
             "VALUES ($1, $2, $3, now(), $4, $5, 350)",
             {uuidgen::v4(), owner.ledger_id, operation_seq.rows.at(0).fields.at(0), wallet, category});

    auto status = account_deletion_repo::delete_own_account(*db, owner.user_id);
    REQUIRE(status == account_deletion_repo::DeleteStatus::kOk);

    CHECK(!ledger_exists(*db, owner.ledger_id));
    CHECK(!account_exists(*db, owner.ledger_id, wallet));
    CHECK(db->exec("SELECT 1 FROM account_asset WHERE ledger_id = $1", {owner.ledger_id}).rows.empty());
    CHECK(db->exec("SELECT 1 FROM currency WHERE uuid IN ($1, $2)", {base, quote}).rows.empty());
    CHECK(db->exec("SELECT 1 FROM icon WHERE uuid = $1", {own_icon}).rows.empty());
    CHECK(!change_stream_exists(*db, owner.ledger_id));
    CHECK(!app_user_exists(*db, owner.user_id));
    // Общая иконка и blob — не данные леджера, каскад их не трогает.
    CHECK(!db->exec("SELECT 1 FROM icon WHERE uuid = $1", {shared_icon.uuid}).rows.empty());
}

// Жёсткий DELETE используемой валюты вне delete_own_account по-прежнему
// отклоняется сразу: ключ DEFERRABLE, но INITIALLY IMMEDIATE.
// change debts, задача 3.6: контрагенты (в том числе со своей иконкой
// леджера) и долговые кошельки уходят вместе с леджером. Каскад идёт двумя
// ветками — ledger → counterparty и ledger → account → account_operating →
// account_debt, — поэтому fk_account_debt_counterparty и fk_counterparty_icon
// отложены до COMMIT (account_deletion_repo).
TEST(delete_own_account_wipes_ledger_with_counterparties_and_debts) {
    auto db = fixture::open();
    auto owner = fixture::make_identity(*db);

    auto shared_icon = fixture::make_reference_icon_with_sha256(*db);
    std::string own_icon = uuidgen::v4();
    auto icon_seq = db->exec("SELECT next_seq($1)", {owner.ledger_id});
    db->exec("INSERT INTO icon (uuid, ledger_id, seq, name, content_sha256, icon_type) "
             "VALUES ($1, $2, $3, $4, decode($5, 'hex'), 0)",
             {own_icon, owner.ledger_id, icon_seq.rows.at(0).fields.at(0), "own-icon-" + own_icon,
              shared_icon.sha256_hex});
    std::string currency = fixture::make_currency(*db, owner.ledger_id, own_icon);

    std::string counterparty = uuidgen::v4();
    std::string archived = uuidgen::v4();
    auto cp_seq = db->exec("SELECT next_seq($1)", {owner.ledger_id});
    db->exec("INSERT INTO counterparty (uuid, ledger_id, seq, name, icon_uuid) VALUES ($1, $2, $3, $4, $5)",
             {counterparty, owner.ledger_id, cp_seq.rows.at(0).fields.at(0), "Вася " + counterparty, own_icon});
    db->exec("INSERT INTO counterparty (uuid, ledger_id, seq, name, is_archived, deleted_at) "
             "VALUES ($1, $2, $3, $4, true, now())",
             {archived, owner.ledger_id, cp_seq.rows.at(0).fields.at(0), "Петя " + archived});

    std::string loan1 = add_account(*db, owner.ledger_id, own_icon);
    std::string loan2 = add_account(*db, owner.ledger_id, own_icon);
    for (const auto& wallet : {loan1, loan2}) {
        auto seq = db->exec("SELECT next_seq($1)", {owner.ledger_id}).rows.at(0).fields.at(0);
        db->exec("INSERT INTO account_operating (uuid, ledger_id, seq, currency_uuid) VALUES ($1, $2, $3, $4)",
                 {wallet, owner.ledger_id, seq, currency});
        db->exec("INSERT INTO account_debt (uuid, ledger_id, seq, counterparty_uuid, due_date) "
                 "VALUES ($1, $2, $3, $4, '2026-12-31')",
                 {wallet, owner.ledger_id, seq, counterparty});
    }

    auto status = account_deletion_repo::delete_own_account(*db, owner.user_id);
    REQUIRE(status == account_deletion_repo::DeleteStatus::kOk);

    CHECK(!ledger_exists(*db, owner.ledger_id));
    CHECK(db->exec("SELECT 1 FROM account_debt WHERE ledger_id = $1", {owner.ledger_id}).rows.empty());
    CHECK(db->exec("SELECT 1 FROM counterparty WHERE ledger_id = $1", {owner.ledger_id}).rows.empty());
    CHECK(db->exec("SELECT 1 FROM icon WHERE uuid = $1", {own_icon}).rows.empty());
    CHECK(!change_stream_exists(*db, owner.ledger_id));
    CHECK(!app_user_exists(*db, owner.user_id));
}

TEST(hard_delete_of_currency_used_by_wallet_is_still_rejected) {
    auto db = fixture::open();
    auto owner = fixture::make_identity(*db);
    std::string icon = fixture::make_reference_icon(*db);
    std::string currency = fixture::make_currency(*db, owner.ledger_id, icon);
    std::string wallet = add_account(*db, owner.ledger_id, icon);
    auto op_seq = db->exec("SELECT next_seq($1)", {owner.ledger_id});
    db->exec("INSERT INTO account_operating (uuid, ledger_id, seq, currency_uuid) VALUES ($1, $2, $3, $4)",
             {wallet, owner.ledger_id, op_seq.rows.at(0).fields.at(0), currency});

    bool caught_fk_violation = false;
    try {
        db->exec("DELETE FROM currency WHERE uuid = $1", {currency});
    } catch (const db::QueryError& e) {
        caught_fk_violation = e.sqlstate == "23503";
    }
    CHECK(caught_fk_violation);
    CHECK(!db->exec("SELECT 1 FROM currency WHERE uuid = $1", {currency}).rows.empty());
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
