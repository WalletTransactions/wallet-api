// Отчётные функции change debts (миграция 000036) против живого Postgres:
// v_account_operating/f_balance_* отдают counterparty_uuid,
// f_operations_for_period/f_operations_total знают kind = 'debt',
// f_debts_for_period — сводка по долговым кошелькам.
//
// Данные заводятся прямым SQL (как fixture::make_currency), не push_batch: здесь
// проверяются функции, а не протокол синка (его сценарии — test_push_batch.cpp,
// раздел «Долги»). Каждый тест — свой леджер (fixture::make_identity).
//
// Набор DebtLedger (период 2026-03-01 .. 2026-03-31 включительно, эквивалент —
// EUR по курсу USD→EUR 0.9 с 2026-01-01, у RUB курса к EUR нет):
//   Вася · USD (loan1)      — в периоде выдано 1000, возвращено 400 → 0/1000/400/600;
//                             ещё 999 после периода — не входит;
//   Вася · USD (loan2)      — 200 до периода; в периоде прощено 50 (→ категория
//                             «Списание долгов») и 10 переведено на loan4 → 200/0/60/140;
//   Вася · USD (zero)       — архивный кошелёк без проводок → 0/0/0/0;
//   Коля · USD (loan4)      — получил 10 с loan2 → 0/10/0/10;
//   Петя · RUB (petya)      — контрагент архивный; выдано 100, возвращено 150 →
//                             0/100/150/−50 (переплата), эквиваленты NULL;
//   Вася · USD (unmarked)   — признак долга снят (account_debt удалён) — в сводку не входит.
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

struct DebtLedger {
    std::shared_ptr<db::Database> db;
    fixture::TestIdentity identity;
    std::string icon, usd, eur, rub;
    std::string cash_usd, cash_rub, write_off;
    std::string vasya, kolya, petya;
    std::string loan1, loan2, zero, loan4, petya_rub, unmarked;
    std::map<std::string, std::string> ops; // имя → uuid операции
};

std::string add_account(DebtLedger& l, const std::string& name, int kind, bool archived = false) {
    std::string uuid = uuidgen::v4();
    l.db->exec("INSERT INTO account (uuid, ledger_id, seq, name, icon_uuid, kind, is_archived) "
               "VALUES ($1, $2, $3, $4, $5, $6, $7)",
               {uuid, l.identity.ledger_id, seq(*l.db, l.identity.ledger_id), name + " " + uuid, l.icon,
                std::to_string(kind), archived ? "t" : "f"});
    return uuid;
}

std::string add_wallet(DebtLedger& l, const std::string& name, const std::string& currency, bool archived = false) {
    std::string uuid = add_account(l, name, 1, archived);
    l.db->exec("INSERT INTO account_operating (uuid, ledger_id, seq, currency_uuid) VALUES ($1, $2, $3, $4)",
               {uuid, l.identity.ledger_id, seq(*l.db, l.identity.ledger_id), currency});
    return uuid;
}

std::string add_counterparty(DebtLedger& l, const std::string& name, bool archived = false) {
    std::string uuid = uuidgen::v4();
    l.db->exec("INSERT INTO counterparty (uuid, ledger_id, seq, name, is_archived) VALUES ($1, $2, $3, $4, $5)",
               {uuid, l.identity.ledger_id, seq(*l.db, l.identity.ledger_id), name + " " + uuid,
                archived ? "t" : "f"});
    return uuid;
}

std::string add_debt_wallet(DebtLedger& l, const std::string& name, const std::string& currency,
                            const std::string& counterparty, bool archived = false) {
    std::string uuid = add_wallet(l, name, currency, archived);
    l.db->exec("INSERT INTO account_debt (uuid, ledger_id, seq, counterparty_uuid, comment, due_date) "
               "VALUES ($1, $2, $3, $4, 'заём', '2026-12-31')",
               {uuid, l.identity.ledger_id, seq(*l.db, l.identity.ledger_id), counterparty});
    return uuid;
}

