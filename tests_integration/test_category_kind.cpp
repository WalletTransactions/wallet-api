// Интеграционные тесты вида категории account.category_kind (change
// category-kind-income-expense, миграция 000041) против ЖИВОГО Postgres.
//
// Две группы:
//   * push/pull — колонка обязательна, значения 0..2 доезжают до pull как есть,
//     вне набора и без поля — 400 invalid_row, смена вида получает новый seq;
//   * миграционная разметка — файлы 000041 прогоняются в откатываемой
//     транзакции (как test_default_icons.cpp): сначала down (колонки нет), затем
//     up на данных, заведённых до миграции. Данные кладутся ДО транзакции —
//     Database держит одно соединение, push_batch внутри Transaction завис бы.
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#include "fixture.hpp"
#include "nlohmann/json.hpp"
#include "sync_repo.hpp"
#include "test_framework.hpp"
#include "util/uuid.hpp"

namespace {

using json = nlohmann::json;

std::string migrations_dir() {
    const char* v = std::getenv("WALLET_API_MIGRATIONS_DIR");
    return (v != nullptr && *v != '\0') ? v : "/src/migrations";
}

std::string read_file(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) throw std::runtime_error("не открылся файл " + path + " (WALLET_API_MIGRATIONS_DIR?)");
    std::ostringstream ss;
    ss << in.rdbuf();
    return ss.str();
}

// db::Database::exec идёт через PQexecParams — несколько команд в одном
// запросе он не принимает, а файл миграции их содержит (ALTER, COMMENT, DO).
// Режем по «;» в конце строки вне тела $$ ... $$, строки-комментарии пропускаем.
std::vector<std::string> split_statements(const std::string& sql) {
    std::vector<std::string> out;
    std::string cur;
    bool in_dollar = false;
    std::istringstream in(sql);
    std::string line;
    while (std::getline(in, line)) {
        if (!in_dollar && line.rfind("--", 0) == 0) continue;
        cur += line + "\n";
        for (std::size_t pos = line.find("$$"); pos != std::string::npos; pos = line.find("$$", pos + 2)) {
            in_dollar = !in_dollar;
        }
        if (!in_dollar && !line.empty() && line.back() == ';') {
            out.push_back(cur);
            cur.clear();
        }
    }
    return out;
}

void run_file(db::Database::Transaction& tx, const std::string& path) {
    for (const auto& stmt : split_statements(read_file(path))) tx.exec(stmt);
}

void run_up(db::Database::Transaction& tx) { run_file(tx, migrations_dir() + "/000041_category_kind.up.sql"); }
void run_down(db::Database::Transaction& tx) { run_file(tx, migrations_dir() + "/000041_category_kind.down.sql"); }

json account_row(const std::string& uuid, const std::string& icon_uuid, const std::string& name,
                 int category_kind) {
    return json{{"uuid", uuid},          {"name", name},          {"comment", ""},
                {"icon_uuid", icon_uuid}, {"is_archived", false},  {"system_kind", 0},
                {"kind", 0},             {"category_kind", category_kind}};
}

sync_repo::PushOutcome push_accounts(db::Database& db, const fixture::TestIdentity& id, const json& rows) {
    return sync_repo::push_batch(db, id.ledger_id, id.device_id, uuidgen::v4(), {{"account", rows}});
}

std::string scalar(db::Database& db, const std::string& sql, const std::vector<std::string>& p = {}) {
    return db.exec(sql, p).rows.at(0).fields.at(0);
}

// --- Данные «до миграции»: прямой SQL, колонка category_kind ещё не нужна ---

struct Seeded {
    fixture::TestIdentity id;
    std::string icon;
    std::string wallet1;
    std::string wallet2;
};

std::string insert_account(db::Database& db, const Seeded& s, const std::string& name, int kind, int system_kind) {
    std::string uuid = uuidgen::v4();
    std::string seq = scalar(db, "SELECT next_seq($1)", {s.id.ledger_id});
    db.exec("INSERT INTO account (uuid, ledger_id, seq, name, icon_uuid, kind, system_kind) "
            "VALUES ($1,$2,$3,$4,$5,$6,$7)",
            {uuid, s.id.ledger_id, seq, name + " " + uuid, s.icon, std::to_string(kind),
             std::to_string(system_kind)});
    return uuid;
}

