// Миграция 000039_default_reference_currencies (change default-reference-currencies):
// общий справочник валют и валютных пар по умолчанию — состав, выдача через pull
// потока reference, идемпотентность, уважение валют администратора и откат.
//
// Справочник уже накачен миграциями, на которых стоит тестовая база. Повтор up.sql и
// down.sql гоняется ВНУТРИ транзакции, которая в конце откатывается (RAII
// Database::Transaction), — общая тестовая база после каждого теста остаётся
// как была, а тесты друг другу не мешают (см. README.md, «Изоляция»).
#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <fstream>
#include <set>
#include <sstream>
#include <string>

#include "db.hpp"
#include "fixture.hpp"
#include "nlohmann/json.hpp"
#include "sync_repo.hpp"
#include "test_framework.hpp"
#include "util/uuid.hpp"

using nlohmann::json;

namespace {

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

json manifest() { return json::parse(read_file(migrations_dir() + "/default_currencies/manifest.json")); }

std::string up_sql() { return read_file(migrations_dir() + "/000039_default_reference_currencies.up.sql"); }
std::string down_sql() { return read_file(migrations_dir() + "/000039_default_reference_currencies.down.sql"); }

std::string scalar(db::Database::Transaction& tx, const std::string& sql, const std::vector<std::string>& p = {}) {
    return tx.exec(sql, p).rows.at(0).fields.at(0);
}

std::string scalar(db::Database& db, const std::string& sql, const std::vector<std::string>& p = {}) {
    return db.exec(sql, p).rows.at(0).fields.at(0);
}

constexpr const char* kStream = "'00000000-0000-0000-0000-000000000001'";

// Сколько живых общих валют набора (по детерминированному uuid) стоит в базе.
std::string set_currencies_count(db::Database::Transaction& tx, const json& m) {
    std::string codes;
    for (const auto& c : m.at("currencies")) {
        if (!codes.empty()) codes += ",";
        codes += "('" + c.at("iso").get<std::string>() + "')";
    }
    return scalar(tx,
                  "SELECT count(*) FROM currency c WHERE c.ledger_id IS NULL AND c.deleted_at IS NULL AND c.uuid IN "
                  "(SELECT md5('reference-currency:' || n.iso)::uuid FROM (VALUES " + codes + ") n(iso))");
}

std::string set_pairs_count(db::Database::Transaction& tx, const json& m) {
    std::string symbols;
    for (const auto& p : m.at("pairs")) {
        if (!symbols.empty()) symbols += ",";
        symbols += "('" + p.at("symbol").get<std::string>() + "')";
    }
    return scalar(tx,
                  "SELECT count(*) FROM currency_pair p WHERE p.ledger_id IS NULL AND p.deleted_at IS NULL AND p.uuid "
                  "IN (SELECT md5('reference-currency-pair:' || n.symbol)::uuid FROM (VALUES " + symbols + ") n(symbol))");
}

// Общая валюта администратора (в обход ручек — как fixture.hpp); иконка — любая живая общая.
std::string admin_currency(db::Database::Transaction& tx, const std::string& iso, const std::string& name,
                           bool deleted = false) {
    std::string uuid = uuidgen::v4();
    tx.exec(std::string("INSERT INTO currency (uuid, seq, name, iso_code, icon_uuid, symbol, deleted_at) VALUES "
                        "($1, (SELECT next_seq(") + kStream + ")), $2, $3, "
                "(SELECT uuid FROM icon WHERE ledger_id IS NULL AND deleted_at IS NULL LIMIT 1), $3, " +
                (deleted ? "now()" : "NULL") + ")",
            {uuid, name, iso});
    return uuid;
}

} // namespace