void add_op(DebtLedger& l, const std::string& key, const std::string& date, const std::string& from,
            const std::string& to, const std::string& amount) {
    std::string uuid = uuidgen::v4();
    l.db->exec("INSERT INTO operation (uuid, ledger_id, seq, \"date\", acc_fr_uuid, acc_to_uuid, amount, comment) "
               "VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
               {uuid, l.identity.ledger_id, seq(*l.db, l.identity.ledger_id), date, from, to, amount, key});
    l.ops[key] = uuid;
}

DebtLedger make_debt_ledger() {
    DebtLedger l;
    l.db = fixture::open();
    l.identity = fixture::make_identity(*l.db);
    l.icon = fixture::make_reference_icon(*l.db);
    l.usd = fixture::make_currency(*l.db, l.identity.ledger_id, l.icon);
    l.eur = fixture::make_currency(*l.db, l.identity.ledger_id, l.icon);
    l.rub = fixture::make_currency(*l.db, l.identity.ledger_id, l.icon);

    std::string pair = uuidgen::v4();
    l.db->exec("INSERT INTO currency_pair (uuid, ledger_id, seq, symbol, base_currency_uuid, quote_currency_uuid) "
               "VALUES ($1, $2, $3, $4, $5, $6)",
               {pair, l.identity.ledger_id, seq(*l.db, l.identity.ledger_id), "USDEUR " + pair, l.usd, l.eur});
    l.db->exec("INSERT INTO currency_pair_rate (uuid, ledger_id, seq, currency_pair_uuid, \"date\", rate) "
               "VALUES ($1, $2, $3, $4, '2026-01-01', 0.9)",
               {uuidgen::v4(), l.identity.ledger_id, seq(*l.db, l.identity.ledger_id), pair});

    l.cash_usd = add_wallet(l, "Наличные USD", l.usd);
    l.cash_rub = add_wallet(l, "Наличные RUB", l.rub);
    l.write_off = add_account(l, "Списание долгов", 0);

    l.vasya = add_counterparty(l, "Вася");
    l.kolya = add_counterparty(l, "Коля");
    l.petya = add_counterparty(l, "Петя", /*archived=*/true);

    l.loan1 = add_debt_wallet(l, "Вася · USD", l.usd, l.vasya);
    l.loan2 = add_debt_wallet(l, "Вася · USD 2", l.usd, l.vasya);
    l.zero = add_debt_wallet(l, "Вася · USD 0", l.usd, l.vasya, /*archived=*/true);
    l.loan4 = add_debt_wallet(l, "Коля · USD", l.usd, l.kolya);
    l.petya_rub = add_debt_wallet(l, "Петя · RUB", l.rub, l.petya);
    l.unmarked = add_debt_wallet(l, "Вася · USD снят", l.usd, l.vasya);
    l.db->exec("UPDATE account_debt SET deleted_at = now() WHERE ledger_id = $1 AND uuid = $2",
               {l.identity.ledger_id, l.unmarked});

    add_op(l, "give1", "2026-03-05 10:00:00", l.cash_usd, l.loan1, "1000");
    add_op(l, "back1", "2026-03-20 10:00:00", l.loan1, l.cash_usd, "400");
    add_op(l, "after", "2026-04-05 10:00:00", l.cash_usd, l.loan1, "999");
    add_op(l, "give2", "2026-02-10 10:00:00", l.cash_usd, l.loan2, "200");
    add_op(l, "forgive", "2026-03-10 10:00:00", l.loan2, l.write_off, "50");
    add_op(l, "debt2debt", "2026-03-15 10:00:00", l.loan2, l.loan4, "10");
    add_op(l, "give_rub", "2026-03-06 10:00:00", l.cash_rub, l.petya_rub, "100");
    add_op(l, "back_rub", "2026-03-25 10:00:00", l.petya_rub, l.cash_rub, "150");
    add_op(l, "unmarked", "2026-03-07 10:00:00", l.cash_usd, l.unmarked, "5");
    return l;
}

