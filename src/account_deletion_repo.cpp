#include "account_deletion_repo.hpp"

#include <vector>

namespace account_deletion_repo {

namespace {

bool has_other_members(db::Database::Transaction& tx, const std::string& ledger_id,
                        const std::string& user_id) {
    auto res = tx.exec(
        "SELECT EXISTS (SELECT 1 FROM ledger_member WHERE ledger_id = $1 AND user_id <> $2)",
        {ledger_id, user_id});
    return res.rows.at(0).fields.at(0) == "t";
}

} // namespace

DeleteStatus delete_own_account(db::Database& db, const std::string& user_id) {
    auto tx = db.begin_transaction();

    auto owned = tx.exec("SELECT ledger_id FROM ledger_member WHERE user_id = $1 AND role = 'owner'",
                          {user_id});
    std::vector<std::string> owned_ledger_ids;
    owned_ledger_ids.reserve(owned.rows.size());
    for (const auto& row : owned.rows) owned_ledger_ids.push_back(row.fields.at(0));

    // Проверяем ВСЕ владения ДО единого DELETE — отказ должен ничего не
    // тронуть, не только откатить уже начатое (см. комментарий в .hpp,
    // "либо всё... либо не трогается вовсе").
    for (const auto& ledger_id : owned_ledger_ids) {
        if (has_other_members(tx, ledger_id, user_id)) {
            return DeleteStatus::kOwnsSharedLedger; // tx разрушится не закоммиченной — ROLLBACK
        }
    }

    for (const auto& ledger_id : owned_ledger_ids) {
        // ON DELETE CASCADE (wallet-api/schema/table/*.sql) снимает разом
        // ledger_member/ledger_invite/device/account/account_operating/
        // operation/operation_link/sync_push_batch/currency/currency_pair/
        // currency_pair_rate ЭТОГО леджера — см. .hpp, почему одним DELETE,
        // не десятком построчных.
        tx.exec("DELETE FROM ledger WHERE id = $1", {ledger_id});
        // ledger.id REFERENCES change_stream ON DELETE RESTRICT (ledger.sql)
        // — только теперь, когда ссылающейся строки ledger уже нет.
        tx.exec("DELETE FROM change_stream WHERE id = $1", {ledger_id});
    }

    // Каскадом снимает членство ЭТОГО user_id в ЧУЖИХ леджерах (просто
    // участник — "выйти из общего кошелька", не трогая сам леджер и данные
    // остальных), любые оставшиеся device и ledger_invite created_by/used_by.
    // Не ошибка, если строки уже нет (idempotent) — DELETE ... WHERE просто
    // не находит строк.
    tx.exec("DELETE FROM app_user WHERE id = $1", {user_id});

    tx.commit();
    return DeleteStatus::kOk;
}

} // namespace account_deletion_repo
