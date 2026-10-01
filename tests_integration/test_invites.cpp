// Интеграционные тесты invites_repo.hpp против ЖИВОГО Postgres (Фаза 6,
// org/docs/TODO_mobile_sync.md, п. 9.6) — тем же приёмом, что
// test_push_batch.cpp зовёт sync_repo::push_batch()/pull_*_stream()
// напрямую: HTTP-слой (invites.hpp/.cpp — session::current_user, парсинг
// JSON тела, коды ответа) сюда намеренно не входит, тем же обоснованием,
// что и у sync.cpp в CMakeLists.txt рядом ("тянет httplib::Request/
// Response, тестам это не нужно"). В частности, "не-owner получает 403"
// здесь НЕ тестируется отдельно — эта проверка (`require_owner` в
// invites.cpp) однострочная (`role != "owner"`) и живёт целиком в
// HTTP-слое, а не в invites_repo; то же самое разделение ответственности,
// что уже принято для device_id/403 у authenticate_and_provision (см. её
// комментарий в CMakeLists.txt).
#include "invites_repo.hpp"

#include <algorithm>
#include <cstddef>
#include <string>

#include "fixture.hpp"
#include "provisioning.hpp"
#include "test_framework.hpp"
#include "util/uuid.hpp"

namespace {

// Добавляет участника НАПРЯМУЮ SQL, в обход invites_repo::accept_invite —
// нужен там, где тесту важен ГОТОВЫЙ второй/третий участник ОДНОГО и того
// же леджера (fixture::make_identity каждый раз заводит СВОЙ, отдельный
// леджер — см. её комментарий), а не сам путь приёма приглашения. Тот же
// приём, что fixture::make_reference_icon() — прямая вставка вместо
// прогона настоящего протокола там, где протокол не то, что проверяется.
std::string add_member(db::Database& db, const std::string& ledger_id, const std::string& role) {
    std::string user_id = uuidgen::v4();
    db.exec("INSERT INTO app_user (id, email) VALUES ($1, $2)",
            {user_id, "member-" + user_id + "@example.com"});
    db.exec("INSERT INTO ledger_member (ledger_id, user_id, role) VALUES ($1, $2, $3)",
            {ledger_id, user_id, role});
    return user_id;
}

// "Состарить" уже созданное приглашение так, чтобы оно оказалось
// просроченным ПРЯМО СЕЙЧАС — просто отодвинуть expires_at в прошлое
// нельзя: CHECK ck... requires expires_at > created_at (см. миграцию), и
// created_at тоже был выставлен только что настоящим create_invite().
// Отодвигаем ОБА на двое суток в прошлое — сохраняет инвариант
// (expires_at всё ещё позже created_at) и одновременно делает
// expires_at < now().
void force_expired(db::Database& db, const std::string& invite_id) {
    db.exec("UPDATE ledger_invite SET created_at = now() - interval '2 days', "
            "expires_at = now() - interval '1 day' WHERE id = $1",
            {invite_id});
}

std::size_t count_owners(db::Database& db, const std::string& ledger_id) {
    auto res = db.exec("SELECT count(*) FROM ledger_member WHERE ledger_id = $1 AND role = 'owner'",
                        {ledger_id});
    return static_cast<std::size_t>(std::stoul(res.rows.at(0).fields.at(0)));
}

} // namespace

TEST(create_invite_then_accept_grants_membership_with_chosen_role) {
    auto db = fixture::open();
    auto owner = fixture::make_identity(*db);

    auto invite = invites_repo::create_invite(*db, owner.ledger_id, owner.user_id, "reader", 7);
    CHECK_EQ(invite.role, std::string("reader"));
    CHECK(!invite.token.empty());

    // Пользователь, который ни разу раньше не обращался к wallet-api —
    // ровно сценарий "чистый браузерный вход" (см. invites_repo.hpp,
    // accept_invite): app_user для него ещё не существует.
    std::string new_user_id = uuidgen::v4();
    auto result = invites_repo::accept_invite(*db, new_user_id, "newbie@example.com", invite.token);

    REQUIRE(result.status == invites_repo::AcceptStatus::kOk);
    CHECK_EQ(result.ledger_id, owner.ledger_id);
    CHECK_EQ(result.role, std::string("reader"));

    auto members = invites_repo::list_members(*db, owner.ledger_id);
    auto it = std::find_if(members.begin(), members.end(),
                            [&](const invites_repo::MemberRow& m) { return m.user_id == new_user_id; });
    REQUIRE(it != members.end());
    CHECK_EQ(it->role, std::string("reader"));
    CHECK_EQ(it->email, std::string("newbie@example.com"));
}

