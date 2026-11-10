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
#include <stdexcept>

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
    for (const char* name : {"account", "account_operating", "account_asset", "operation", "operation_link"}) {
        const TableSpec* t = find(push_tables(), name);
        REQUIRE(t != nullptr);
        CHECK(t->scope == Scope::LedgerOnly);
    }
}

TEST(account_asset_requires_all_business_columns) {
    // design D2 capital-assets: все три поля обязательны (нет optional_columns).
    const TableSpec* t = find(push_tables(), "account_asset");
    REQUIRE(t != nullptr);
    CHECK(t->columns == std::vector<std::string>({"asset_type", "include_in_net_worth", "comment"}));
    CHECK(t->optional_columns.empty());
    CHECK(t->numeric_columns.empty());
}

TEST(apply_order_covers_push_tables_and_puts_parents_first) {
    const auto& order = sync_repo::apply_order();
    std::set<std::string> ordered(order.begin(), order.end());
    std::set<std::string> pushed;
    for (const auto& t : push_tables()) pushed.insert(t.name);
    CHECK(ordered == pushed);
    CHECK_EQ(ordered.size(), order.size());

    auto pos = [&](const std::string& name) { return std::find(order.begin(), order.end(), name) - order.begin(); };
    // Ссылающаяся таблица применяется после той, на которую ссылается —
    // иначе батч «новый кошелёк-актив» упал бы на 23503.
    for (const auto& ref : sync_repo::sync_table_refs()) {
        CHECK(pos(ref.parent) < pos(ref.child));
    }
    CHECK_EQ(pos("account_asset"), pos("account_operating") + 1);
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

// --- Каскад мягкого удаления (changes cascade-link-tombstones, cascade-asset-tombstones) ---

namespace {

bool sql_has(const std::string& haystack, const std::string& needle) {
    return haystack.find(needle) != std::string::npos;
}

const sync_repo::CascadeRule& rule_for(const std::string& child) {
    for (const auto& r : sync_repo::cascade_rules()) {
        if (r.child == child) return r;
    }
    throw std::runtime_error("нет правила каскада для " + child);
}

// Ссылка child.<column> → parent есть в sync_table_refs() напрямую или (для
// общего uuid кошелька) через одну промежуточную таблицу по тому же uuid.
bool references(const std::string& child, const std::string& column, const std::string& parent) {
    auto direct = [](const std::string& c, const std::string& col, const std::string& p) {
        for (const auto& ref : sync_repo::sync_table_refs()) {
            if (ref.child == c && ref.parent == p && ref.child_columns.back() == col) return true;
        }
        return false;
    };
    if (direct(child, column, parent)) return true;
    if (column != "uuid") return false;
    for (const auto& ref : sync_repo::sync_table_refs()) {
        if (ref.child == child && ref.child_columns.back() == "uuid" && direct(ref.parent, "uuid", parent)) return true;
    }
    return false;
}

} // namespace

TEST(cascade_rules_follow_sync_table_refs) {
    CHECK_EQ(sync_repo::cascade_rules().size(), 2u);
    for (const auto& rule : sync_repo::cascade_rules()) {
        CHECK(find(push_tables(), rule.child) != nullptr);
        for (const auto& p : rule.parents) {
            CHECK(find(push_tables(), p.table) != nullptr);
            CHECK(references(rule.child, p.child_column, p.table));
        }
    }
}

TEST(cascade_inputs_for_links_collect_deleted_operations_and_live_links) {
    using nlohmann::json;
    json changes = {
        {"operation", json::array({json{{"uuid", "op-del"}, {"deleted", true}},
                                   json{{"uuid", "op-live"}},
                                   json{{"uuid", "op-false"}, {"deleted", false}},
                                   json{{"deleted", true}}, // без uuid — пропуск
                                   1})},
        {"operation_link", json::array({json{{"uuid", "link-live"}},
                                        json{{"uuid", "link-false"}, {"deleted", false}},
                                        json{{"uuid", "link-del"}, {"deleted", true}}})},
        {"account", json::array({json{{"uuid", "acc"}, {"deleted", true}}})},
    };
    auto in = sync_repo::cascade_inputs(changes, rule_for("operation_link"));
    // operation — родитель дважды (main_uuid, link_uuid), uuid не дублируется.
    CHECK(in.deleted_parents == std::vector<std::string>{"op-del"});
    CHECK(in.live_children == (std::vector<std::string>{"link-live", "link-false"}));
    CHECK(!in.empty());
}

TEST(cascade_inputs_for_assets_collect_deleted_wallets_and_live_assets) {
    using nlohmann::json;
    json changes = {
        {"account", json::array({json{{"uuid", "w1"}, {"deleted", true}}, json{{"uuid", "w3"}}})},
        {"account_operating", json::array({json{{"uuid", "w1"}, {"deleted", true}},
                                           json{{"uuid", "w2"}, {"deleted", true}}})},
        {"account_asset", json::array({json{{"uuid", "w4"}}, json{{"uuid", "w5"}, {"deleted", true}}})},
        {"operation", json::array({json{{"uuid", "op"}, {"deleted", true}}})},
    };
    auto in = sync_repo::cascade_inputs(changes, rule_for("account_asset"));
    CHECK(in.deleted_parents == (std::vector<std::string>{"w1", "w2"}));
    CHECK(in.live_children == std::vector<std::string>{"w4"});
}

TEST(cascade_inputs_is_empty_without_deletes_or_children) {
    using nlohmann::json;
    const auto& links = rule_for("operation_link");
    CHECK(sync_repo::cascade_inputs(json::object(), links).empty());
    CHECK(sync_repo::cascade_inputs(json::array(), links).empty());
    CHECK(sync_repo::cascade_inputs(json{{"operation", json::object()}}, links).empty());
    CHECK(sync_repo::cascade_inputs(json{{"operation", json::array({json{{"uuid", "op"}}})}}, links).empty());
    // Не-булево deleted не бросает и не считается удалением.
    CHECK(sync_repo::cascade_inputs(json{{"operation", json::array({json{{"uuid", "op"}, {"deleted", "yes"}}})}},
                                    links)
              .deleted_parents.empty());
}

TEST(build_cascade_sql_checks_every_parent_and_dedupes_columns) {
    std::string links = sync_repo::build_cascade_sql(rule_for("operation_link"));
    CHECK(sql_has(links, "UPDATE operation_link c SET deleted_at = now(), seq = $2, updated_by = $3"));
    CHECK(sql_has(links, "c.main_uuid = ANY($4::uuid[]) OR c.link_uuid = ANY($4::uuid[]) OR c.uuid = ANY($5::uuid[])"));
    CHECK(sql_has(links, "FROM operation p WHERE p.ledger_id = c.ledger_id AND p.uuid = c.main_uuid"));
    CHECK(sql_has(links, "FROM operation p WHERE p.ledger_id = c.ledger_id AND p.uuid = c.link_uuid"));

    std::string assets = sync_repo::build_cascade_sql(rule_for("account_asset"));
    // Оба родителя — по uuid: колонка в списке кандидатов одна.
    CHECK(sql_has(assets, "(c.uuid = ANY($4::uuid[]) OR c.uuid = ANY($5::uuid[]))"));
    CHECK(sql_has(assets, "FROM account_operating p WHERE"));
    CHECK(sql_has(assets, "FROM account p WHERE"));
    CHECK(sql_has(assets, "RETURNING 1"));
}

TEST(pg_array_literal_joins_values_in_braces) {
    using sync_repo::pg_array_literal;
    CHECK_EQ(pg_array_literal({}), std::string("{}"));
    CHECK_EQ(pg_array_literal({"a"}), std::string("{a}"));
    CHECK_EQ(pg_array_literal({"a", "b"}), std::string("{a,b}"));
}

// --- Необязательные колонки push (change currency-ui-tweaks, design D2) ---

namespace {

bool has(const std::string& haystack, const std::string& needle) {
    return haystack.find(needle) != std::string::npos;
}

nlohmann::json currency_row() {
    return nlohmann::json{{"uuid", "11111111-1111-1111-1111-111111111111"},
                          {"name", "Тенге"},
                          {"iso_code", "KZT"},
                          {"icon_uuid", "22222222-2222-2222-2222-222222222222"},
                          {"symbol", "₸"},
                          {"precision", 2}};
}

} // namespace

TEST(optional_columns_is_always_a_subset_of_columns) {
    for (const auto& t : push_tables()) {
        for (const auto& col : t.optional_columns) {
            CHECK(std::find(t.columns.begin(), t.columns.end(), col) != t.columns.end());
        }
    }
}

TEST(only_currency_show_in_equivalent_is_optional) {
    // account.kind и прочие бизнес-колонки остаются обязательными (design D3).
    for (const auto& t : push_tables()) {
        if (t.name == "currency") {
            std::vector<std::string> expected = {"show_in_equivalent"};
            CHECK(t.optional_columns == expected);
        } else {
            CHECK(t.optional_columns.empty());
        }
    }
}

TEST(build_upsert_omits_absent_optional_column_everywhere) {
    const TableSpec* currency = find(push_tables(), "currency");
    REQUIRE(currency != nullptr);
    auto q = sync_repo::build_upsert(*currency, "ledger", "device", 7, currency_row());
    CHECK(!has(q.insert_sql, "show_in_equivalent"));
    CHECK(!has(q.update_set, "show_in_equivalent"));
    CHECK(!has(q.update_by_uuid_set, "show_in_equivalent"));
    // 5 общих параметров + 5 бизнес-колонок без флага.
    CHECK_EQ(q.params.size(), static_cast<std::size_t>(10));
    // Остальные колонки на месте, guard общей строки тоже.
    CHECK(has(q.update_set, "symbol = EXCLUDED.symbol"));
    CHECK(has(q.update_set, "WHERE currency.ledger_id = EXCLUDED.ledger_id"));
}

TEST(build_upsert_includes_present_optional_column) {
    const TableSpec* currency = find(push_tables(), "currency");
    REQUIRE(currency != nullptr);
    auto row = currency_row();
    row["show_in_equivalent"] = false;
    auto q = sync_repo::build_upsert(*currency, "ledger", "device", 7, row);
    CHECK(has(q.insert_sql, ", show_in_equivalent) VALUES"));
    CHECK(has(q.update_set, "show_in_equivalent = EXCLUDED.show_in_equivalent"));
    CHECK(has(q.update_by_uuid_set, "show_in_equivalent = $11"));
    REQUIRE(q.params.size() == static_cast<std::size_t>(11));
    CHECK_EQ(q.params.back(), std::string("f"));
}

TEST(build_upsert_rejects_non_boolean_optional_column) {
    const TableSpec* currency = find(push_tables(), "currency");
    REQUIRE(currency != nullptr);
    auto row = currency_row();
    row["show_in_equivalent"] = "yes";
    std::string detail;
    try {
        sync_repo::build_upsert(*currency, "ledger", "device", 7, row);
    } catch (const sync_repo::InvalidRow& e) {
        detail = e.detail;
    }
    CHECK(has(detail, "show_in_equivalent"));
    row["show_in_equivalent"] = nullptr; // null — тоже не boolean
    CHECK_THROWS(sync_repo::build_upsert(*currency, "ledger", "device", 7, row));
}

TEST(build_upsert_still_requires_mandatory_columns) {
    const TableSpec* currency = find(push_tables(), "currency");
    REQUIRE(currency != nullptr);
    auto row = currency_row();
    row.erase("symbol");
    CHECK_THROWS(sync_repo::build_upsert(*currency, "ledger", "device", 7, row));
}

// --- Срок хранения tombstone (change purge-synced-tombstones) ---------------

TEST(reset_reason_none_for_zero_cursor_even_if_purged) {
    // Курсор 0 — не отставание: клиент и так читает с нуля.
    CHECK(sync_repo::reset_reason_for(0, 100, 500) == sync_repo::ResetReason::None);
}

TEST(reset_reason_ahead_when_cursor_beyond_head) {
    CHECK(sync_repo::reset_reason_for(146, 13, 0) == sync_repo::ResetReason::Ahead);
    // "ahead" проверяется первым: курсор не от этого потока вообще.
    CHECK(sync_repo::reset_reason_for(600, 550, 500) == sync_repo::ResetReason::Ahead);
}

TEST(reset_reason_purged_when_cursor_behind_purged_seq) {
    CHECK(sync_repo::reset_reason_for(40, 600, 500) == sync_repo::ResetReason::Purged);
    CHECK(sync_repo::reset_reason_for(499, 600, 500) == sync_repo::ResetReason::Purged);
}

TEST(reset_reason_none_when_cursor_equals_purged_seq_or_head) {
    CHECK(sync_repo::reset_reason_for(500, 600, 500) == sync_repo::ResetReason::None);
    CHECK(sync_repo::reset_reason_for(600, 600, 500) == sync_repo::ResetReason::None);
    CHECK(sync_repo::reset_reason_for(10, 600, 0) == sync_repo::ResetReason::None);
}

TEST(reset_reason_none_while_loading_from_zero_and_purged_seq_not_grown) {
    // Ручная проверка на test 2026-11-04: загрузка с нуля, первая страница
    // кончилась на 13, поток вычищен до 77 — без отметки начала загрузки
    // "purged" отправлял устройство снова на 0, бесконечно.
    CHECK(sync_repo::reset_reason_for(13, 78, 77, 77) == sync_repo::ResetReason::None);
    // Отметка с бóльшим purged_seq (чистка откатиться не может, но пусть) — тоже не отставание.
    CHECK(sync_repo::reset_reason_for(13, 78, 77, 90) == sync_repo::ResetReason::None);
}

TEST(reset_reason_purged_when_purged_seq_grew_since_load_started) {
    // Устройство начинало при purged_seq 77, бросило загрузку, выпало из
    // горизонта, поток вычищен дальше — удаления после 13 потеряны.
    CHECK(sync_repo::reset_reason_for(13, 120, 100, 77) == sync_repo::ResetReason::Purged);
    // Устройство грузилось с нуля ещё до любой чистки.
    CHECK(sync_repo::reset_reason_for(13, 120, 100, 0) == sync_repo::ResetReason::Purged);
    // "ahead" по-прежнему первым.
    CHECK(sync_repo::reset_reason_for(200, 120, 100, 100) == sync_repo::ResetReason::Ahead);
}

TEST(reset_reason_names) {
    CHECK_EQ(std::string(sync_repo::reset_reason_name(sync_repo::ResetReason::None)), std::string(""));
    CHECK_EQ(std::string(sync_repo::reset_reason_name(sync_repo::ResetReason::Ahead)), std::string("ahead"));
    CHECK_EQ(std::string(sync_repo::reset_reason_name(sync_repo::ResetReason::Purged)), std::string("purged"));
}

TEST(purge_order_matches_pull_tables) {
    // Новая таблица синка без места в порядке чистки — её tombstone копились
    // бы вечно, а её ссылки не держали бы родителей.
    std::set<std::string> order(sync_repo::purge_order().begin(), sync_repo::purge_order().end());
    std::set<std::string> pulled;
    for (const auto& t : pull_tables()) pulled.insert(t.name);
    CHECK(order == pulled);
    CHECK_EQ(order.size(), sync_repo::purge_order().size());
}

TEST(table_refs_point_between_sync_tables_and_columns_exist) {
    for (const auto& ref : sync_repo::sync_table_refs()) {
        const TableSpec* child = find(pull_tables(), ref.child);
        const TableSpec* parent = find(pull_tables(), ref.parent);
        REQUIRE(child != nullptr);
        REQUIRE(parent != nullptr);
        REQUIRE(ref.child_columns.size() == ref.parent_columns.size());
        for (const auto& col : ref.child_columns) {
            bool common = col == "uuid" || col == "ledger_id";
            bool business = std::find(child->columns.begin(), child->columns.end(), col) != child->columns.end();
            CHECK(common || business);
        }
        for (const auto& col : ref.parent_columns) CHECK(col == "uuid" || col == "ledger_id");
    }
}

TEST(purge_order_deletes_children_before_parents) {
    const auto& order = sync_repo::purge_order();
    auto pos = [&](const std::string& name) {
        return std::find(order.begin(), order.end(), name) - order.begin();
    };
    for (const auto& ref : sync_repo::sync_table_refs()) {
        CHECK(pos(ref.child) < pos(ref.parent));
    }
}

TEST(every_uuid_column_of_sync_tables_has_a_ref) {
    // Бизнес-колонка *_uuid — ссылка на другую таблицу синка; забытая в
    // sync_table_refs() ссылка уронила бы DELETE на FK или унесла бы
    // каскадом живые строки.
    for (const auto& t : pull_tables()) {
        for (const auto& col : t.columns) {
            if (col.size() < 5 || col.substr(col.size() - 5) != "_uuid") continue;
            bool found = false;
            for (const auto& ref : sync_repo::sync_table_refs()) {
                if (ref.child != t.name) continue;
                if (std::find(ref.child_columns.begin(), ref.child_columns.end(), col) != ref.child_columns.end()) {
                    found = true;
                }
            }
            CHECK(found);
        }
    }
}

TEST(purge_statements_ledger_stream_cover_all_tables) {
    auto stmts = sync_repo::build_purge_statements(/*ledger_stream=*/true);
    CHECK_EQ(stmts.size(), sync_repo::purge_order().size());
    for (const auto& st : stmts) {
        CHECK(st.sql.find("p.ledger_id = $1") != std::string::npos);
        CHECK(st.sql.find("p.seq <= $2") != std::string::npos);
        CHECK(st.sql.find("p.deleted_at IS NOT NULL") != std::string::npos);
    }
}

TEST(purge_statements_account_checks_operations_and_operating) {
    auto stmts = sync_repo::build_purge_statements(/*ledger_stream=*/true);
    auto it = std::find_if(stmts.begin(), stmts.end(), [](const auto& s) { return s.table == "account"; });
    REQUIRE(it != stmts.end());
    CHECK(it->sql.find("c.acc_fr_uuid = p.uuid") != std::string::npos);
    CHECK(it->sql.find("c.acc_to_uuid = p.uuid") != std::string::npos);
    CHECK(it->sql.find("FROM account_operating c") != std::string::npos);
}

TEST(purge_statements_reference_stream_only_shared_tables) {
    auto stmts = sync_repo::build_purge_statements(/*ledger_stream=*/false);
    for (const auto& st : stmts) {
        const TableSpec* spec = find(pull_tables(), st.table);
        REQUIRE(spec != nullptr);
        CHECK(spec->scope == Scope::ReferenceOrLedger);
        CHECK(st.sql.find("p.ledger_id IS NULL") != std::string::npos);
        CHECK(st.sql.find("p.seq <= $1") != std::string::npos);
    }
    // icon держат и счета (ledger-only таблица): ссылки не фильтруются по
    // потоку.
    auto icon = std::find_if(stmts.begin(), stmts.end(), [](const auto& s) { return s.table == "icon"; });
    REQUIRE(icon != stmts.end());
    CHECK(icon->sql.find("FROM account c") != std::string::npos);
}
