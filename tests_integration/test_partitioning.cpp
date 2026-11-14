// Интеграционные тесты секционирования operation/operation_link (change
// partition-operation-by-ledger, миграция 000040) против ЖИВОГО Postgres.
//
// Проверяют не сам DDL (его сверяет up→down→up в задачах change), а то, что
// обещает спека ledger-data-storage: строки одного леджера лежат в секциях с
// одним номером, любой новый леджер принимается, контракт таблиц для кода не
// изменился (идемпотентность по (ledger_id, uuid), чужой счёт, каскады) и
// запросы одного леджера читают ровно одну секцию.
#include <cctype>
#include <set>
#include <string>
#include <vector>

#include "account_deletion_repo.hpp"
#include "fixture.hpp"
#include "nlohmann/json.hpp"
#include "sync_repo.hpp"
#include "test_framework.hpp"
#include "util/uuid.hpp"

namespace {

using json = nlohmann::json;

// Строка account напрямую SQL — как add_account в test_account_deletion.cpp.
std::string add_account(db::Database& db, const std::string& ledger_id, const std::string& icon_uuid) {
    std::string uuid = uuidgen::v4();
    auto seq_res = db.exec("SELECT next_seq($1)", {ledger_id});
    db.exec("INSERT INTO account (uuid, ledger_id, seq, name, icon_uuid) VALUES ($1,$2,$3,$4,$5)",
            {uuid, ledger_id, seq_res.rows.at(0).fields.at(0), "wallet-" + uuid, icon_uuid});
    return uuid;
}

json operation_row(const std::string& uuid, const std::string& acc_fr, const std::string& acc_to,
                   const std::string& comment = "") {
    return json{{"uuid", uuid},           {"date", "2026-11-14T12:00:00"}, {"acc_fr_uuid", acc_fr},
                {"acc_to_uuid", acc_to},  {"amount", "10.00"},             {"comment", comment}};
}

json link_row(const std::string& uuid, const std::string& main_uuid, const std::string& link_uuid) {
    return json{{"uuid", uuid}, {"main_uuid", main_uuid}, {"link_uuid", link_uuid}, {"type", 0}};
}

struct Ledger {
    fixture::TestIdentity id;
    std::string icon;
    std::string acc_fr;
    std::string acc_to;
};

Ledger make_ledger(db::Database& db) {
    Ledger l;
    l.id = fixture::make_identity(db);
    l.icon = fixture::make_reference_icon(db);
    l.acc_fr = add_account(db, l.id.ledger_id, l.icon);
    l.acc_to = add_account(db, l.id.ledger_id, l.icon);
    return l;
}

sync_repo::PushOutcome push(db::Database& db, const Ledger& l, const json& changes) {
    return sync_repo::push_batch(db, l.id.ledger_id, l.id.device_id, uuidgen::v4(), changes);
}

// Секции, в которых лежат строки леджера (имена таблиц, не OID).
std::set<std::string> partitions_of(db::Database& db, const std::string& table, const std::string& ledger_id) {
    auto res = db.exec("SELECT DISTINCT tableoid::regclass::text FROM " + table + " WHERE ledger_id = $1",
                       {ledger_id});
    std::set<std::string> out;
    for (const auto& row : res.rows) out.insert(row.fields.at(0));
    return out;
}

// Номер секции — два последних символа имени (operation_p05 → "05").
std::string partition_number(const std::string& partition_name) {
    return partition_name.substr(partition_name.size() - 2);
}

std::string count_of(db::Database& db, const std::string& sql, const std::vector<std::string>& params) {
    return db.exec(sql, params).rows.at(0).fields.at(0);
}

// Все имена секций operation_pNN/operation_link_pNN, упомянутые в тексте плана.
std::set<std::string> partitions_in_plan(const std::string& plan, const std::string& prefix) {
    std::set<std::string> out;
    for (size_t pos = plan.find(prefix); pos != std::string::npos; pos = plan.find(prefix, pos + 1)) {
        size_t end = pos + prefix.size();
        while (end < plan.size() && std::isdigit(static_cast<unsigned char>(plan[end]))) ++end;
        out.insert(plan.substr(pos, end - pos));
    }
    return out;
}

std::string explain(db::Database& db, const std::string& sql, const std::vector<std::string>& params) {
    auto res = db.exec(sql, params);
    std::string plan;
    for (const auto& row : res.rows) plan += row.fields.at(0) + "\n";
    return plan;
}

} // namespace

