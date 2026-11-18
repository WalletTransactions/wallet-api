// Функции поиска операций (change operations-search-summary-sql, миграция 000042)
// против живого Postgres: p_exclude_qs у f_operations_for_period/f_operations_total
// и f_operations_by_category.
//
// Данные заводятся прямым SQL (как test_debts_reports.cpp), каждый тест — свой
// леджер. Эквивалент — та же валюта, что у операций (курс не нужен: v_operation_eq
// для операции в валюте эквивалента берёт сумму как есть).
//
// Набор (период 2026-03-01 .. 2026-11-30, все расходы с кошелька «Наличные»):
//   2026-03-04  «Стрижка»                       23   Personal Care
//   2026-09-07  «Машинка для стрижки волос»     62.1 Electronics
//   2026-11-06  «Стрижка»                       10   Personal Care
//   2026-06-01  «стрижка у Ивана»               15   Красота и уход
//   2026-05-01  пустой комментарий (NULL)        7   Personal Care
#include <map>
#include <string>
#include <vector>

#include "fixture.hpp"
#include "test_framework.hpp"
#include "util/uuid.hpp"

namespace {

std::string seq(db::Database& db, const std::string& ledger_id) {
    return db.exec("SELECT next_seq($1)", {ledger_id}).rows.at(0).fields.at(0);
}

struct SearchLedger {
    std::shared_ptr<db::Database> db;
    fixture::TestIdentity identity;
    std::string icon, cur, cash;
    std::string personal_care, electronics, beauty;
};

std::string add_account(SearchLedger& l, const std::string& name, int kind) {
    std::string uuid = uuidgen::v4();
    l.db->exec("INSERT INTO account (uuid, ledger_id, seq, name, icon_uuid, kind, is_archived) "
               "VALUES ($1, $2, $3, $4, $5, $6, 'f')",
               {uuid, l.identity.ledger_id, seq(*l.db, l.identity.ledger_id), name, l.icon, std::to_string(kind)});
    return uuid;
}

void add_expense(SearchLedger& l, const std::string& date, const std::string& category, const std::string& amount,
                 const std::string* comment) {
    std::string uuid = uuidgen::v4();
    if (comment != nullptr) {
        l.db->exec("INSERT INTO operation (uuid, ledger_id, seq, \"date\", acc_fr_uuid, acc_to_uuid, amount, comment) "
                   "VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
                   {uuid, l.identity.ledger_id, seq(*l.db, l.identity.ledger_id), date, l.cash, category, amount,
                    *comment});
    } else {
        l.db->exec("INSERT INTO operation (uuid, ledger_id, seq, \"date\", acc_fr_uuid, acc_to_uuid, amount) "
                   "VALUES ($1, $2, $3, $4, $5, $6, $7)",
                   {uuid, l.identity.ledger_id, seq(*l.db, l.identity.ledger_id), date, l.cash, category, amount});
    }
}

SearchLedger make_search_ledger() {
    SearchLedger l;
    l.db = fixture::open();
    l.identity = fixture::make_identity(*l.db);
    l.icon = fixture::make_reference_icon(*l.db);
    l.cur = fixture::make_currency(*l.db, l.identity.ledger_id, l.icon);

    l.cash = add_account(l, "Наличные", 1);
    l.db->exec("INSERT INTO account_operating (uuid, ledger_id, seq, currency_uuid) VALUES ($1, $2, $3, $4)",
               {l.cash, l.identity.ledger_id, seq(*l.db, l.identity.ledger_id), l.cur});
    l.personal_care = add_account(l, "Personal Care", 0);
    l.electronics = add_account(l, "Electronics", 0);
    l.beauty = add_account(l, "Красота и уход", 0);

    const std::string haircut = "Стрижка", clipper = "Машинка для стрижки волос", ivan = "стрижка у Ивана";
    add_expense(l, "2026-03-04 00:00:00", l.personal_care, "23", &haircut);
    add_expense(l, "2026-09-07 00:00:00", l.electronics, "62.1", &clipper);
    add_expense(l, "2026-11-06 00:00:00", l.personal_care, "10", &haircut);
    add_expense(l, "2026-06-01 00:00:00", l.beauty, "15", &ivan);
    add_expense(l, "2026-05-01 00:00:00", l.personal_care, "7", nullptr);
    return l;
}

const char* kFrom = "2026-01-01 00:00:00";
const char* kTo = "2026-11-30 23:59:59";

// Литерал text[] для параметра: значения без запятых и кавычек.
std::string text_array(const std::vector<std::string>& items) {
    std::string out = "{";
    for (std::size_t i = 0; i < items.size(); ++i) out += (i ? "," : "") + items[i];
    return out + "}";
}

// Итог f_operations_total: {total_eq, matched}.
std::pair<std::string, std::string> total(SearchLedger& l, const std::string& qs, const std::string& exclude_qs) {
    std::string args = "$1, $2, $3, $4, p_kind => 'expense'";
    std::vector<std::string> params = {l.identity.ledger_id, kFrom, kTo, l.cur};
    if (!qs.empty()) {
        args += ", p_qs => $" + std::to_string(params.size() + 1) + "::text[]";
        params.push_back(qs);
    }
    if (!exclude_qs.empty()) {
        args += ", p_exclude_qs => $" + std::to_string(params.size() + 1) + "::text[]";
        params.push_back(exclude_qs);
    }
    auto res = l.db->exec("SELECT trim_scale(total_eq)::text, matched::text FROM f_operations_total(" + args + ")", params);
    return {res.rows.at(0).fields.at(0), res.rows.at(0).fields.at(1)};
}

// Комментарии ленты по тем же фильтрам (по убыванию даты).
std::vector<std::string> feed_comments(SearchLedger& l, const std::string& qs, const std::string& exclude_qs) {
    std::string args = "$1, $2, $3, $4";
    std::vector<std::string> params = {l.identity.ledger_id, kFrom, kTo, l.cur};
    if (!qs.empty()) {
        args += ", p_qs => $" + std::to_string(params.size() + 1) + "::text[]";
        params.push_back(qs);
    }
    if (!exclude_qs.empty()) {
        args += ", p_exclude_qs => $" + std::to_string(params.size() + 1) + "::text[]";
        params.push_back(exclude_qs);
    }
    auto res = l.db->exec("SELECT coalesce(comment, '<NULL>') FROM f_operations_for_period(" + args + ")", params);
    std::vector<std::string> out;
    for (const auto& row : res.rows) out.push_back(row.fields.at(0));
    return out;
}

} // namespace