const char* kFrom = "2026-03-01 00:00:00";
const char* kTo = "2026-03-31 23:59:59";

// Строка f_debts_for_period по account_uuid: все поля текстом, NULL — "NULL".
std::map<std::string, std::vector<std::string>> debts_rows(DebtLedger& l) {
    auto res = l.db->exec(
        "SELECT account_uuid, counterparty_uuid, counterparty_archived::text, account_archived::text, "
        "currency_uuid, coalesce(due_date::text, 'NULL'), comment, balance_from::text, inflow::text, "
        "outflow::text, balance_to::text, coalesce(balance_to_eq::text, 'NULL'), "
        "coalesce(inflow_eq::text, 'NULL'), coalesce(outflow_eq::text, 'NULL') "
        "FROM f_debts_for_period($1, $2, $3, $4)",
        {l.identity.ledger_id, kFrom, kTo, l.eur});
    std::map<std::string, std::vector<std::string>> out;
    for (const auto& row : res.rows) out[row.fields.at(0)] = row.fields;
    return out;
}

// kind операции из ленты за период (все kind разом, без фильтра).
std::map<std::string, std::string> feed_kinds(DebtLedger& l) {
    auto res = l.db->exec("SELECT operation_uuid, kind FROM f_operations_for_period($1, $2, $3, $4)",
                          {l.identity.ledger_id, kFrom, kTo, l.eur});
    std::map<std::string, std::string> out;
    for (const auto& row : res.rows) out[row.fields.at(0)] = row.fields.at(1);
    return out;
}

} // namespace

TEST(debts_for_period_partial_return_and_boundaries) {
    auto l = make_debt_ledger();
    auto rows = debts_rows(l);
    // Строка на каждый живой долговой кошелёк; снятый признак — не долг.
    CHECK_EQ(rows.size(), static_cast<std::size_t>(5));
    CHECK(rows.count(l.unmarked) == 0);

    REQUIRE(rows.count(l.loan1) == 1);
    const auto& r1 = rows.at(l.loan1);
    CHECK_EQ(r1.at(1), l.vasya);
    CHECK_EQ(r1.at(2), std::string("false"));
    CHECK_EQ(r1.at(4), l.usd);
    CHECK_EQ(r1.at(5), std::string("2026-12-31"));
    CHECK_EQ(r1.at(6), std::string("заём"));
    // Остаток после частичного возврата: 0 / 1000 / 400 / 600; 999 после p_to не входит.
    CHECK_EQ(r1.at(7), std::string("0.00"));
    CHECK_EQ(r1.at(8), std::string("1000.00"));
    CHECK_EQ(r1.at(9), std::string("400.00"));
    CHECK_EQ(r1.at(10), std::string("600.00"));
    // Эквиваленты по одному курсу 0.9 на p_to.
    CHECK_EQ(r1.at(11), std::string("540.00"));
    CHECK_EQ(r1.at(12), std::string("900.00"));
    CHECK_EQ(r1.at(13), std::string("360.00"));

    // Баланс до периода, прощение и перевод на другой долг — выбытия.
    REQUIRE(rows.count(l.loan2) == 1);
    const auto& r2 = rows.at(l.loan2);
    CHECK_EQ(r2.at(7), std::string("200.00"));
    CHECK_EQ(r2.at(8), std::string("0.00"));
    CHECK_EQ(r2.at(9), std::string("60.00"));
    CHECK_EQ(r2.at(10), std::string("140.00"));

    REQUIRE(rows.count(l.loan4) == 1);
    CHECK_EQ(rows.at(l.loan4).at(1), l.kolya);
    CHECK_EQ(rows.at(l.loan4).at(10), std::string("10.00"));
}