TEST(partitioning_operations_and_links_of_one_ledger_share_partition_number) {
    auto db = fixture::open();
    for (int i = 0; i < 2; ++i) {
        auto l = make_ledger(*db);
        std::string main = uuidgen::v4(), leg = uuidgen::v4(), fee = uuidgen::v4();
        json changes = {
            {"operation", json::array({operation_row(main, l.acc_fr, l.acc_to),
                                       operation_row(leg, l.acc_fr, l.acc_to),
                                       operation_row(fee, l.acc_fr, l.acc_to)})},
            {"operation_link", json::array({link_row(uuidgen::v4(), main, leg),
                                            link_row(uuidgen::v4(), main, fee)})},
        };
        auto outcome = push(*db, l, changes);
        REQUIRE(outcome.http_status == 200);

        auto op_parts = partitions_of(*db, "operation", l.id.ledger_id);
        auto link_parts = partitions_of(*db, "operation_link", l.id.ledger_id);
        REQUIRE(op_parts.size() == 1);
        REQUIRE(link_parts.size() == 1);
        CHECK_EQ(partition_number(*link_parts.begin()), partition_number(*op_parts.begin()));
        CHECK(op_parts.begin()->rfind("operation_p", 0) == 0);
        CHECK(link_parts.begin()->rfind("operation_link_p", 0) == 0);
    }
}

TEST(partitioning_any_new_ledger_accepts_its_first_operation) {
    auto db = fixture::open();
    // Ledger id случайный (gen_random_uuid/uuidgen) — по 20 леджеров попадают в разные
    // секции; любой остаток обязан иметь секцию, иначе «no partition of relation found».
    std::set<std::string> seen;
    for (int i = 0; i < 20; ++i) {
        auto l = make_ledger(*db);
        auto outcome = push(*db, l, {{"operation", json::array({operation_row(uuidgen::v4(), l.acc_fr, l.acc_to)})}});
        CHECK_EQ(outcome.http_status, 200);
        for (const auto& p : partitions_of(*db, "operation", l.id.ledger_id)) seen.insert(p);
    }
    CHECK(seen.size() > 1);
}

TEST(partitioning_repeated_push_of_same_operation_does_not_duplicate) {
    auto db = fixture::open();
    auto l = make_ledger(*db);
    std::string op = uuidgen::v4();

    auto first = push(*db, l, {{"operation", json::array({operation_row(op, l.acc_fr, l.acc_to, "one")})}});
    REQUIRE(first.http_status == 200);
    // Другой batch_id, тот же (ledger_id, uuid): ON CONFLICT (ledger_id, uuid) обновляет строку.
    auto second = push(*db, l, {{"operation", json::array({operation_row(op, l.acc_fr, l.acc_to, "two")})}});
    CHECK_EQ(second.http_status, 200);

    CHECK_EQ(count_of(*db, "SELECT count(*) FROM operation WHERE ledger_id = $1 AND uuid = $2",
                      {l.id.ledger_id, op}),
             std::string("1"));
    CHECK_EQ(count_of(*db, "SELECT comment FROM operation WHERE ledger_id = $1 AND uuid = $2",
                      {l.id.ledger_id, op}),
             std::string("two"));
}

TEST(partitioning_foreign_ledger_account_is_rejected_with_missing_reference) {
    auto db = fixture::open();
    auto mine = make_ledger(*db);
    auto other = make_ledger(*db);

    auto outcome = push(*db, mine, {{"operation", json::array({operation_row(uuidgen::v4(), other.acc_fr, other.acc_to)})}});
    CHECK_EQ(outcome.http_status, 409);
    auto body = json::parse(outcome.response_body);
    CHECK_EQ(body.at("error").get<std::string>(), std::string("missing_reference"));
    CHECK_EQ(count_of(*db, "SELECT count(*) FROM operation WHERE ledger_id = $1", {mine.id.ledger_id}),
             std::string("0"));
}