TEST(default_currencies_exist_with_manifest_fields_and_icon) {
    auto db = fixture::open();
    const json m = manifest();
    REQUIRE(m.at("currencies").size() == 17);

    for (const auto& c : m.at("currencies")) {
        auto iso = c.at("iso").get<std::string>();
        // Одна живая общая валюта с таким кодом, поля — как в манифесте.
        CHECK(scalar(*db, "SELECT count(*) FROM currency WHERE ledger_id IS NULL AND deleted_at IS NULL AND "
                          "iso_code = $1", {iso}) == "1");
        CHECK(scalar(*db, "SELECT name || '|' || symbol || '|' || \"precision\" FROM currency WHERE ledger_id IS NULL "
                          "AND deleted_at IS NULL AND iso_code = $1", {iso}) ==
              c.at("name").get<std::string>() + "|" + c.at("symbol").get<std::string>() + "|" +
                  std::to_string(c.at("precision").get<int>()));
        // Иконка — живая общая иконка набора с именем из манифеста.
        CHECK(scalar(*db, "SELECT count(*) FROM currency c JOIN icon i ON i.uuid = c.icon_uuid WHERE c.ledger_id IS "
                          "NULL AND c.deleted_at IS NULL AND c.iso_code = $1 AND i.ledger_id IS NULL AND "
                          "i.deleted_at IS NULL AND lower(i.name) = lower($2)",
                     {iso, c.at("icon").get<std::string>()}) == "1");
    }
}

TEST(default_currencies_pairs_link_base_and_quote_by_code) {
    auto db = fixture::open();
    const json m = manifest();
    REQUIRE(m.at("pairs").size() == 31);

    for (const auto& p : m.at("pairs")) {
        auto symbol = p.at("symbol").get<std::string>();
        CHECK(scalar(*db, "SELECT count(*) FROM currency_pair WHERE ledger_id IS NULL AND deleted_at IS NULL AND "
                          "symbol = $1", {symbol}) == "1");
        CHECK(scalar(*db, "SELECT b.iso_code || q.iso_code || '|' || p.\"precision\" FROM currency_pair p "
                          "JOIN currency b ON b.uuid = p.base_currency_uuid JOIN currency q ON q.uuid = "
                          "p.quote_currency_uuid WHERE p.ledger_id IS NULL AND p.deleted_at IS NULL AND "
                          "p.symbol = $1", {symbol}) == symbol + "|5");
    }
}

TEST(default_currencies_are_served_by_reference_pull_and_not_again_past_head) {
    auto db = fixture::open();
    const json m = manifest();

    auto page = sync_repo::pull_reference_stream(*db, 0, 100000);
    REQUIRE(page.changes.contains("currency"));
    REQUIRE(page.changes.contains("currency_pair"));
    std::set<std::string> codes, symbols;
    for (const auto& row : page.changes.at("currency")) {
        if (row.contains("deleted_at") && !row.at("deleted_at").is_null()) continue;
        codes.insert(row.at("iso_code").get<std::string>());
    }
    for (const auto& row : page.changes.at("currency_pair")) {
        if (row.contains("deleted_at") && !row.at("deleted_at").is_null()) continue;
        symbols.insert(row.at("symbol").get<std::string>());
    }
    for (const auto& c : m.at("currencies")) CHECK(codes.count(c.at("iso").get<std::string>()) == 1);
    for (const auto& p : m.at("pairs")) CHECK(symbols.count(p.at("symbol").get<std::string>()) == 1);

    // Курсор на голове потока — справочник повторно не отдаётся.
    auto head = sync_repo::pull_reference_stream(*db, page.next_seq, 100000);
    CHECK(!head.changes.contains("currency") || head.changes.at("currency").empty());
    CHECK(!head.changes.contains("currency_pair") || head.changes.at("currency_pair").empty());
}

TEST(default_currencies_up_twice_changes_nothing) {
    auto db = fixture::open();
    const json m = manifest();
    auto tx = db->begin_transaction();

    auto currencies_before = scalar(tx, "SELECT count(*) FROM currency WHERE ledger_id IS NULL");
    auto pairs_before = scalar(tx, "SELECT count(*) FROM currency_pair WHERE ledger_id IS NULL");
    auto seq_before = scalar(tx, std::string("SELECT seq FROM change_stream WHERE id = ") + kStream);

    tx.exec(up_sql());

    CHECK(set_currencies_count(tx, m) == "17");
    CHECK(set_pairs_count(tx, m) == "31");
    CHECK(scalar(tx, "SELECT count(*) FROM currency WHERE ledger_id IS NULL") == currencies_before);
    CHECK(scalar(tx, "SELECT count(*) FROM currency_pair WHERE ledger_id IS NULL") == pairs_before);
    // Поток reference при повторе не двигается (нечего вставлять).
    CHECK(scalar(tx, std::string("SELECT seq FROM change_stream WHERE id = ") + kStream) == seq_before);
}