TEST(exclude_qs_removes_false_positive_from_feed_and_total) {
    auto l = make_search_ledger();
    auto without = total(l, text_array({"стриж"}), "");
    CHECK_EQ(without.second, std::string("4")); // Стрижка×2, Машинка…, стрижка у Ивана
    auto with = total(l, text_array({"стриж"}), text_array({"машинк"}));
    CHECK_EQ(with.first, std::string("48")); // 23 + 10 + 15
    CHECK_EQ(with.second, std::string("3"));
    auto comments = feed_comments(l, text_array({"стриж"}), text_array({"машинк"}));
    CHECK_EQ(comments.size(), static_cast<std::size_t>(3));
    for (const auto& c : comments) CHECK(c.find("Машинка") == std::string::npos);
}

TEST(exclude_qs_is_case_and_yo_insensitive) {
    auto l = make_search_ledger();
    auto r = total(l, text_array({"стриж"}), text_array({"МАШИНК"}));
    CHECK_EQ(r.second, std::string("3"));
}

TEST(exclude_qs_keeps_operation_with_null_comment) {
    auto l = make_search_ledger();
    // Без q: все пять расходов; исключение «стрижк» убирает четыре с комментарием,
    // операция с NULL-комментарием остаётся.
    auto r = total(l, "", text_array({"стрижк"}));
    CHECK_EQ(r.second, std::string("1"));
    CHECK_EQ(r.first, std::string("7"));
}