TEST(debts_for_period_zero_archived_and_two_loans_of_one_person) {
    auto l = make_debt_ledger();
    auto rows = debts_rows(l);
    // Нулевой архивный кошелёк — в выдаче, с нулями и эквивалентом 0.
    REQUIRE(rows.count(l.zero) == 1);
    const auto& z = rows.at(l.zero);
    CHECK_EQ(z.at(3), std::string("true"));
    CHECK_EQ(z.at(7), std::string("0.00"));
    CHECK_EQ(z.at(8), std::string("0.00"));
    CHECK_EQ(z.at(9), std::string("0.00"));
    CHECK_EQ(z.at(10), std::string("0.00"));
    CHECK_EQ(z.at(11), std::string("0.00"));
    // У Васи три займа в одной валюте — три строки.
    int vasya_rows = 0;
    for (const auto& [uuid, row] : rows) {
        if (row.at(1) == l.vasya) ++vasya_rows;
    }
    CHECK_EQ(vasya_rows, 3);
}

TEST(debts_for_period_overpayment_goes_negative_and_no_rate_gives_null_eq) {
    auto l = make_debt_ledger();
    auto rows = debts_rows(l);
    REQUIRE(rows.count(l.petya_rub) == 1);
    const auto& p = rows.at(l.petya_rub);
    CHECK_EQ(p.at(2), std::string("true")); // архивный контрагент — долг всё равно в сводке
    CHECK_EQ(p.at(4), l.rub);
    CHECK_EQ(p.at(8), std::string("100.00"));
    CHECK_EQ(p.at(9), std::string("150.00"));
    CHECK_EQ(p.at(10), std::string("-50.00"));
    CHECK_EQ(p.at(11), std::string("NULL"));
    CHECK_EQ(p.at(12), std::string("NULL"));
    CHECK_EQ(p.at(13), std::string("NULL"));
}

TEST(balance_functions_return_counterparty_uuid_for_debt_wallets_only) {
    auto l = make_debt_ledger();
    auto res = l.db->exec("SELECT account_uuid, coalesce(counterparty_uuid::text, 'NULL'), balance::text "
                          "FROM f_balance_to_date($1, '2026-04-01', $2)",
                          {l.identity.ledger_id, l.eur});
    std::map<std::string, std::pair<std::string, std::string>> by_account;
    for (const auto& row : res.rows) by_account[row.fields.at(0)] = {row.fields.at(1), row.fields.at(2)};
    REQUIRE(by_account.count(l.loan1) == 1);
    CHECK_EQ(by_account.at(l.loan1).first, l.vasya);
    CHECK_EQ(by_account.at(l.loan1).second, std::string("600.00"));
    REQUIRE(by_account.count(l.cash_usd) == 1);
    CHECK_EQ(by_account.at(l.cash_usd).first, std::string("NULL"));
    // Снятый признак — обычный кошелёк с прежним балансом.
    REQUIRE(by_account.count(l.unmarked) == 1);
    CHECK_EQ(by_account.at(l.unmarked).first, std::string("NULL"));
    CHECK_EQ(by_account.at(l.unmarked).second, std::string("5.00"));
    // Знак баланса: выдано 100, возвращено 150 → −50.
    REQUIRE(by_account.count(l.petya_rub) == 1);
    CHECK_EQ(by_account.at(l.petya_rub).second, std::string("-50.00"));

    auto dates = l.db->exec("SELECT DISTINCT coalesce(counterparty_uuid::text, 'NULL') FROM f_balance_to_dates("
                            "$1, ARRAY['2026-04-01'::timestamp], $2) WHERE account_uuid = $3",
                            {l.identity.ledger_id, l.eur, l.loan4});
    REQUIRE(dates.rows.size() == 1);
    CHECK_EQ(dates.rows.at(0).fields.at(0), l.kolya);

    auto series = l.db->exec("SELECT coalesce(account_uuid::text, 'NULL'), coalesce(counterparty_uuid::text, 'NULL') "
                             "FROM f_balance_series($1, '2026-03-01', '2026-03-31', 'month', $2)",
                             {l.identity.ledger_id, l.eur});
    bool seen = false;
    for (const auto& row : series.rows) {
        if (row.fields.at(0) == l.loan2) seen = row.fields.at(1) == l.vasya;
    }
    CHECK(seen);
    // Пустой бакет (до первой проводки) — одна строка, account- и counterparty_uuid NULL.
    auto empty = l.db->exec("SELECT coalesce(account_uuid::text, 'NULL'), coalesce(counterparty_uuid::text, 'NULL') "
                            "FROM f_balance_series($1, '2025-01-01', '2025-01-31', 'month', $2)",
                            {l.identity.ledger_id, l.eur});
    REQUIRE(empty.rows.size() == 1);
    CHECK_EQ(empty.rows.at(0).fields.at(0), std::string("NULL"));
    CHECK_EQ(empty.rows.at(0).fields.at(1), std::string("NULL"));
}

