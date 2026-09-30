// Логика доступа/приглашений в леджер (org/docs/TODO_mobile_sync.md, Фаза 6,
// пп. 9.1-9.3) — отделена от HTTP-слоя (invites.hpp/.cpp) тем же приёмом,
// что sync_repo.hpp/reports_repo.hpp отделены от своих HTTP-слоёв: без
// httplib в сигнатурах, можно проверить интеграционным тестом напрямую.
//
// В отличие от sync/*, здесь НЕ требуется claim device_id — обычный
// браузерный вход годится не хуже мобильного (то же решение, что у
// /sync/blobs и у отчётов, см. reports.hpp).
#pragma once

#include <optional>
#include <string>
#include <vector>

#include "db.hpp"

namespace invites_repo {

// Роль текущего пользователя в ЕГО ЕДИНСТВЕННОМ леджере (MVP — один леджер
// на пользователя, см. org/docs/TODO_mobile_sync.md, п. 1.3). nullopt — у
// пользователя ещё нет ни одного леджера (это read-only путь — в отличие от
// provisioning::ensure_identity, ничего не создаёт; тот же принцип, что
// reports_repo::find_ledger_for_user).
struct Membership {
    std::string ledger_id;
    std::string role; // 'owner' | 'member' | 'reader'
};
std::optional<Membership> find_membership(db::Database& db, const std::string& user_id);

// Участник леджера для экрана "Доступ и приглашения". Без отдельного поля
// "имя" — app_user хранит только email (см. wallet-api/schema/table/app_user.sql,
// "проще, чем предполагалось"): сервер никогда не видит человекочитаемое имя
// ДРУГОГО пользователя, только своё (claim в СВОЁМ JWT). Веб-экран (Фаза 6,
// п. 9.5) показывает email там, где макет предполагал имя.
struct MemberRow {
    std::string user_id;
    std::string email;
    std::string role;
    std::string joined_at; // ISO-8601 UTC, "...Z"
};
std::vector<MemberRow> list_members(db::Database& db, const std::string& ledger_id);

// false — под user_id в этом леджере нет строки, ЛИБО эта строка — owner
// (роль owner меняется только через transfer_owner ниже, никогда через этот
// путь: 0 совпавших строк в обоих случаях, вызывающий код отвечает 404, не
// различая их — та же логика, что not_found в wallet.cpp).
bool set_member_role(db::Database& db, const std::string& ledger_id, const std::string& user_id,
                      const std::string& new_role);

// false — под user_id в этом леджере нет строки, ЛИБО эта строка — owner
// (владельца нельзя удалить этим путём — тот же смысл, что у set_member_role
// выше).
bool remove_member(db::Database& db, const std::string& ledger_id, const std::string& user_id);

enum class TransferStatus {
    kOk,
    kCallerNotOwner,  // caller_user_id не владелец ЭТОГО леджера прямо сейчас
    kTargetNotMember, // target_user_id — не участник этого леджера вовсе
};

// Одна транзакция, ДВА последовательных UPDATE (не один CASE) — см.
// org/docs/TODO_mobile_sync.md, п. 9.3, почему один CASE рискует временным
// дублем owner'а на частичном уникальном индексе uq_ledger_member_owner.
// Порядок проверок внутри устроен так, что леджер ни на миг не остаётся без
// владельца: если target вообще не участник, транзакция откатывается ДО
// того, как caller лишился роли owner (см. .cpp).
TransferStatus transfer_owner(db::Database& db, const std::string& ledger_id,
                               const std::string& caller_user_id,
                               const std::string& target_user_id);

// Сырой токен — только здесь и в JSON-ответе HTTP-слоя на создание; в БД не
// попадает вовсе (см. wallet-api/schema/table/ledger_invite.sql). role уже
// провалидирована вызывающим кодом (см. invites.hpp) как 'member'/'reader'.
struct CreatedInvite {
    std::string id;
    std::string role;
    std::string token; // hex, кладётся в ссылку как есть
    std::string created_at;
    std::string expires_at;
};
CreatedInvite create_invite(db::Database& db, const std::string& ledger_id,
                             const std::string& created_by, const std::string& role,
                             int ttl_days);

// Только активные (см. wallet-api/schema/table/ledger_invite.sql, "Активно не
// хранится отдельным полем") — БЕЗ самого токена: он не хранится, повторно
// показать нечего (см. org/docs/TODO_mobile_sync.md, п. 9.3, отступление от
// макета).
struct InviteSummary {
    std::string id;
    std::string role;
    std::string created_at;
    std::string expires_at;
};
std::vector<InviteSummary> list_active_invites(db::Database& db, const std::string& ledger_id);

// false — приглашения с таким id либо нет в этом леджере, либо оно уже не
// активно (использовано/просрочено/уже отозвано).
bool revoke_invite(db::Database& db, const std::string& ledger_id, const std::string& invite_id);

enum class AcceptStatus {
    kOk,
    kInvalidOrExpired, // токен не найден / использован / отозван / просрочен
    kAlreadyHasLedger, // MVP: один леджер на пользователя (см. п. 1.3) — приглашение НЕ расходуется
};
struct AcceptResult {
    AcceptStatus status;
    std::string ledger_id; // заполнено только при kOk
    std::string role;      // заполнено только при kOk
};

// email — как upsert_user в provisioning.cpp: кэш claim'а из токена,
// подтягивается на каждый вызов. Гонка с ДРУГИМ одновременным accept ДЛЯ
// ТОГО ЖЕ user_id (два разных приглашения в два разных леджера) теоретически
// возможна — тот же принятый риск, что в provisioning.cpp::ensure_identity,
// см. .cpp.
AcceptResult accept_invite(db::Database& db, const std::string& user_id, const std::string& email,
                            const std::string& raw_token);

} // namespace invites_repo