TEST(exclude_qs_absent_keeps_previous_result) {
    auto l = make_search_ledger();
    auto r = total(l, "", "");
    CHECK_EQ(r.second, std::string("5"));
}

TEST(operations_by_category_groups_and_matches_total) {
    auto l = make_search_ledger();
    auto res = l.db->exec(
        "SELECT category_name, matched::text, trim_scale(total_eq)::text, first_date::text, last_date::text "
        "FROM f_operations_by_category($1, $2, $3, $4, p_kind => 'expense', p_qs => $5::text[], "
        "p_exclude_qs => $6::text[])",
        {l.identity.ledger_id, kFrom, kTo, l.cur, text_array({"стриж"}), text_array({"машинк"})});
    REQUIRE(res.rows.size() == 2);
    // По убыванию суммы: Personal Care 33 (2 шт.), Красота и уход 15 (1 шт.).
    CHECK_EQ(res.rows[0].fields.at(0), std::string("Personal Care"));
    CHECK_EQ(res.rows[0].fields.at(1), std::string("2"));
    CHECK_EQ(res.rows[0].fields.at(2), std::string("33"));
    CHECK_EQ(res.rows[0].fields.at(3), std::string("2026-03-04 00:00:00"));
    CHECK_EQ(res.rows[0].fields.at(4), std::string("2026-11-06 00:00:00"));
    CHECK_EQ(res.rows[1].fields.at(0), std::string("Красота и уход"));
    CHECK_EQ(res.rows[1].fields.at(2), std::string("15"));

    // Сумма по строкам равна итогу f_operations_total с теми же аргументами.
    auto t = total(l, text_array({"стриж"}), text_array({"машинк"}));
    CHECK_EQ(t.first, std::string("48"));
    CHECK_EQ(t.second, std::string("3"));
}

TEST(operations_by_category_other_matches_via_exclude_category) {
    auto l = make_search_ledger();
    // «Совпадения вне фильтра»: тот же q, категория Personal Care исключена.
    auto res = l.db->exec(
        "SELECT category_name, matched::text, trim_scale(total_eq)::text "
        "FROM f_operations_by_category($1, $2, $3, $4, p_kind => 'expense', p_qs => $5::text[], "
        "p_exclude_category_uuids => $6::uuid[])",
        {l.identity.ledger_id, kFrom, kTo, l.cur, text_array({"стриж"}), "{" + l.personal_care + "}"});
    REQUIRE(res.rows.size() == 2);
    std::map<std::string, std::string> totals;
    for (const auto& row : res.rows) totals[row.fields.at(0)] = row.fields.at(2);
    CHECK_EQ(totals.at("Electronics"), std::string("62.1"));
    CHECK_EQ(totals.at("Красота и уход"), std::string("15"));
}

TEST(operations_by_category_empty_when_nothing_matches) {
    auto l = make_search_ledger();
    auto res = l.db->exec("SELECT 1 FROM f_operations_by_category($1, $2, $3, $4, p_qs => $5::text[])",
                          {l.identity.ledger_id, kFrom, kTo, l.cur, text_array({"zzz-нет-такого"})});
    CHECK_EQ(res.rows.size(), static_cast<std::size_t>(0));
}

TEST(operations_by_category_does_not_see_foreign_ledger) {
    auto l = make_search_ledger();
    auto other = fixture::make_identity(*l.db);
    auto res = l.db->exec("SELECT 1 FROM f_operations_by_category($1, $2, $3, $4, p_qs => $5::text[])",
                          {other.ledger_id, kFrom, kTo, l.cur, text_array({"стриж"})});
    CHECK_EQ(res.rows.size(), static_cast<std::size_t>(0));
}