TEST(default_currencies_up_after_down_restores_same_uuids_with_one_new_seq) {
    auto db = fixture::open();
    const json m = manifest();
    auto tx = db->begin_transaction();

    auto uuids_before = scalar(tx, "SELECT string_agg(uuid::text, ',' ORDER BY uuid) FROM currency WHERE ledger_id IS "
                                   "NULL AND uuid IN (SELECT md5('reference-currency:' || n.iso)::uuid FROM (VALUES "
                                   "('EUR'), ('USD'), ('BTC')) n(iso))");
    tx.exec(down_sql());
    CHECK(set_currencies_count(tx, m) == "0");
    CHECK(set_pairs_count(tx, m) == "0");

    auto seq_before = std::stoll(scalar(tx, std::string("SELECT seq FROM change_stream WHERE id = ") + kStream));
    tx.exec(up_sql());

    CHECK(set_currencies_count(tx, m) == "17");
    CHECK(set_pairs_count(tx, m) == "31");
    CHECK(scalar(tx, "SELECT string_agg(uuid::text, ',' ORDER BY uuid) FROM currency WHERE ledger_id IS NULL AND "
                     "uuid IN (SELECT md5('reference-currency:' || n.iso)::uuid FROM (VALUES ('EUR'), ('USD'), "
                     "('BTC')) n(iso))") == uuids_before);
    // Одна вставка — один новый seq на все валюты и пары набора.
    auto seq_after = std::stoll(scalar(tx, std::string("SELECT seq FROM change_stream WHERE id = ") + kStream));
    CHECK(seq_after == seq_before + 1);
    CHECK(scalar(tx, "SELECT count(DISTINCT seq) FROM (SELECT seq FROM currency WHERE ledger_id IS NULL AND uuid IN "
                     "(SELECT md5('reference-currency:' || n.iso)::uuid FROM (VALUES ('EUR'), ('USD')) n(iso)) "
                     "UNION ALL SELECT seq FROM currency_pair WHERE ledger_id IS NULL AND symbol = 'EURUSD') x "
                     "WHERE seq = " + std::to_string(seq_after)) == "1");
}

TEST(default_currencies_up_keeps_admin_currency_with_same_code_and_pairs_use_it) {
    auto db = fixture::open();
    const json m = manifest();
    auto tx = db->begin_transaction();

    tx.exec(down_sql());
    auto admin_uuid = admin_currency(tx, "EUR", "Евро администратора");
    tx.exec(up_sql());

    // «EUR» набора пропущена — единственная живая общая EUR остаётся администраторской.
    CHECK(scalar(tx, "SELECT count(*) FROM currency WHERE ledger_id IS NULL AND deleted_at IS NULL AND iso_code = "
                     "'EUR'") == "1");
    CHECK(scalar(tx, "SELECT uuid FROM currency WHERE ledger_id IS NULL AND deleted_at IS NULL AND iso_code = "
                     "'EUR'") == admin_uuid);
    CHECK(set_currencies_count(tx, m) == "16");
    // Пары с EUR всё равно созданы — они опираются на живую общую валюту по коду.
    CHECK(scalar(tx, "SELECT count(*) FROM currency_pair p WHERE p.ledger_id IS NULL AND p.deleted_at IS NULL AND "
                     "p.symbol = 'EURUSD' AND p.base_currency_uuid = $1", {admin_uuid}) == "1");
    CHECK(set_pairs_count(tx, m) == "31");
}

