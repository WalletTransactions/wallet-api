// Флаг приёма своих иконок (change optional-icon-upload): разбор переменной,
// решение «флаг × роль», вырезание строк `icon` из батча и тело ответа push.
// Сам HTTP-путь с базой — tests_integration/test_icon_upload.cpp.
#include "icon_upload.hpp"

#include "nlohmann/json.hpp"
#include "sync_repo.hpp"
#include "test_framework.hpp"

using nlohmann::json;

TEST(icon_upload_flag_parses_on_true_1_and_defaults_off) {
    CHECK(icon_upload::parse_flag("on"));
    CHECK(icon_upload::parse_flag("true"));
    CHECK(icon_upload::parse_flag("1"));
    CHECK(!icon_upload::parse_flag("off"));
    CHECK(!icon_upload::parse_flag(""));
    CHECK(!icon_upload::parse_flag("yes"));
    CHECK(!icon_upload::parse_flag("ON"));
}

TEST(icon_upload_allowed_by_flag_or_admin_role) {
    CHECK(icon_upload::allowed(true, "user"));
    CHECK(icon_upload::allowed(true, "admin"));
    CHECK(icon_upload::allowed(false, "admin"));
    CHECK(!icon_upload::allowed(false, "user"));
    CHECK(!icon_upload::allowed(false, "support"));
    CHECK(!icon_upload::allowed(false, ""));
}

TEST(take_icon_rows_removes_icons_and_keeps_rest_of_batch) {
    json changes = {{"icon", json::array({{{"uuid", "i1"}, {"name", "a"}}, {{"uuid", "i2"}}, {{"name", "no uuid"}}})},
                    {"operation", json::array({{{"uuid", "op1"}}})}};
    auto uuids = icon_upload::take_icon_rows(changes);
    REQUIRE(uuids.size() == 2);
    CHECK_EQ(uuids[0], std::string("i1"));
    CHECK_EQ(uuids[1], std::string("i2"));
    CHECK(!changes.contains("icon"));
    CHECK_EQ(changes.at("operation").size(), std::size_t{1});
}

TEST(take_icon_rows_without_icons_leaves_batch_untouched) {
    json changes = {{"operation", json::array({{{"uuid", "op1"}}})}};
    json before = changes;
    CHECK(icon_upload::take_icon_rows(changes).empty());
    CHECK(changes == before);
}

TEST(take_icon_rows_drops_empty_icon_table_without_uuids) {
    json changes = {{"icon", json::array()}};
    CHECK(icon_upload::take_icon_rows(changes).empty());
    CHECK(!changes.contains("icon"));
}

TEST(push_success_response_has_icons_rejected_only_when_some) {
    json plain = sync_repo::success_response(42, {});
    CHECK_EQ(plain.at("seq").get<int64_t>(), int64_t{42});
    CHECK(plain.at("conflicts").empty());
    CHECK(!plain.contains("icons_rejected"));

    json rejected = sync_repo::success_response(43, {"i1", "i2"});
    CHECK_EQ(rejected.at("icons_rejected").at("error").get<std::string>(), std::string("icon_upload_disabled"));
    CHECK_EQ(rejected.at("icons_rejected").at("uuids").size(), std::size_t{2});
    CHECK_EQ(rejected.at("icons_rejected").at("uuids").at(0).get<std::string>(), std::string("i1"));
}