// from → to; deleted — мягко удалённая операция.
void insert_operation(db::Database& db, const Seeded& s, const std::string& from, const std::string& to,
                      bool deleted = false) {
    std::string seq = scalar(db, "SELECT next_seq($1)", {s.id.ledger_id});
    db.exec("INSERT INTO operation (uuid, ledger_id, seq, deleted_at, \"date\", acc_fr_uuid, acc_to_uuid, amount) "
            "VALUES ($1,$2,$3," + std::string(deleted ? "now()" : "NULL") + ",'2026-11-14 12:00:00',$4,$5,10)",
            {uuidgen::v4(), s.id.ledger_id, seq, from, to});
}

Seeded seed(db::Database& db) {
    Seeded s;
    s.id = fixture::make_identity(db);
    s.icon = fixture::make_reference_icon(db);
    s.wallet1 = insert_account(db, s, "wallet", 1, 0);
    s.wallet2 = insert_account(db, s, "wallet", 1, 0);
    return s;
}

} // namespace

TEST(category_kind_push_pull_round_trips_all_values) {
    auto db = fixture::open();
    auto id = fixture::make_identity(*db);
    std::string icon = fixture::make_reference_icon(*db);
    std::string expense = uuidgen::v4(), income = uuidgen::v4(), both = uuidgen::v4();

    auto outcome = push_accounts(*db, id,
                                 json::array({account_row(expense, icon, "Расход " + expense, 0),
                                              account_row(income, icon, "Доход " + income, 1),
                                              account_row(both, icon, "Оба " + both, 2)}));
    REQUIRE(outcome.http_status == 200);

    auto pulled = sync_repo::pull_ledger_stream(*db, id.ledger_id, /*cursor=*/0, /*limit=*/1000);
    int found = 0;
    for (const auto& row : pulled.changes.at("account")) {
        const std::string u = row.at("uuid");
        if (u == expense) { CHECK_EQ(row.at("category_kind").get<int>(), 0); ++found; }
        if (u == income) { CHECK_EQ(row.at("category_kind").get<int>(), 1); ++found; }
        if (u == both) { CHECK_EQ(row.at("category_kind").get<int>(), 2); ++found; }
    }
    CHECK_EQ(found, 3);
}

TEST(category_kind_out_of_range_is_invalid_row_not_500) {
    auto db = fixture::open();
    auto id = fixture::make_identity(*db);
    std::string icon = fixture::make_reference_icon(*db);
    std::string uuid = uuidgen::v4();

    auto outcome = push_accounts(*db, id, json::array({account_row(uuid, icon, "Bad " + uuid, 3)}));

    CHECK_EQ(outcome.http_status, 400);
    json body = json::parse(outcome.response_body);
    CHECK_EQ(body.value("error", std::string{}), std::string("invalid_row"));
    CHECK_EQ(scalar(*db, "SELECT count(*) FROM account WHERE ledger_id = $1 AND uuid = $2", {id.ledger_id, uuid}),
             std::string("0"));
}

TEST(category_kind_missing_column_is_invalid_row_naming_the_field) {
    auto db = fixture::open();
    auto id = fixture::make_identity(*db);
    std::string icon = fixture::make_reference_icon(*db);
    std::string uuid = uuidgen::v4();
    json row = account_row(uuid, icon, "No kind " + uuid, 0);
    row.erase("category_kind");

    auto outcome = push_accounts(*db, id, json::array({row}));

    CHECK_EQ(outcome.http_status, 400);
    json body = json::parse(outcome.response_body);
    CHECK_EQ(body.value("error", std::string{}), std::string("invalid_row"));
    CHECK(body.value("detail", std::string{}).find("category_kind") != std::string::npos);
    CHECK_EQ(scalar(*db, "SELECT count(*) FROM account WHERE ledger_id = $1 AND uuid = $2", {id.ledger_id, uuid}),
             std::string("0"));
}