TEST(operations_feed_marks_debt_transfers_only) {
    auto l = make_debt_ledger();
    auto kinds = feed_kinds(l);
    CHECK_EQ(kinds[l.ops.at("give1")], std::string("debt"));
    CHECK_EQ(kinds[l.ops.at("back1")], std::string("debt"));
    CHECK_EQ(kinds[l.ops.at("give_rub")], std::string("debt"));
    CHECK_EQ(kinds[l.ops.at("back_rub")], std::string("debt"));
    // Прощение — расход на категорию; перевод между двумя долговыми — transfer.
    CHECK_EQ(kinds[l.ops.at("forgive")], std::string("expense"));
    CHECK_EQ(kinds[l.ops.at("debt2debt")], std::string("transfer"));
    // Кошелёк со снятым признаком — обычный перевод.
    CHECK_EQ(kinds[l.ops.at("unmarked")], std::string("transfer"));

    auto filtered = l.db->exec("SELECT operation_uuid FROM f_operations_for_period($1, $2, $3, $4, p_kind => 'debt')",
                               {l.identity.ledger_id, kFrom, kTo, l.eur});
    CHECK_EQ(filtered.rows.size(), static_cast<std::size_t>(4));
    auto transfers = l.db->exec(
        "SELECT operation_uuid FROM f_operations_for_period($1, $2, $3, $4, p_kind => 'transfer')",
        {l.identity.ledger_id, kFrom, kTo, l.eur});
    CHECK_EQ(transfers.rows.size(), static_cast<std::size_t>(2));
}

TEST(operations_total_counts_debt_only_with_explicit_kind_and_forgiveness_as_expense) {
    auto l = make_debt_ledger();
    // Без p_kind: сальдо income − expense, долги и переводы — 0; прощение 50 USD = 45 EUR расхода.
    auto saldo = l.db->exec("SELECT total_eq::text, incomplete::text, matched::text "
                            "FROM f_operations_total($1, $2, $3, $4)",
                            {l.identity.ledger_id, kFrom, kTo, l.eur});
    REQUIRE(saldo.rows.size() == 1);
    CHECK_EQ(saldo.rows.at(0).fields.at(0), std::string("-45.00"));
    // p_kind => 'debt': сумма эквивалентов (1000 + 400) × 0.9; RUB без курса — incomplete.
    auto debt = l.db->exec("SELECT total_eq::text, incomplete::text, matched::text "
                           "FROM f_operations_total($1, $2, $3, $4, p_kind => 'debt')",
                           {l.identity.ledger_id, kFrom, kTo, l.eur});
    REQUIRE(debt.rows.size() == 1);
    CHECK_EQ(debt.rows.at(0).fields.at(0), std::string("1260.00"));
    CHECK_EQ(debt.rows.at(0).fields.at(1), std::string("true"));
    CHECK_EQ(debt.rows.at(0).fields.at(2), std::string("4"));
    // Прощение — расход категории «Списание долгов» в отчёте расходов.
    auto expense = l.db->exec("SELECT amount::text FROM f_expanse_for_period($1, $2, $3, $4) WHERE account_uuid = $5",
                              {l.identity.ledger_id, kFrom, kTo, l.eur, l.write_off});
    REQUIRE(expense.rows.size() == 1);
    CHECK_EQ(expense.rows.at(0).fields.at(0), std::string("50.00"));
}