TEST(partitioning_deleting_ledger_wipes_operations_and_links) {
    auto db = fixture::open();
    auto l = make_ledger(*db);
    std::string main = uuidgen::v4(), leg = uuidgen::v4();
    json changes = {
        {"operation", json::array({operation_row(main, l.acc_fr, l.acc_to), operation_row(leg, l.acc_fr, l.acc_to)})},
        {"operation_link", json::array({link_row(uuidgen::v4(), main, leg)})},
    };
    REQUIRE(push(*db, l, changes).http_status == 200);
    REQUIRE(count_of(*db, "SELECT count(*) FROM operation WHERE ledger_id = $1", {l.id.ledger_id}) == "2");
    REQUIRE(count_of(*db, "SELECT count(*) FROM operation_link WHERE ledger_id = $1", {l.id.ledger_id}) == "1");

    auto status = account_deletion_repo::delete_own_account(*db, l.id.user_id);
    REQUIRE(status == account_deletion_repo::DeleteStatus::kOk);

    CHECK_EQ(count_of(*db, "SELECT count(*) FROM operation WHERE ledger_id = $1", {l.id.ledger_id}),
             std::string("0"));
    CHECK_EQ(count_of(*db, "SELECT count(*) FROM operation_link WHERE ledger_id = $1", {l.id.ledger_id}),
             std::string("0"));
}

TEST(partitioning_physical_delete_of_operation_cascades_to_links) {
    auto db = fixture::open();
    auto l = make_ledger(*db);
    std::string main = uuidgen::v4(), leg = uuidgen::v4(), fee = uuidgen::v4();
    json changes = {
        {"operation", json::array({operation_row(main, l.acc_fr, l.acc_to), operation_row(leg, l.acc_fr, l.acc_to),
                                   operation_row(fee, l.acc_fr, l.acc_to)})},
        {"operation_link", json::array({link_row(uuidgen::v4(), main, leg), link_row(uuidgen::v4(), main, fee)})},
    };
    REQUIRE(push(*db, l, changes).http_status == 200);

    // Ссылаются на main (оба link): удаление leg снимает только свою связь.
    db->exec("DELETE FROM operation WHERE ledger_id = $1 AND uuid = $2", {l.id.ledger_id, leg});
    CHECK_EQ(count_of(*db, "SELECT count(*) FROM operation_link WHERE ledger_id = $1", {l.id.ledger_id}),
             std::string("1"));
    // main — главная проводка обеих связей.
    db->exec("DELETE FROM operation WHERE ledger_id = $1 AND uuid = $2", {l.id.ledger_id, main});
    CHECK_EQ(count_of(*db, "SELECT count(*) FROM operation_link WHERE ledger_id = $1", {l.id.ledger_id}),
             std::string("0"));
}

TEST(partitioning_pull_query_touches_a_single_operation_partition) {
    auto db = fixture::open();
    auto l = make_ledger(*db);
    REQUIRE(push(*db, l, {{"operation", json::array({operation_row(uuidgen::v4(), l.acc_fr, l.acc_to)})}}).http_status ==
            200);

    // Тот же вид выборки, что у sync_repo::pull_ledger_stream: по (ledger_id, seq).
    auto plan = explain(*db,
                        "EXPLAIN (COSTS OFF) SELECT * FROM operation WHERE ledger_id = $1 AND seq > $2 ORDER BY seq LIMIT 500",
                        {l.id.ledger_id, "0"});
    auto parts = partitions_in_plan(plan, "operation_p");
    CHECK_EQ(parts.size(), static_cast<size_t>(1));
    CHECK(!plan.empty());
}

TEST(partitioning_report_function_reads_a_single_operation_partition) {
    auto db = fixture::open();
    auto l = make_ledger(*db);
    std::string currency = fixture::make_currency(*db, l.id.ledger_id, l.icon);
    REQUIRE(push(*db, l, {{"operation", json::array({operation_row(uuidgen::v4(), l.acc_fr, l.acc_to)})}}).http_status ==
            200);

    // f_balance_to_date — SQL-функция, встраиваемая в запрос: partition pruning видно прямо в плане.
    auto plan = explain(*db,
                        "EXPLAIN (COSTS OFF) SELECT * FROM f_balance_to_date($1::uuid, $2::timestamp, $3::uuid)",
                        {l.id.ledger_id, "2026-11-14 23:59:59", currency});
    auto parts = partitions_in_plan(plan, "operation_p");
    CHECK(parts.size() <= 1);
    // Все остальные секции отсечены: таких имён в плане больше нет ни одного.
    CHECK(partitions_in_plan(plan, "operation_link_p").size() <= 1);
    CHECK(plan.find("operation") != std::string::npos);
}
