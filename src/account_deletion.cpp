#include "account_deletion.hpp"

#include "account_deletion_repo.hpp"
#include "nlohmann/json.hpp"
#include "session.hpp"
#include "util/log.hpp"

using nlohmann::json;

namespace account_deletion_api {

namespace {

constexpr const char* kJsonContentType = "application/json";

void json_error(httplib::Response& res, int status, const std::string& message) {
    res.status = status;
    res.set_content(json{{"error", message}}.dump(), kJsonContentType);
}

void handle_delete_account(AppState& state, const httplib::Request& req, httplib::Response& res) {
    applog::set_route("DELETE /api/account"); // литерал из register_routes ниже
    auto user = session::current_user(req, *state.jwks);
    if (!user) {
        json_error(res, 401, "unauthenticated");
        return;
    }

    auto status = account_deletion_repo::delete_own_account(*state.db_pool->acquire(), user->user_id);
    switch (status) {
        case account_deletion_repo::DeleteStatus::kOk:
            res.status = 204;
            return;
        case account_deletion_repo::DeleteStatus::kOwnsSharedLedger:
            json_error(res, 409,
                       "вы владелец кошелька с другими участниками — сначала передайте "
                       "владение (POST /api/ledger/transfer-owner) или удалите их "
                       "(DELETE /api/ledger/members/{user_id})");
            return;
    }
}

} // namespace

void register_routes(httplib::Server& svr, AppState& state) {
    svr.Delete("/api/account", [&state](const httplib::Request& req, httplib::Response& res) {
        handle_delete_account(state, req, res);
    });
}

} // namespace account_deletion_api
