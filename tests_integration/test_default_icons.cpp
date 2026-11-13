// Миграция 000037_default_reference_icons (change default-reference-icons):
// общий набор иконок по умолчанию — состав, хеши, выдача через pull потока
// reference, идемпотентность, уважение иконок администратора и откат.
//
// Набор уже накачен миграциями, на которых стоит тестовая база. Повтор up.sql и
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

// В тестовом образе миграции лежат в /src/migrations (Containerfile копирует их
// рядом с исходниками); локально можно переопределить переменной окружения.
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

json manifest() { return json::parse(read_file(migrations_dir() + "/default_icons/manifest.json")); }

std::string up_sql() { return read_file(migrations_dir() + "/000037_default_reference_icons.up.sql"); }
std::string down_sql() { return read_file(migrations_dir() + "/000037_default_reference_icons.down.sql"); }

std::string scalar(db::Database::Transaction& tx, const std::string& sql, const std::vector<std::string>& p = {}) {
    return tx.exec(sql, p).rows.at(0).fields.at(0);
}

std::string scalar(db::Database& db, const std::string& sql, const std::vector<std::string>& p = {}) {
    return db.exec(sql, p).rows.at(0).fields.at(0);
}

constexpr const char* kStream = "'00000000-0000-0000-0000-000000000001'";

// Сколько живых общих иконок набора (по детерминированному uuid) стоит в базе.
std::string set_icons_count(db::Database::Transaction& tx, const json& m) {
    std::string names;
    for (const auto& e : m) {
        if (!names.empty()) names += ",";
        names += "('" + e.at("name").get<std::string>() + "')";
    }
    return scalar(tx,
                  "SELECT count(*) FROM icon i WHERE i.ledger_id IS NULL AND i.deleted_at IS NULL AND i.uuid IN "
                  "(SELECT md5('reference-icon:' || lower(n.name))::uuid FROM (VALUES " + names + ") n(name))");
}

// Свой blob и общая иконка администратора с ним (в обход ручек — как fixture.hpp).
std::string admin_icon(db::Database::Transaction& tx, const std::string& name, const std::string& sha256_hex,
                       bool deleted = false) {
    tx.exec("INSERT INTO blob (sha256, bytes) VALUES (decode($1, 'hex'), decode('00', 'hex')) "
            "ON CONFLICT (sha256) DO NOTHING",
            {sha256_hex});
    std::string uuid = uuidgen::v4();
    tx.exec(std::string("INSERT INTO icon (uuid, seq, name, content_sha256, icon_type, deleted_at) VALUES "
                        "($1, (SELECT next_seq(") + kStream + ")), $2, decode($3, 'hex'), 2, " +
                (deleted ? "now()" : "NULL") + ")",
            {uuid, name, sha256_hex});
    return uuid;
}

} // namespace

TEST(default_icons_exist_with_matching_names_types_and_hashes) {
    auto db = fixture::open();
    const json m = manifest();
    REQUIRE(m.size() > 0);

    // Для каждого имени набора есть живая общая иконка (без учёта регистра).
    for (const auto& e : m) {
        auto name = e.at("name").get<std::string>();
        auto count = scalar(*db,
                            "SELECT count(*) FROM icon WHERE ledger_id IS NULL AND deleted_at IS NULL AND "
                            "lower(name) = lower($1)",
                            {name});
        CHECK(count == "1");
    }

    // Запасная иконка по icon-sync.
    CHECK(scalar(*db, "SELECT count(*) FROM icon WHERE ledger_id IS NULL AND deleted_at IS NULL AND lower(name) = "
                      "'unknown'") == "1");

}

