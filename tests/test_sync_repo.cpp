// Юнит-тесты чисто табличного описания протокола синка (sync_repo.hpp) —
// то немногое в sync_repo.cpp, что не требует живого Postgres. Сам
// push_batch()/pull_*_stream() (SQL, транзакции, дедлок 2026-09-04, который
// они когда-то ловили) — материал для tests_integration/, см. её README:
// без реальной базы это честно не проверить, а притворяться, что проверено
// (фейковый db::Database) значило бы вносить абстракцию в прод-код только
// ради теста.
//
// Ценность этих тестов узкая, но конкретная: опечатка при добавлении новой
// таблицы в TableSpec (например, забытое numeric-поле или не тот scope)
// иначе всплыла бы только на реальном push/pull, а тут — сразу.
#include "sync_repo.hpp"

#include <algorithm>
#include <set>

#include "test_framework.hpp"

using sync_repo::pull_tables;
using sync_repo::push_tables;
using sync_repo::Scope;
using sync_repo::TableSpec;

namespace {

const TableSpec* find(const std::vector<TableSpec>& tables, const std::string& name) {
    for (const auto& t : tables) {
        if (t.name == name) return &t;
    }
    return nullptr;
}

bool has_duplicates(const std::vector<TableSpec>& tables) {
    std::set<std::string> seen;
    for (const auto& t : tables) {
        if (!seen.insert(t.name).second) return true;
    }
    return false;
}

} // namespace

TEST(push_tables_has_no_duplicate_names) {
    CHECK(!has_duplicates(push_tables()));
}

TEST(pull_tables_has_no_duplicate_names) {
    CHECK(!has_duplicates(pull_tables()));
}

TEST(push_includes_icon) {
    // icon (метаданные — не содержимое, см. sync_repo.hpp, шапка файла)
    // теперь обычная синхронизируемая таблица, как и остальные восемь.
    CHECK(find(push_tables(), "icon") != nullptr);
}

TEST(pull_tables_equals_push_tables) {
    // Раньше отличалось на "icon" (pull-only) — теперь push и pull видят
    // ровно один и тот же набор таблиц (см. sync_repo.hpp, pull_tables()).
    CHECK_EQ(pull_tables().size(), push_tables().size());
    for (const auto& t : push_tables()) {
        CHECK(find(pull_tables(), t.name) != nullptr);
    }
}

TEST(icon_content_sha256_is_hex_column) {
    // См. TableSpec::hex_columns — content_sha256 (bytea) кодируется как
    // hex-строка на границе протокола, не голыми байтами (db.hpp: сырые
    // байты параметром SQL передавать нельзя, см. util/hex.hpp).
    const TableSpec* icon = find(push_tables(), "icon");
    REQUIRE(icon != nullptr);
    CHECK_EQ(icon->hex_columns.size(), static_cast<std::size_t>(1));
    CHECK(std::find(icon->hex_columns.begin(), icon->hex_columns.end(), "content_sha256") !=
          icon->hex_columns.end());
}

TEST(hex_columns_is_always_a_subset_of_columns) {
    // Тот же класс проверки, что numeric_columns_is_always_a_subset_of_columns
    // ниже — patch в build_candidates ссылается на колонку по имени, опечатка
    // сломала бы SQL на реальной таблице, а не здесь.
    for (const auto& t : pull_tables()) {
        for (const auto& hex_col : t.hex_columns) {
            bool found = std::find(t.columns.begin(), t.columns.end(), hex_col) != t.columns.end();
            CHECK(found);
        }
    }
}

TEST(numeric_columns_is_always_a_subset_of_columns) {
    // См. sync_repo.hpp: numeric_columns патчится в pull-запросе через
    // jsonb_build_object(col::text) поверх to_jsonb(t.*) — колонки не из
    // columns там взяться не может, а если она туда попадёт по ошибке,
    // сгенерированный SQL сломается на реальной таблице (но лучше поймать
    // это здесь, а не по факту 500-й ошибки).
    for (const auto& t : pull_tables()) {
        for (const auto& numeric_col : t.numeric_columns) {
            bool found =
                std::find(t.columns.begin(), t.columns.end(), numeric_col) != t.columns.end();
            CHECK(found);
        }
    }
}

TEST(operation_amount_is_numeric) {
    // Это и есть колонка из README wallet-api, "Синхронизация" — amount
    // должен прийти строкой на pull, не голым JSON-числом (иначе то самое
    // "amount as number" из README снова тихо вернётся).
    const TableSpec* operation = find(push_tables(), "operation");
    REQUIRE(operation != nullptr);
    CHECK_EQ(operation->numeric_columns.size(), static_cast<std::size_t>(1));
    CHECK(std::find(operation->numeric_columns.begin(), operation->numeric_columns.end(),
                     "amount") != operation->numeric_columns.end());
}

TEST(currency_pair_rate_rate_is_numeric) {
    const TableSpec* rate_table = find(push_tables(), "currency_pair_rate");
    REQUIRE(rate_table != nullptr);
    CHECK_EQ(rate_table->numeric_columns.size(), static_cast<std::size_t>(1));
    CHECK(std::find(rate_table->numeric_columns.begin(), rate_table->numeric_columns.end(),
                     "rate") != rate_table->numeric_columns.end());
}