TEST(category_kind_change_gets_new_seq_and_pulls) {
    auto db = fixture::open();
    auto id = fixture::make_identity(*db);
    std::string icon = fixture::make_reference_icon(*db);
    std::string uuid = uuidgen::v4();
    std::string name = "Подарки " + uuid;

    REQUIRE(push_accounts(*db, id, json::array({account_row(uuid, icon, name, 0)})).http_status == 200);
    auto seq_before = std::stoll(
        scalar(*db, "SELECT seq FROM account WHERE ledger_id = $1 AND uuid = $2", {id.ledger_id, uuid}));

    REQUIRE(push_accounts(*db, id, json::array({account_row(uuid, icon, name, 2)})).http_status == 200);
    auto seq_after = std::stoll(
        scalar(*db, "SELECT seq FROM account WHERE ledger_id = $1 AND uuid = $2", {id.ledger_id, uuid}));
    CHECK(seq_after > seq_before);

    // Курсор, дочитанный до первой версии, отдаёт строку с новым видом.
    auto pulled = sync_repo::pull_ledger_stream(*db, id.ledger_id, seq_before, /*limit=*/1000);
    bool seen = false;
    for (const auto& row : pulled.changes.at("account")) {
        if (row.at("uuid") == uuid) {
            CHECK_EQ(row.at("category_kind").get<int>(), 2);
            seen = true;
        }
    }
    CHECK(seen);
}

TEST(category_kind_column_defaults_to_2_in_database) {
    auto db = fixture::open();
    auto s = seed(*db);
    CHECK_EQ(scalar(*db, "SELECT category_kind FROM account WHERE ledger_id = $1 AND uuid = $2",
                    {s.id.ledger_id, s.wallet1}),
             std::string("2"));
}

TEST(category_kind_migration_marks_categories_by_live_operations) {
    auto db = fixture::open();
    auto s = seed(*db);

    std::string salary = insert_account(*db, s, "Зарплата", 0, 0);      // только категория → кошелёк
    std::string groceries = insert_account(*db, s, "Продукты", 0, 0);   // только кошелёк → категория
    std::string gifts = insert_account(*db, s, "Подарки", 0, 0);        // обе стороны
    std::string empty = insert_account(*db, s, "Пустая", 0, 0);         // без операций
    std::string refund = insert_account(*db, s, "Удалённое", 0, 0);     // единственная операция удалена
    std::string transfer = insert_account(*db, s, "Перевод", 0, 1);     // системная, только расход

    insert_operation(*db, s, salary, s.wallet1);
    insert_operation(*db, s, s.wallet1, groceries);
    insert_operation(*db, s, s.wallet1, gifts);
    insert_operation(*db, s, gifts, s.wallet2);
    insert_operation(*db, s, refund, s.wallet1, /*deleted=*/true);
    insert_operation(*db, s, s.wallet1, transfer);

    auto head_before = std::stoll(scalar(*db, "SELECT seq FROM change_stream WHERE id = $1", {s.id.ledger_id}));
    std::string seq_gifts_before =
        scalar(*db, "SELECT seq FROM account WHERE ledger_id = $1 AND uuid = $2", {s.id.ledger_id, gifts});

    auto tx = db->begin_transaction();
    run_down(tx);
    run_up(tx);

    auto get = [&](const std::string& uuid, const char* col) {
        return tx.exec(std::string("SELECT ") + col + " FROM account WHERE ledger_id = $1 AND uuid = $2",
                       {s.id.ledger_id, uuid})
            .rows.at(0)
            .fields.at(0);
    };

    CHECK_EQ(get(salary, "category_kind"), std::string("1"));
    CHECK_EQ(get(groceries, "category_kind"), std::string("0"));
    CHECK_EQ(get(gifts, "category_kind"), std::string("2"));
    CHECK_EQ(get(empty, "category_kind"), std::string("2"));
    CHECK_EQ(get(refund, "category_kind"), std::string("2"));
    CHECK_EQ(get(transfer, "category_kind"), std::string("2"));
    CHECK_EQ(get(s.wallet1, "category_kind"), std::string("2"));

    // Изменённые строки — один новый seq больше головы потока, updated_by NULL.
    CHECK(std::stoll(get(salary, "seq")) > head_before);
    CHECK_EQ(get(salary, "seq"), get(groceries, "seq"));
    CHECK(get(salary, "updated_by").empty()); // NULL приходит как ""
    // Строки с итогом 2 seq не двигают.
    CHECK_EQ(get(gifts, "seq"), seq_gifts_before);
    // Откат транзакции (деструктор без commit) возвращает базу как была.
}