TEST(accept_same_token_twice_second_attempt_is_invalid) {
    auto db = fixture::open();
    auto owner = fixture::make_identity(*db);
    auto invite = invites_repo::create_invite(*db, owner.ledger_id, owner.user_id, "member", 7);

    auto first = invites_repo::accept_invite(*db, uuidgen::v4(), "first@example.com", invite.token);
    REQUIRE(first.status == invites_repo::AcceptStatus::kOk);

    // Другой пользователь пробует ТЕМ ЖЕ токеном — ссылка одноразовая (см.
    // wallet-api/schema/table/ledger_invite.sql).
    auto second = invites_repo::accept_invite(*db, uuidgen::v4(), "second@example.com", invite.token);
    CHECK(second.status == invites_repo::AcceptStatus::kInvalidOrExpired);
}

TEST(accept_revoked_invite_is_invalid) {
    auto db = fixture::open();
    auto owner = fixture::make_identity(*db);
    auto invite = invites_repo::create_invite(*db, owner.ledger_id, owner.user_id, "member", 7);

    CHECK(invites_repo::revoke_invite(*db, owner.ledger_id, invite.id));

    auto result = invites_repo::accept_invite(*db, uuidgen::v4(), "late@example.com", invite.token);
    CHECK(result.status == invites_repo::AcceptStatus::kInvalidOrExpired);
}

TEST(revoke_invite_twice_second_call_returns_false) {
    auto db = fixture::open();
    auto owner = fixture::make_identity(*db);
    auto invite = invites_repo::create_invite(*db, owner.ledger_id, owner.user_id, "member", 2);

    CHECK(invites_repo::revoke_invite(*db, owner.ledger_id, invite.id));
    // Уже не активно — второй "Отозвать" не должен молча "сработать" ещё раз.
    CHECK(!invites_repo::revoke_invite(*db, owner.ledger_id, invite.id));
}

TEST(accept_expired_invite_is_invalid) {
    auto db = fixture::open();
    auto owner = fixture::make_identity(*db);
    auto invite = invites_repo::create_invite(*db, owner.ledger_id, owner.user_id, "member", 2);
    force_expired(*db, invite.id);

    auto result = invites_repo::accept_invite(*db, uuidgen::v4(), "toolate@example.com", invite.token);
    CHECK(result.status == invites_repo::AcceptStatus::kInvalidOrExpired);
}

TEST(list_active_invites_excludes_used_revoked_and_expired) {
    auto db = fixture::open();
    auto owner = fixture::make_identity(*db);

    auto active = invites_repo::create_invite(*db, owner.ledger_id, owner.user_id, "reader", 7);
    auto used = invites_repo::create_invite(*db, owner.ledger_id, owner.user_id, "reader", 7);
    auto revoked = invites_repo::create_invite(*db, owner.ledger_id, owner.user_id, "reader", 7);
    auto expired = invites_repo::create_invite(*db, owner.ledger_id, owner.user_id, "reader", 7);

    REQUIRE(invites_repo::accept_invite(*db, uuidgen::v4(), "u@example.com", used.token).status ==
            invites_repo::AcceptStatus::kOk);
    CHECK(invites_repo::revoke_invite(*db, owner.ledger_id, revoked.id));
    force_expired(*db, expired.id);

    auto list = invites_repo::list_active_invites(*db, owner.ledger_id);
    REQUIRE(list.size() == static_cast<std::size_t>(1));
    CHECK_EQ(list.at(0).id, active.id);
}

TEST(accept_when_already_has_a_ledger_is_rejected_and_invite_stays_active) {
    auto db = fixture::open();
    auto owner = fixture::make_identity(*db);
    auto invite = invites_repo::create_invite(*db, owner.ledger_id, owner.user_id, "member", 7);

    // already_owner — уже владелец СВОЕГО, отдельного леджера (см.
    // fixture::make_identity) — MVP держит инвариант "один леджер на
    // пользователя" (org/docs/TODO_mobile_sync.md, п. 1.3/9.3).
    auto already_owner = fixture::make_identity(*db);
    auto rejected = invites_repo::accept_invite(*db, already_owner.user_id, "owner2@example.com",
                                                 invite.token);
    CHECK(rejected.status == invites_repo::AcceptStatus::kAlreadyHasLedger);

    // Приглашение НЕ израсходовано отказом — годится следующему, у кого
    // леджера ещё нет (см. invites_repo.hpp, accept_invite).
    auto ok = invites_repo::accept_invite(*db, uuidgen::v4(), "fresh@example.com", invite.token);
    CHECK(ok.status == invites_repo::AcceptStatus::kOk);
    CHECK_EQ(ok.ledger_id, owner.ledger_id);
}