TEST(currency_pair_rate_date_is_date_only_column) {
    // См. TableSpec::date_only_columns — upsert_row обрезает "date" до
    // "yyyy-MM-dd" явно (вторая линия обороны поверх клиента, который тоже
    // больше не должен слать время — см. Android SyncEngine.collectDirty):
    // два локальных дубля одной даты с разным временем иначе бьются об
    // uq_currency_pair_rate_* при push (org/docs/TODO_mobile_sync.md).
    const TableSpec* rate_table = find(push_tables(), "currency_pair_rate");
    REQUIRE(rate_table != nullptr);
    CHECK_EQ(rate_table->date_only_columns.size(), static_cast<std::size_t>(1));
    CHECK(std::find(rate_table->date_only_columns.begin(), rate_table->date_only_columns.end(),
                     "date") != rate_table->date_only_columns.end());
}

TEST(date_only_columns_is_always_a_subset_of_columns) {
    // Тот же класс проверки, что hex_columns_is_always_a_subset_of_columns
    // выше.
    for (const auto& t : pull_tables()) {
        for (const auto& date_col : t.date_only_columns) {
            bool found = std::find(t.columns.begin(), t.columns.end(), date_col) != t.columns.end();
            CHECK(found);
        }
    }
}

TEST(only_amount_and_rate_tables_have_numeric_columns) {
    // Отрицательный вариант предыдущих двух тестов — на случай, если
    // numeric_columns однажды повесят не на ту таблицу по ошибке copy-paste.
    for (const auto& t : push_tables()) {
        if (t.name == "operation" || t.name == "currency_pair_rate") continue;
        CHECK(t.numeric_columns.empty());
    }
}

TEST(ledger_data_tables_have_ledger_only_scope) {
    for (const char* name : {"account", "account_operating", "operation", "operation_link"}) {
        const TableSpec* t = find(push_tables(), name);
        REQUIRE(t != nullptr);
        CHECK(t->scope == Scope::LedgerOnly);
    }
}

TEST(reference_tables_have_reference_or_ledger_scope) {
    for (const char* name :
         {"currency", "currency_pair", "currency_pair_rate", "currency_conversion", "icon"}) {
        const TableSpec* t = find(pull_tables(), name);
        REQUIRE(t != nullptr);
        CHECK(t->scope == Scope::ReferenceOrLedger);
    }
}

TEST(currency_pair_rate_conflicts_on_natural_key_not_uuid) {
    // См. TableSpec::conflict_columns — два офлайн-устройства могут прислать
    // РАЗНЫЕ uuid на одну и ту же (ledger, пара, дата): `ON CONFLICT (uuid)`
    // это не поймает, INSERT падает прямо на uq_currency_pair_rate_ledger
    // (23505), не доходя до ON CONFLICT (реальный кейс, POST /sync/push, см.
    // org/docs/TODO_mobile_sync.md). Резолвим по естественному ключу — тому
    // же, что уже использует клиент (WalletDbCRUD.InsertOrReplaceRate).
    const TableSpec* rate_table = find(push_tables(), "currency_pair_rate");
    REQUIRE(rate_table != nullptr);
    std::vector<std::string> expected = {"ledger_id", "currency_pair_uuid", "date"};
    CHECK(rate_table->conflict_columns == expected);
    // conflict_where — предикат частичного индекса-арбитра
    // (uq_currency_pair_rate_ledger), без него Postgres не примет частичный
    // индекс как arbiter (см. upsert_row).
    CHECK(!rate_table->conflict_where.empty());
}

TEST(conflict_columns_is_ledger_id_or_a_subset_of_columns) {
    // Тот же класс проверки, что hex/numeric/date_only_columns выше — но
    // conflict_columns вправе содержать ещё и "ledger_id" (общая колонка,
    // не бизнес-колонка из TableSpec::columns, см. upsert_row).
    for (const auto& t : pull_tables()) {
        for (const auto& col : t.conflict_columns) {
            bool ok = col == "ledger_id" ||
                      std::find(t.columns.begin(), t.columns.end(), col) != t.columns.end();
            CHECK(ok);
        }
    }
}

TEST(only_currency_pair_rate_has_conflict_columns) {
    // Отрицательный вариант — на случай, если conflict_columns однажды
    // повесят не на ту таблицу по ошибке copy-paste (см.
    // only_amount_and_rate_tables_have_numeric_columns выше).
    for (const auto& t : push_tables()) {
        if (t.name == "currency_pair_rate") continue;
        CHECK(t.conflict_columns.empty());
    }
}

TEST(create_only_violation_allows_only_new_operations) {
    using nlohmann::json;
    using sync_repo::create_only_violation;
    json op = {{"uuid", "u"}, {"amount", "1"}};
    CHECK(create_only_violation(json{{"operation", json::array({op})}}).empty());
    CHECK(create_only_violation(json::object()).empty());
    json not_deleted = op;
    not_deleted["deleted"] = false;
    CHECK(create_only_violation(json{{"operation", json::array({not_deleted})}}).empty());

    CHECK_EQ(create_only_violation(json{{"operation", json::array({op})}, {"account", json::array()}}),
             std::string("only_operation"));
    CHECK_EQ(create_only_violation(json{{"operation_link", json::array()}}), std::string("only_operation"));
    CHECK_EQ(create_only_violation(json{{"operation", json::object()}}), std::string("only_operation"));
    CHECK_EQ(create_only_violation(json{{"operation", json::array({1})}}), std::string("only_operation"));
    CHECK_EQ(create_only_violation(json::array()), std::string("only_operation"));

    json deleted = op;
    deleted["deleted"] = true;
    CHECK_EQ(create_only_violation(json{{"operation", json::array({deleted})}}), std::string("delete_not_allowed"));
    deleted["deleted"] = "yes"; // не булево — тоже нельзя
    CHECK_EQ(create_only_violation(json{{"operation", json::array({deleted})}}), std::string("delete_not_allowed"));
}