TEST(default_icons_hashes_match_blob_bytes_and_types_match_manifest) {
    auto db = fixture::open();
    const json m = manifest();
    std::string names;
    for (const auto& e : m) {
        if (!names.empty()) names += ",";
        names += "('" + e.at("name").get<std::string>() + "')";
    }
    // Иконок набора, у которых sha256(bytes) расходится с content_sha256 или нет blob, нет.
    auto bad = scalar(*db,
                      "SELECT count(*) FROM icon i LEFT JOIN blob b ON b.sha256 = i.content_sha256 "
                      "WHERE i.ledger_id IS NULL AND i.uuid IN (SELECT md5('reference-icon:' || lower(n.name))::uuid "
                      "FROM (VALUES " + names + ") n(name)) AND (b.sha256 IS NULL OR sha256(b.bytes) <> i.content_sha256)");
    CHECK(bad == "0");

    // Типы: флаги — 1, остальное — 2, как в манифесте.
    for (const auto& e : m) {
        auto name = e.at("name").get<std::string>();
        auto type = e.at("icon_type").get<int>();
        auto count = scalar(*db,
                            "SELECT count(*) FROM icon WHERE ledger_id IS NULL AND deleted_at IS NULL AND "
                            "lower(name) = lower($1) AND icon_type = $2",
                            {name, std::to_string(type)});
        // Тёзка-админ мог занять имя с другим типом — тогда иконки набора с этим именем нет вовсе.
        auto set_owned = scalar(*db,
                                std::string("SELECT count(*) FROM icon WHERE ledger_id IS NULL AND uuid = ") +
                                    "md5('reference-icon:' || lower($1))::uuid",
                                {name});
        if (set_owned == "1") CHECK(count == "1");
    }
}

TEST(default_icons_are_served_by_reference_pull_and_not_again_past_head) {
    auto db = fixture::open();
    const json m = manifest();

    auto page = sync_repo::pull_reference_stream(*db, 0, 100000);
    REQUIRE(page.changes.contains("icon"));
    std::set<std::string> pulled;
    for (const auto& row : page.changes.at("icon")) {
        if (row.contains("deleted_at") && !row.at("deleted_at").is_null()) continue;
        std::string name = row.at("name").get<std::string>();
        std::transform(name.begin(), name.end(), name.begin(), [](unsigned char c) { return std::tolower(c); });
        pulled.insert(name);
        CHECK(row.at("content_sha256").get<std::string>().size() == 64);
    }
    for (const auto& e : m) {
        std::string name = e.at("name").get<std::string>();
        std::transform(name.begin(), name.end(), name.begin(), [](unsigned char c) { return std::tolower(c); });
        CHECK(pulled.count(name) == 1);
    }

    // Курсор на голове потока — набор повторно не отдаётся.
    auto head = sync_repo::pull_reference_stream(*db, page.next_seq, 100000);
    CHECK(!head.changes.contains("icon") || head.changes.at("icon").empty());
}

TEST(default_icons_up_twice_changes_nothing) {
    auto db = fixture::open();
    const json m = manifest();
    auto tx = db->begin_transaction();

    auto before_count = set_icons_count(tx, m);
    auto before_seq = scalar(tx, std::string("SELECT seq FROM change_stream WHERE id = ") + kStream);
    auto before_icons = scalar(tx, "SELECT count(*) FROM icon WHERE ledger_id IS NULL");

    tx.exec(up_sql());

    CHECK(set_icons_count(tx, m) == before_count);
    CHECK(scalar(tx, "SELECT count(*) FROM icon WHERE ledger_id IS NULL") == before_icons);
    // Поток reference при повторе не двигается (нечего вставлять).
    CHECK(scalar(tx, std::string("SELECT seq FROM change_stream WHERE id = ") + kStream) == before_seq);
}

TEST(default_icons_up_after_down_restores_same_uuids_with_one_new_seq) {
    auto db = fixture::open();
    const json m = manifest();
    auto tx = db->begin_transaction();

    auto uuids_before = scalar(tx,
                               "SELECT string_agg(uuid::text, ',' ORDER BY uuid) FROM icon WHERE ledger_id IS NULL AND "
                               "uuid IN (SELECT md5('reference-icon:' || lower(name))::uuid FROM (VALUES ('Groceries'), "
                               "('Flag USD'), ('unknown')) n(name))");
    tx.exec(down_sql());
    CHECK(set_icons_count(tx, m) == "0");

    auto seq_before = std::stoll(scalar(tx, std::string("SELECT seq FROM change_stream WHERE id = ") + kStream));
    tx.exec(up_sql());

    CHECK(set_icons_count(tx, m) == std::to_string(m.size()));
    auto uuids_after = scalar(tx,
                              "SELECT string_agg(uuid::text, ',' ORDER BY uuid) FROM icon WHERE ledger_id IS NULL AND "
                              "uuid IN (SELECT md5('reference-icon:' || lower(name))::uuid FROM (VALUES ('Groceries'), "
                              "('Flag USD'), ('unknown')) n(name))");
    CHECK(uuids_after == uuids_before);
    // Одна вставка — один новый seq на все иконки набора.
    auto seq_after = std::stoll(scalar(tx, std::string("SELECT seq FROM change_stream WHERE id = ") + kStream));
    CHECK(seq_after == seq_before + 1);
    CHECK(scalar(tx, "SELECT count(DISTINCT seq) FROM icon WHERE ledger_id IS NULL AND uuid IN "
                     "(SELECT md5('reference-icon:' || lower(name))::uuid FROM (VALUES ('Groceries'), ('Flag USD'), "
                     "('unknown')) n(name)) AND seq = " + std::to_string(seq_after)) == "1");
}