TEST(accept_replacing_empty_ledger_deletes_it_and_joins_invited_one) {
    auto db = fixture::open();
    auto owner = fixture::make_identity(*db);
    auto invite = invites_repo::create_invite(*db, owner.ledger_id, owner.user_id, "member", 7);

    // make_identity заводит леджер, но ничего в него не пишет — seq = 0.
    auto joiner = fixture::make_identity(*db);
    auto first = invites_repo::accept_invite(*db, joiner.user_id, "j@example.com", invite.token);
    CHECK(first.status == invites_repo::AcceptStatus::kAlreadyHasLedger);
    CHECK(first.ledger_empty);

    auto ok = invites_repo::accept_invite(*db, joiner.user_id, "j@example.com", invite.token, true);
    REQUIRE(ok.status == invites_repo::AcceptStatus::kOk);
    CHECK_EQ(ok.ledger_id, owner.ledger_id);
    CHECK_EQ(ok.role, std::string("member"));

    CHECK(db->exec("SELECT 1 FROM ledger WHERE id = $1", {joiner.ledger_id}).rows.empty());
    CHECK(db->exec("SELECT 1 FROM change_stream WHERE id = $1", {joiner.ledger_id}).rows.empty());
    auto membership = invites_repo::find_membership(*db, joiner.user_id);
    REQUIRE(membership.has_value());
    CHECK_EQ(membership->ledger_id, owner.ledger_id);
}

TEST(accept_replacing_non_empty_ledger_is_rejected_and_nothing_changes) {
    auto db = fixture::open();
    auto owner = fixture::make_identity(*db);
    auto invite = invites_repo::create_invite(*db, owner.ledger_id, owner.user_id, "member", 7);

    auto joiner = fixture::make_identity(*db);
    db->exec("SELECT next_seq($1)", {joiner.ledger_id}); // был хотя бы один push

    auto first = invites_repo::accept_invite(*db, joiner.user_id, "j@example.com", invite.token);
    CHECK(first.status == invites_repo::AcceptStatus::kAlreadyHasLedger);
    CHECK(!first.ledger_empty);

    auto forced = invites_repo::accept_invite(*db, joiner.user_id, "j@example.com", invite.token, true);
    CHECK(forced.status == invites_repo::AcceptStatus::kAlreadyHasLedger);
    CHECK_EQ(invites_repo::find_membership(*db, joiner.user_id)->ledger_id, joiner.ledger_id);

    // Приглашение не израсходовано.
    auto ok = invites_repo::accept_invite(*db, uuidgen::v4(), "fresh@example.com", invite.token);
    CHECK(ok.status == invites_repo::AcceptStatus::kOk);
}

TEST(accept_replacing_ledger_with_other_members_is_rejected) {
    auto db = fixture::open();
    auto owner = fixture::make_identity(*db);
    auto invite = invites_repo::create_invite(*db, owner.ledger_id, owner.user_id, "member", 7);

    // seq = 0, но в леджере есть кто-то ещё — удалять нельзя.
    auto joiner = fixture::make_identity(*db);
    add_member(*db, joiner.ledger_id, "reader");

    auto first = invites_repo::accept_invite(*db, joiner.user_id, "j@example.com", invite.token);
    CHECK(!first.ledger_empty);
    auto forced = invites_repo::accept_invite(*db, joiner.user_id, "j@example.com", invite.token, true);
    CHECK(forced.status == invites_repo::AcceptStatus::kAlreadyHasLedger);
    CHECK(!db->exec("SELECT 1 FROM ledger WHERE id = $1", {joiner.ledger_id}).rows.empty());
}

TEST(set_member_role_ignores_owner_row_but_updates_real_member) {
    auto db = fixture::open();
    auto owner = fixture::make_identity(*db);
    std::string member_id = add_member(*db, owner.ledger_id, "member");

    // Попытка сменить роль СТРОКИ ВЛАДЕЛЬЦА этим путём — 0 совпавших строк
    // (WHERE role <> 'owner', см. invites_repo.cpp), не полутайное "тихо
    // ничего не сделал, но вернул успех".
    CHECK(!invites_repo::set_member_role(*db, owner.ledger_id, owner.user_id, "reader"));

    CHECK(invites_repo::set_member_role(*db, owner.ledger_id, member_id, "reader"));
    auto members = invites_repo::list_members(*db, owner.ledger_id);
    auto it = std::find_if(members.begin(), members.end(),
                            [&](const invites_repo::MemberRow& m) { return m.user_id == member_id; });
    REQUIRE(it != members.end());
    CHECK_EQ(it->role, std::string("reader"));
}

