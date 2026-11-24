// Запрет записи читателю леджера (роль 'reader', ledger_member.role).
//
// Скоуп токена (wallet:write) говорит, ЧТО умеет клиент, а не КЕМ пользователь
// приходится леджеру: у читателя на телефоне и в вебе тот же wallet:write, что
// у владельца. Поэтому роль проверяется отдельно, в каждом пишущем маршруте
// леджера — /sync/push (sync.cpp) и REST валют/пар/курсов/маршрутов. До этого
// роль смотрел только push бота (expense_only), и читатель с телефона мог
// удалить или переписать весь общий леджер.
//
// Ответ — 403 {"error":"reader_cannot_write"}: тот же машинный код, что уже
// понимают бот (wallet_client.cpp) и веб (app.js).
#pragma once

#include <string>

#include "app_state.hpp"
#include "httplib.h"
#include "invites_repo.hpp"
#include "session.hpp"

namespace ledger_write_guard {

constexpr const char* kReaderCannotWrite = "reader_cannot_write";

inline bool can_write(const std::string& ledger_role) { return ledger_role != "reader"; }

inline void reject(httplib::Response& res) {
    res.status = 403;
    res.set_content(std::string("{\"error\":\"") + kReaderCannotWrite + "\"}", "application/json");
}

// true — пользователь читатель своего леджера, ответ 403 уже записан.
// Без токена или без леджера — false: эти случаи (401/404/провизионирование)
// остаются за самим хендлером.
inline bool reject_reader(AppState& state, const httplib::Request& req, httplib::Response& res) {
    auto user = session::current_user(req, *state.jwks);
    if (!user) return false;
    auto membership = invites_repo::find_membership(*state.db_pool->acquire(), user->user_id);
    if (!membership || can_write(membership->role)) return false;
    reject(res);
    return true;
}

} // namespace ledger_write_guard