TEST(default_currencies_up_keeps_admin_currency_with_same_name_other_code) {
    auto db = fixture::open();
    const json m = manifest();
    auto tx = db->begin_transaction();

    tx.exec(down_sql());
    auto admin_uuid = admin_currency(tx, "XEU", "euro"); // то же название в другом регистре
    tx.exec(up_sql());

    // Название «Euro» занято администраторской валютой — «EUR» набора пропущена целиком.
    CHECK(scalar(tx, "SELECT count(*) FROM currency WHERE ledger_id IS NULL AND deleted_at IS NULL AND "
                     "lower(name) = 'euro'") == "1");
    CHECK(scalar(tx, "SELECT uuid FROM currency WHERE ledger_id IS NULL AND deleted_at IS NULL AND "
                     "lower(name) = 'euro'") == admin_uuid);
    CHECK(scalar(tx, "SELECT count(*) FROM currency WHERE ledger_id IS NULL AND deleted_at IS NULL AND iso_code = "
                     "'EUR'") == "0");
    // Без EUR нет и пар с EUR (база или квота не нашлась) — остальные 16 валют на месте.
    CHECK(set_currencies_count(tx, m) == "16");
    CHECK(scalar(tx, "SELECT count(*) FROM currency_pair WHERE ledger_id IS NULL AND deleted_at IS NULL AND symbol "
                     "IN ('EURUSD', 'EURRUB')") == "0");
}

TEST(default_currencies_up_ignores_deleted_namesake_and_does_not_revive_it) {
    auto db = fixture::open();
    const json m = manifest();
    auto tx = db->begin_transaction();

    tx.exec(down_sql());
    admin_currency(tx, "EUR", "Euro", /*deleted=*/true);
    tx.exec(up_sql());

    CHECK(scalar(tx, "SELECT count(*) FROM currency WHERE ledger_id IS NULL AND deleted_at IS NULL AND iso_code = "
                     "'EUR'") == "1");
    CHECK(set_currencies_count(tx, m) == "17");
}

TEST(default_currencies_up_skips_currency_without_default_icon) {
    auto db = fixture::open();
    auto tx = db->begin_transaction();

    tx.exec(down_sql());
    // Иконку флага GBP «убирает» администратор: у валюты набора больше нет иконки.
    tx.exec("UPDATE icon SET deleted_at = now() WHERE ledger_id IS NULL AND lower(name) = 'flag gbp'");
    tx.exec(up_sql());

    CHECK(scalar(tx, "SELECT count(*) FROM currency WHERE ledger_id IS NULL AND deleted_at IS NULL AND iso_code = "
                     "'GBP'") == "0");
    // Пары с GBP не созданы, остальные на месте: 31 − USDGBP − EURGBP.
    CHECK(scalar(tx, "SELECT count(*) FROM currency_pair WHERE ledger_id IS NULL AND deleted_at IS NULL AND symbol IN "
                     "('USDGBP', 'EURGBP')") == "0");
    CHECK(scalar(tx, "SELECT count(*) FROM currency_pair WHERE ledger_id IS NULL AND deleted_at IS NULL AND symbol = "
                     "'EURUSD'") == "1");
}

TEST(default_currencies_down_removes_the_set_and_keeps_currency_with_references) {
    auto db = fixture::open();
    const json m = manifest();
    auto id = fixture::make_identity(*db);
    auto tx = db->begin_transaction();

    // Своя пара леджера опирается на общие RUB и USD набора: внешний ключ не даст их удалить.
    tx.exec(std::string("INSERT INTO currency_pair (uuid, ledger_id, seq, symbol, base_currency_uuid, "
                        "quote_currency_uuid) VALUES ($1, $2, (SELECT next_seq($2::uuid)), $3, "
                        "md5('reference-currency:RUB')::uuid, md5('reference-currency:USD')::uuid)"),
            {uuidgen::v4(), id.ledger_id, "RUBUSD"});
    // Админская пара и валюта вне набора — откат их не трогает.
    auto admin = admin_currency(tx, "ZZ" + uuidgen::v4().substr(0, 4), "Admin " + uuidgen::v4().substr(0, 8));

    tx.exec(down_sql());

    CHECK(scalar(tx, "SELECT count(*) FROM currency WHERE uuid = $1", {admin}) == "1");
    // RUB и USD остались из-за ссылки, остальные 15 валют набора и все 31 пара набора ушли.
    CHECK(set_currencies_count(tx, m) == "2");
    CHECK(set_pairs_count(tx, m) == "0");
    CHECK(scalar(tx, "SELECT count(*) FROM currency WHERE ledger_id IS NULL AND uuid IN "
                     "(md5('reference-currency:RUB')::uuid, md5('reference-currency:USD')::uuid)") == "2");
}
