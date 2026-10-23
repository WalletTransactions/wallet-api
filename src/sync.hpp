// POST /sync/push и GET /sync/pull (org/docs/TODO_mobile_sync.md, Фаза 2) —
// синхронизация локальной SQLite Android-клиента с этим сервисом; push
// заодно — запись операций из бота и веба. Нужен токен с claim'ом device_id
// (мобильный вход, бот, браузер — см. README google-auth); без него — 403
// device_required, см. authenticate_and_provision в sync.cpp.
#pragma once

#include "app_state.hpp"
#include "httplib.h"

namespace syncapi {

void register_routes(httplib::Server& svr, AppState& state);

} // namespace syncapi