TEST(remove_member_cannot_remove_owner_but_removes_real_member) {
    auto db = fixture::open();
    auto owner = fixture::make_identity(*db);
    std::string member_id = add_member(*db, owner.ledger_id, "member");

    CHECK(!invites_repo::remove_member(*db, owner.ledger_id, owner.user_id));
    CHECK(invites_repo::remove_member(*db, owner.ledger_id, member_id));

    auto members = invites_repo::list_members(*db, owner.ledger_id);
    CHECK(std::none_of(members.begin(), members.end(),
                        [&](const invites_repo::MemberRow& m) { return m.user_id == member_id; }));
}

TEST(transfer_owner_happy_path_swaps_roles_atomically) {
    auto db = fixture::open();
    auto owner = fixture::make_identity(*db);
    std::string member_id = add_member(*db, owner.ledger_id, "member");

    auto status = invites_repo::transfer_owner(*db, owner.ledger_id, owner.user_id, member_id);
    REQUIRE(status == invites_repo::TransferStatus::kOk);

    auto members = invites_repo::list_members(*db, owner.ledger_id);
    auto new_owner = std::find_if(members.begin(), members.end(),
                                   [&](const invites_repo::MemberRow& m) { return m.user_id == member_id; });
    auto old_owner = std::find_if(members.begin(), members.end(),
                                   [&](const invites_repo::MemberRow& m) { return m.user_id == owner.user_id; });
    REQUIRE(new_owner != members.end());
    REQUIRE(old_owner != members.end());
    CHECK_EQ(new_owner->role, std::string("owner"));
    CHECK_EQ(old_owner->role, std::string("member"));
    // uq_ledger_member_owner — ровно один владелец в любой момент (см.
    // wallet-api/schema/table/ledger_member.sql).
    CHECK_EQ(count_owners(*db, owner.ledger_id), static_cast<std::size_t>(1));
}

TEST(transfer_owner_reader_can_become_owner_directly) {
    // Решённый в 9.3/9.7 открытый вопрос: reader НЕ обязан сперва стать
    // member — исходная роль цели не проверяется, только факт членства.
    auto db = fixture::open();
    auto owner = fixture::make_identity(*db);
    std::string reader_id = add_member(*db, owner.ledger_id, "reader");

    auto status = invites_repo::transfer_owner(*db, owner.ledger_id, owner.user_id, reader_id);
    REQUIRE(status == invites_repo::TransferStatus::kOk);

    auto membership = invites_repo::find_membership(*db, reader_id);
    REQUIRE(membership.has_value());
    CHECK_EQ(membership->role, std::string("owner"));
}

TEST(transfer_owner_caller_not_owner_is_rejected_without_side_effects) {
    auto db = fixture::open();
    auto owner = fixture::make_identity(*db);
    std::string member_id = add_member(*db, owner.ledger_id, "member");
    std::string other_id = add_member(*db, owner.ledger_id, "reader");

    // member_id — не владелец; пытается передать владение третьему.
    auto status = invites_repo::transfer_owner(*db, owner.ledger_id, member_id, other_id);
    CHECK(status == invites_repo::TransferStatus::kCallerNotOwner);

    // Ничего не поменялось — настоящий владелец всё ещё владелец.
    auto membership = invites_repo::find_membership(*db, owner.user_id);
    REQUIRE(membership.has_value());
    CHECK_EQ(membership->role, std::string("owner"));
    CHECK_EQ(count_owners(*db, owner.ledger_id), static_cast<std::size_t>(1));
}

TEST(transfer_owner_target_not_member_is_rejected_owner_unchanged) {
    auto db = fixture::open();
    auto owner = fixture::make_identity(*db);
    std::string stranger_id = uuidgen::v4(); // ни разу не появлялся в этом леджере

    // Порядок проверок в transfer_owner (см. invites_repo.cpp) — target
    // проверяется ДО того, как caller лишается роли owner: леджер ни на миг
    // не должен остаться без владельца.
    auto status = invites_repo::transfer_owner(*db, owner.ledger_id, owner.user_id, stranger_id);
    CHECK(status == invites_repo::TransferStatus::kTargetNotMember);

    auto membership = invites_repo::find_membership(*db, owner.user_id);
    REQUIRE(membership.has_value());
    CHECK_EQ(membership->role, std::string("owner"));
    CHECK_EQ(count_owners(*db, owner.ledger_id), static_cast<std::size_t>(1));
}

TEST(create_invite_rejects_owner_role_via_check_constraint) {
    auto db = fixture::open();
    auto owner = fixture::make_identity(*db);
    // ledger_invite.role CHECK IN ('member','reader') — второго owner'а
    // ссылкой не пригласить (см. миграцию 000016_ledger_invite).
    CHECK_THROWS(invites_repo::create_invite(*db, owner.ledger_id, owner.user_id, "owner", 7));
}