TEST(default_icons_up_keeps_admin_icon_with_same_name_in_other_case) {
    auto db = fixture::open();
    const json m = manifest();
    auto tx = db->begin_transaction();

    tx.exec(down_sql());
    auto admin_uuid = admin_icon(tx, "groceries", fixture::detail::random_hex64());
    tx.exec(up_sql());

    // «Groceries» набора пропущена, остаётся единственная живая — администратора, с прежним uuid.
    CHECK(scalar(tx, "SELECT count(*) FROM icon WHERE ledger_id IS NULL AND deleted_at IS NULL AND "
                     "lower(name) = 'groceries'") == "1");
    CHECK(scalar(tx, "SELECT uuid FROM icon WHERE ledger_id IS NULL AND deleted_at IS NULL AND "
                     "lower(name) = 'groceries'") == admin_uuid);
    // Остальные иконки набора добавлены: их на одну меньше.
    CHECK(set_icons_count(tx, m) == std::to_string(m.size() - 1));
}

TEST(default_icons_up_ignores_deleted_namesake) {
    auto db = fixture::open();
    auto tx = db->begin_transaction();

    tx.exec(down_sql());
    admin_icon(tx, "Groceries", fixture::detail::random_hex64(), /*deleted=*/true);
    tx.exec(up_sql());

    CHECK(scalar(tx, "SELECT count(*) FROM icon WHERE ledger_id IS NULL AND deleted_at IS NULL AND "
                     "lower(name) = 'groceries'") == "1");
    CHECK(scalar(tx, "SELECT count(*) FROM icon WHERE ledger_id IS NULL AND deleted_at IS NULL AND "
                     "lower(name) = 'groceries' AND uuid = md5('reference-icon:groceries')::uuid") == "1");
}

TEST(default_icons_down_removes_only_the_set_and_keeps_shared_blob) {
    auto db = fixture::open();
    const json m = manifest();
    auto tx = db->begin_transaction();

    // Иконка администратора вне набора и иконка на тот же blob, что у «Flag USD» набора.
    auto cinema = admin_icon(tx, "Cinema-" + uuidgen::v4().substr(0, 8), fixture::detail::random_hex64());
    auto shared_sha = scalar(tx, std::string("SELECT encode(content_sha256, 'hex') FROM icon WHERE uuid = ") +
                                     "md5('reference-icon:flag usd')::uuid");
    tx.exec(std::string("INSERT INTO icon (uuid, seq, name, content_sha256, icon_type) VALUES ($1, "
                        "(SELECT next_seq(") + kStream + ")), $2, decode($3, 'hex'), 1)",
            {uuidgen::v4(), "My USD " + uuidgen::v4().substr(0, 8), shared_sha});

    // Картинка «Groceries» набора: на неё чужих ссылок нет, после отката её blob должен уйти.
    auto groceries_sha = scalar(tx, "SELECT encode(content_sha256, 'hex') FROM icon WHERE uuid = "
                                    "md5('reference-icon:groceries')::uuid");

    tx.exec(down_sql());

    CHECK(set_icons_count(tx, m) == "0");
    CHECK(scalar(tx, "SELECT count(*) FROM icon WHERE uuid = $1", {cinema}) == "1");
    CHECK(scalar(tx, "SELECT count(*) FROM blob WHERE sha256 = decode($1, 'hex')", {shared_sha}) == "1");
    CHECK(scalar(tx, "SELECT count(*) FROM blob WHERE sha256 = decode($1, 'hex')", {groceries_sha}) == "0");
}
