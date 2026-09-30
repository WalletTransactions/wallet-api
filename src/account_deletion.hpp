// DELETE /api/account — самообслуживание "Удалить аккаунт" (настройки
// wallet-web). См. account_deletion_repo.hpp, почему не "account.hpp"
// (таблица `account` в схеме — совсем другая сущность, кошельки/категории).
#pragma once

#include "app_state.hpp"
#include "httplib.h"

namespace account_deletion_api {

void register_routes(httplib::Server& svr, AppState& state);

} // namespace account_deletion_api
